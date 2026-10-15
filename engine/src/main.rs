//! BattleStation engine: stream hardware and local-LLM usage as one JSON line per interval.
//!
//! Runtimes are identified by executable path and systemd cgroup, not by process
//! name: LM Studio's engine is also called `llama-server`.
//!
//! - llama.cpp router: llama-server.service (or any other llama-server), plus the
//!   one-shot llama.cpp tools (llama-tts, llama-cli, ...) that load a
//!   model for a single run, e.g. Simple Reader's Qwen voices
//! - Ollama: ollama serve / ollama runner
//! - LM Studio: the lm-studio daemon and its bundled engines (~/.lmstudio)
//! - vLLM: `vllm serve` / vllm.entrypoints and its VLLM::* engine processes
//!
//! GPU metrics and per-process GPU memory come from all-smi, so the monitor
//! shows which runtime actually holds VRAM on NVIDIA, AMD and Intel GPUs.
//! Model details come from the runtimes' local HTTP APIs, which are only queried
//! while the runtime is running (no API call ever starts a service).

mod gpu;
mod http;
mod procs;
mod runtimes;

use std::collections::{HashMap, HashSet};
use std::io::Write;
use std::panic::{AssertUnwindSafe, catch_unwind};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use serde_json::{Value, json};

use gpu::Gpu;
use procs::{clean, read, trusted};
use runtimes::Runtimes;

const RUNTIMES: [(&str, &str); 4] =
    [("llamacpp", "llama.cpp"), ("ollama", "Ollama"), ("lmstudio", "LM Studio"), ("vllm", "vLLM")];
const HALF_GIB: u64 = 512 << 20;
// /proc reports CPU time in USER_HZ, which Linux fixes at 100 for user space.
const CLOCK_TICKS: f64 = 100.0;

struct Engine {
    gpu: Gpu,
    runtimes: Runtimes,
    cpus: f64,
    last_cpu: Option<(u64, u64)>,
    last_ticks: HashMap<String, u64>,
    last_time: Option<Instant>,
}

impl Engine {
    fn new(preferred_gpu: Option<String>) -> Self {
        Engine {
            gpu: Gpu::new(preferred_gpu.as_deref()),
            runtimes: Runtimes::new(),
            cpus: std::thread::available_parallelism().map_or(1, |cpus| cpus.get()) as f64,
            last_cpu: None,
            last_ticks: HashMap::new(),
            last_time: None,
        }
    }

    fn system_stats(&mut self) -> Value {
        let stat = read("/proc/stat");
        let fields: Vec<u64> = stat
            .lines()
            .next()
            .unwrap_or("")
            .split_whitespace()
            .skip(1)
            .filter_map(|value| value.parse().ok())
            .collect();
        let mut cpu = Value::Null;
        if fields.len() >= 8 {
            let (idle, total) = (fields[3] + fields[4], fields[..8].iter().sum::<u64>());
            if let Some((last_idle, last_total)) = self.last_cpu {
                let span = total.saturating_sub(last_total).max(1) as f64;
                let busy = total.saturating_sub(last_total) as f64 - idle.saturating_sub(last_idle) as f64;
                cpu = json!(round1(100.0 * busy / span));
            }
            self.last_cpu = Some((idle, total));
        }
        let mut info = HashMap::new();
        for line in read("/proc/meminfo").lines() {
            if let Some((key, rest)) = line.split_once(':') {
                let kib = rest.split_whitespace().next().and_then(|value| value.parse::<u64>().ok()).unwrap_or(0);
                info.insert(key.to_string(), kib * 1024);
            }
        }
        let total = info.get("MemTotal").copied().unwrap_or(0);
        let used = total.saturating_sub(info.get("MemAvailable").copied().unwrap_or(0));
        // Logical CPUs online: the "cpuN" rows after the aggregate "cpu" row.
        let cores = stat.lines().skip(1).filter(|line| line.starts_with("cpu")).count();
        json!({"cpu": cpu, "cores": cores, "mem_used": used, "mem_total": total})
    }

    fn snapshot(&mut self) -> Value {
        let now = Instant::now();
        let elapsed = self.last_time.map(|last| now.duration_since(last).as_secs_f64());
        self.last_time = Some(now);
        let groups = procs::process_table();
        if let Some(vllm) = groups.get("vllm") {
            let port = runtimes::vllm_port(vllm);
            self.runtimes.ports.insert("vllm", port);
        }
        let mut clients = if groups.is_empty() { HashMap::new() } else { procs::clients_by_port(&self.runtimes.ports) };
        for label in procs::tool_clients(groups.get("llamacpp").map_or(&[], Vec::as_slice)) {
            let labels = clients.entry("llamacpp").or_default();
            if !labels.contains(&label) {
                labels.push(label);
            }
        }
        let gpu_vram = self.gpu.process_vram();
        let installed = self.runtimes.installed(30).clone();
        let mut seen = HashSet::new();
        let mut runtimes = Vec::new();
        for (runtime, name) in RUNTIMES {
            let processes = groups.get(runtime).map_or(&[][..], Vec::as_slice);
            let (mut ticks, mut pss, mut vram, mut spilled) = (0u64, 0u64, 0u64, 0u64);
            for process in processes {
                seen.insert(process.pid.clone());
                let current = procs::ticks(&process.pid);
                if let (Some(_), Some(last)) = (elapsed, self.last_ticks.get(&process.pid)) {
                    ticks += current.saturating_sub(*last);
                }
                self.last_ticks.insert(process.pid.clone(), current);
                pss += procs::pss(&process.pid);
                vram += gpu_vram.get(&process.pid).copied().unwrap_or(0);
                spilled += self.gpu.spilled(&process.pid);
            }
            let cpu = elapsed.map(|elapsed| round1(100.0 * ticks as f64 / CLOCK_TICKS / elapsed / self.cpus));
            let models = self.runtimes.models(runtime, processes);
            runtimes.push(json!({
                "id": runtime, "name": name, "running": !processes.is_empty(),
                "installed": !processes.is_empty() || installed.get(runtime).copied().unwrap_or(true),
                "processes": processes.len(), "cpu": cpu,
                "memory": pss, "vram": vram, "models": models,
                // Asked for VRAM but evicted to system RAM: the GPU is overcommitted.
                "spilled": spilled,
                "clients": clients.get(runtime).cloned().unwrap_or_default(),
            }));
        }
        self.last_ticks.retain(|pid, _| seen.contains(pid));

        let gpu = self.gpu.stats();
        let vram_used = gpu.as_ref().and_then(|gpu| gpu["vram_used"].as_u64()).unwrap_or(0);
        let gpu_busy = gpu.as_ref().and_then(|gpu| gpu["busy"].as_f64()).unwrap_or(0.0);
        // "sleeping" (llama.cpp router idle-unload) keeps the model listed but frees the GPU.
        let mut loaded: Vec<&Value> = runtimes
            .iter()
            .filter(|runtime| {
                let models = runtime["models"].as_array().map_or(&[][..], Vec::as_slice);
                models.iter().any(|model| matches!(model["state"].as_str(), Some("loaded" | "loading")))
                    || runtime["vram"].as_u64().unwrap_or(0) > HALF_GIB
            })
            .collect();
        let mut llm_vram: u64 = runtimes.iter().map(|runtime| runtime["vram"].as_u64().unwrap_or(0)).sum();
        if vram_used > 0 {
            llm_vram = llm_vram.min(vram_used); // never claim more than the GPU reports
        }
        loaded.sort_by_key(|runtime| std::cmp::Reverse(runtime["vram"].as_u64().unwrap_or(0)));
        let primary = loaded.first().map_or(Value::Null, |runtime| primary(runtime));
        let active = !loaded.is_empty();
        json!({
            "time": SystemTime::now().duration_since(UNIX_EPOCH).map_or(0, |time| time.as_secs()),
            "gpu": gpu,
            // Every GPU on this machine, for the panel's settings selector.
            "gpus": self.gpu.list(),
            "system": self.system_stats(),
            "active": active,
            "llm_vram": llm_vram,
            "llm_spilled": runtimes.iter().map(|runtime| runtime["spilled"].as_u64().unwrap_or(0)).sum::<u64>(),
            // Everything else on the GPU: desktop compositor, shell, browser, driver.
            "other_vram": vram_used.saturating_sub(llm_vram),
            "other_apps": other_apps(&gpu_vram, &seen),
            // Generating: what the runtime says (llama.cpp slots, vLLM requests); for
            // runtimes that do not say, a resident model while the GPU is working.
            "busy": active && primary["generating"].as_bool().unwrap_or(gpu_busy >= 20.0),
            "primary": primary,
            "runtimes": runtimes,
        })
    }
}

fn round1(value: f64) -> f64 {
    (value * 10.0).round() / 10.0
}

/// Non-LLM programs holding VRAM (desktop, browser, ...), the five largest by name.
fn other_apps(gpu_vram: &HashMap<String, u64>, llm_pids: &HashSet<String>) -> Value {
    let mut usage: Vec<(String, u64)> = Vec::new();
    for (pid, vram) in gpu_vram {
        if *vram < (16 << 20) || llm_pids.contains(pid) || !trusted(pid) {
            continue;
        }
        let name = Some(clean(&procs::comm(pid), 40)).filter(|name| !name.is_empty()).unwrap_or_else(|| pid.clone());
        match usage.iter_mut().find(|(known, _)| *known == name) {
            Some((_, total)) => *total += vram,
            None => usage.push((name, *vram)),
        }
    }
    usage.sort_by(|a, b| b.1.cmp(&a.1).then_with(|| a.0.cmp(&b.0)));
    usage.into_iter().take(5).map(|(name, vram)| json!({"name": name, "vram": vram})).collect()
}

fn primary(runtime: &Value) -> Value {
    let models = runtime["models"].as_array().map_or(&[][..], Vec::as_slice);
    let model = models.iter().find(|model| model["state"] != "sleeping").cloned().unwrap_or(json!({}));
    let mut out = json!({"runtime": runtime["name"], "model": model.get("name").cloned().unwrap_or(json!(""))});
    for key in ["context", "context_used", "context_memory", "output_used", "output_limit", "generating", "speed"] {
        out[key] = model.get(key).cloned().unwrap_or(Value::Null);
    }
    out
}

fn main() {
    let mut once = false;
    let mut preferred_gpu = None;
    let mut args = std::env::args().skip(1);
    while let Some(arg) = args.next() {
        match arg.as_str() {
            "--once" => once = true,
            // The GPU the panel picked in its settings; an unknown id falls back to auto.
            "--gpu" => preferred_gpu = args.next(),
            _ => {}
        }
    }
    let interval = std::env::var("LLM_USAGE_INTERVAL").ok().and_then(|value| value.parse::<f64>().ok()).unwrap_or(2.0);
    let interval = Duration::from_secs_f64(interval.max(0.2));
    // A panic inside a snapshot is reported as an error line, not on stderr.
    std::panic::set_hook(Box::new(|_| {}));
    let mut engine = Engine::new(preferred_gpu);
    let _ = catch_unwind(AssertUnwindSafe(|| engine.snapshot())); // prime CPU counters
    std::thread::sleep(if once { Duration::from_millis(500) } else { interval.min(Duration::from_secs(1)) });
    let stdout = std::io::stdout();
    loop {
        let line = match catch_unwind(AssertUnwindSafe(|| engine.snapshot())) {
            Ok(snapshot) => snapshot.to_string(),
            Err(panic) => {
                let message = panic
                    .downcast_ref::<&str>()
                    .map(|text| text.to_string())
                    .or_else(|| panic.downcast_ref::<String>().cloned())
                    .unwrap_or_else(|| "engine error".into());
                // keep streaming; the bar shows stale data otherwise
                json!({"error": message.chars().take(200).collect::<String>()}).to_string()
            }
        };
        let mut out = stdout.lock();
        if writeln!(out, "{line}").and_then(|_| out.flush()).is_err() {
            return; // the widget went away
        }
        drop(out);
        if once {
            return;
        }
        std::thread::sleep(interval);
    }
}
