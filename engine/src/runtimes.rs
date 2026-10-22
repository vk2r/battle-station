//! Model details from the runtimes' local HTTP APIs, queried only while a runtime runs.

use std::collections::{BTreeMap, HashMap, VecDeque};
use std::io::Read;
use std::path::Path;
use std::process::{Command, Stdio};
use std::sync::OnceLock;
use std::time::{Duration, Instant};

use regex::Regex;
use serde_json::{Map, Value, json};

use crate::http;
use crate::procs::{self, LLAMACPP_TOOLS, Proc, argv, clean, model_from_cmdline, trusted};

type Model = Map<String, Value>;
/// Prometheus samples by metric name: (labels, value).
type Metrics = HashMap<String, Vec<(HashMap<String, String>, f64)>>;
/// Runtime id, commands on PATH, systemd units, data folders.
type InstallHint = (&'static str, &'static [&'static str], &'static [&'static str], &'static [&'static str]);

fn num(value: Option<&Value>) -> f64 {
    match value {
        Some(Value::Number(number)) => number.as_f64().unwrap_or(0.0),
        Some(Value::String(text)) => text.trim().parse().unwrap_or(0.0),
        _ => 0.0,
    }
}

fn text(value: Option<&Value>) -> String {
    match value {
        Some(Value::String(text)) => text.clone(),
        Some(Value::Null) | None => String::new(),
        Some(other) => other.to_string(),
    }
}

fn rows<'a>(data: &'a Option<Value>, key: &str) -> &'a [Value] {
    data.as_ref().and_then(|data| data.get(key)).and_then(Value::as_array).map_or(&[], Vec::as_slice)
}

fn base_model(name: String, state: &str, context: Value) -> Model {
    let mut model = Model::new();
    model.insert("name".into(), name.into());
    model.insert("state".into(), state.into());
    model.insert("context".into(), context);
    model
}

// --- Generation speed ------------------------------------------------------------

/// Generation-speed bookkeeping per runtime and model, kept while the engine runs.
#[derive(Default)]
struct Speed {
    rates: VecDeque<f64>,
    tokens: f64,
    seconds: f64,
    counters: Option<(f64, f64)>,
    live: Option<(Vec<String>, f64, f64, Option<f64>)>,
    now: Option<f64>,
    server_avg: Option<f64>,
}

impl Speed {
    fn add(&mut self, tokens: f64, seconds: f64) {
        if tokens > 0.0 && seconds > 0.0 {
            self.rates.push_back(tokens / seconds);
            if self.rates.len() > 500 {
                self.rates.pop_front();
            }
            self.tokens += tokens;
            self.seconds += seconds;
        }
    }

    fn reset(&mut self) {
        self.rates.clear();
        self.tokens = 0.0;
        self.seconds = 0.0;
    }

    /// now / min / avg / max tokens per second; avg is weighted by tokens.
    ///
    /// The average prefers the runtime's own totals since the model was loaded, so
    /// it is there right after the monitor starts; min and max need finished replies.
    fn report(&self) -> Value {
        let avg = self.server_avg.or((self.seconds > 0.0).then(|| self.tokens / self.seconds));
        if self.rates.is_empty() && self.now.is_none() && avg.is_none() {
            return Value::Null;
        }
        let min = self.rates.iter().copied().reduce(f64::min);
        let max = self.rates.iter().copied().reduce(f64::max);
        json!({"now": self.now, "count": self.rates.len(), "avg": avg, "min": min, "max": max})
    }
}

/// Prometheus samples from a metrics endpoint as {name: [(labels, value)]}.
fn prometheus(port: u16, path: &str, prefix: &str) -> Metrics {
    static LABEL: OnceLock<Regex> = OnceLock::new();
    static SAMPLE: OnceLock<Regex> = OnceLock::new();
    let label = LABEL.get_or_init(|| Regex::new(r#"(\w+)="([^"]*)""#).unwrap());
    let sample = SAMPLE.get_or_init(|| Regex::new(r"^([A-Za-z0-9_:]+)(\{[^}]*\})?\s+(\S+)").unwrap());
    let mut samples: Metrics = HashMap::new();
    let Some(body) = http::get(port, path) else { return samples };
    for line in String::from_utf8_lossy(&body).lines() {
        if !line.starts_with(prefix) {
            continue; // comments and other exporters' metrics
        }
        let Some(caps) = sample.captures(line) else { continue };
        let Ok(value) = caps[3].parse::<f64>() else { continue };
        let labels = caps.get(2).map_or_else(HashMap::new, |labels| {
            label.captures_iter(labels.as_str()).map(|pair| (pair[1].to_string(), pair[2].to_string())).collect()
        });
        samples.entry(caps[1].to_string()).or_default().push((labels, value));
    }
    samples
}

fn total(metrics: &Metrics, name: &str) -> f64 {
    metrics.get(name).map_or(0.0, |samples| samples.iter().map(|(_, value)| value).sum())
}

// --- Context memory (llama.cpp) --------------------------------------------------

// Flags that decide how much memory the context (KV cache, recurrent state) takes.
const CONTEXT_FLAGS: [(&str, &str); 16] = [
    ("-m", "-m"),
    ("--model", "-m"),
    ("-c", "-c"),
    ("--ctx-size", "-c"),
    ("-ctk", "-ctk"),
    ("--cache-type-k", "-ctk"),
    ("-ctv", "-ctv"),
    ("--cache-type-v", "-ctv"),
    ("-fa", "-fa"),
    ("--flash-attn", "-fa"),
    ("-np", "-np"),
    ("--parallel", "-np"),
    ("-ub", "-ub"),
    ("--ubatch-size", "-ub"),
    ("-b", "-b"),
    ("--batch-size", "-b"),
];
const CONTEXT_SWITCHES: [&str; 5] = ["-kvu", "--kv-unified", "-no-kvu", "--no-kv-unified", "--swa-full"];

/// stdout + stderr of `command`, killed after `timeout`.
fn run_output(command: &mut Command, timeout: Duration) -> Option<String> {
    let mut child = command.stdin(Stdio::null()).stdout(Stdio::piped()).stderr(Stdio::piped()).spawn().ok()?;
    let drain = |pipe: Option<Box<dyn Read + Send>>| {
        std::thread::spawn(move || {
            let mut text = String::new();
            if let Some(mut pipe) = pipe {
                let _ = pipe.read_to_string(&mut text);
            }
            text
        })
    };
    let stdout = drain(child.stdout.take().map(|pipe| Box::new(pipe) as Box<dyn Read + Send>));
    let stderr = drain(child.stderr.take().map(|pipe| Box::new(pipe) as Box<dyn Read + Send>));
    let deadline = Instant::now() + timeout;
    loop {
        match child.try_wait() {
            Ok(Some(_)) => break,
            Ok(None) if Instant::now() < deadline => std::thread::sleep(Duration::from_millis(50)),
            _ => {
                let _ = child.kill();
                let _ = child.wait();
                return None;
            }
        }
    }
    Some(stderr.join().unwrap_or_default() + &stdout.join().unwrap_or_default())
}

// --- State kept across snapshots -------------------------------------------------

pub struct Runtimes {
    pub ports: BTreeMap<&'static str, u16>,
    start: Instant,
    speed: HashMap<String, Speed>,
    last_output: HashMap<String, Model>,
    context_memory: HashMap<Vec<String>, Option<u64>>,
    installed_tick: u64,
    installed: HashMap<&'static str, bool>,
}

impl Runtimes {
    pub fn new() -> Self {
        let ports = BTreeMap::from([("llamacpp", 8080), ("ollama", 11434), ("lmstudio", 1234), ("vllm", 8000)]);
        Runtimes {
            ports,
            start: Instant::now(),
            speed: HashMap::new(),
            last_output: HashMap::new(),
            context_memory: HashMap::new(),
            installed_tick: 0,
            installed: HashMap::new(),
        }
    }

    fn mono(&self) -> f64 {
        self.start.elapsed().as_secs_f64()
    }

    pub fn models(&mut self, runtime: &str, processes: &[Proc]) -> Vec<Value> {
        let models = match runtime {
            _ if processes.is_empty() => Vec::new(),
            "llamacpp" => self.llamacpp_models(processes),
            "ollama" => self.ollama_models(),
            "vllm" => self.vllm_models(),
            _ => self.lmstudio_models(processes),
        };
        models.into_iter().map(Value::Object).collect()
    }

    /// Bytes llama.cpp allocates for the context of the llama-server `pid`.
    ///
    /// Binary and arguments come from /proc of that trusted process, never from
    /// the HTTP API: any local account can answer on the port, so its replies
    /// must not choose what runs here or which model file gets parsed.
    ///
    /// llama-fit-params (next to the llama-server binary) projects the memory
    /// breakdown without loading weights; `-dev none` keeps it off the GPU. It
    /// only runs if root or we own it and its directories (`safe_executable`). The
    /// KV cache is allocated in full at load, so this is what the context holds
    /// in VRAM. Cached per argument set: it runs once per model load.
    fn context_memory(&mut self, pid: &str) -> Option<u64> {
        static ROW: OnceLock<Regex> = OnceLock::new();
        let binary = std::fs::read_link(format!("/proc/{pid}/exe")).ok()?;
        let args = argv(pid);
        if args.is_empty() || !trusted(pid) {
            return None;
        }
        let mut wanted = Vec::new();
        let mut index = 1;
        while index < args.len() {
            let flag = args[index].as_str();
            if let Some((_, short)) = CONTEXT_FLAGS.iter().find(|(long, _)| *long == flag)
                && index + 1 < args.len()
            {
                wanted.push(short.to_string());
                wanted.push(args[index + 1].clone());
                index += 2;
                continue;
            }
            if CONTEXT_SWITCHES.contains(&flag) {
                wanted.push(flag.to_string());
            }
            index += 1;
        }
        if !wanted.iter().any(|arg| arg == "-m") {
            return None;
        }
        let mut key = vec![binary.to_string_lossy().into_owned()];
        key.extend(wanted.iter().cloned());
        if let Some(cached) = self.context_memory.get(&key) {
            return *cached;
        }
        let helper = binary.parent().unwrap_or(Path::new("/")).join("llama-fit-params");
        let output = procs::safe_executable(&helper).and_then(|tool| {
            run_output(Command::new(tool).args(&wanted).args(["-dev", "none", "-lv", "4"]), Duration::from_secs(30))
        });
        // "|   - Host   |   7444 =  4935 +  1877 +  631   |": model + context + compute
        let row = ROW.get_or_init(|| Regex::new(r"\|\s+- .*?\|\s+\d+\s*=\s*\d+\s*\+\s*(\d+)\s*\+\s*\d+").unwrap());
        let total = output.and_then(|output| {
            let mib: Vec<u64> = row.captures_iter(&output).filter_map(|caps| caps[1].parse().ok()).collect();
            (!mib.is_empty()).then(|| mib.iter().sum::<u64>() << 20)
        });
        self.context_memory.insert(key, total);
        total
    }

    // --- llama.cpp ---

    /// Speed of finished replies from llama.cpp's /metrics counters.
    ///
    /// tokens_predicted_total / tokens_predicted_seconds_total grow when a reply
    /// ends and count decode time only (no prompt processing), so each increase is
    /// the generation speed of the replies that just finished. Needs --metrics.
    fn llamacpp_speed(&mut self, model: &str, key: &str) {
        let path =
            if model.is_empty() { "/metrics".to_string() } else { format!("/metrics?model={}", http::quote(model)) };
        let metrics = prometheus(self.ports["llamacpp"], &path, "llamacpp:");
        if metrics.is_empty() {
            return;
        }
        let tokens = total(&metrics, "llamacpp:tokens_predicted_total");
        let seconds = total(&metrics, "llamacpp:tokens_predicted_seconds_total");
        let state = self.speed.entry(key.to_string()).or_default();
        match state.counters {
            Some(previous) if tokens >= previous.0 => state.add(tokens - previous.0, seconds - previous.1),
            Some(_) => state.reset(), // counters went back: the model was reloaded
            None => {}
        }
        state.counters = Some((tokens, seconds));
        state.server_avg = (tokens > 0.0 && seconds > 0.0).then(|| tokens / seconds);
    }

    /// Context and output fill, summed over the server's slots.
    ///
    /// The context is one KV-cache pool of `--ctx-size` tokens. With a unified KV
    /// cache (llama.cpp's default when it picks the slot count) every slot reports
    /// the whole pool as its n_ctx, so the pool is counted once, not per slot;
    /// split caches give each slot its share, which add up to the same pool.
    ///
    /// context_used: tokens in the slots (n_prompt_tokens counts generated ones too).
    /// output_used / output_limit: tokens generated for the reply in progress and
    /// the most it may produce (n_predict, or what is left of the context). The
    /// last reply's figures stay visible after it ends, marked as not generating.
    fn llamacpp_slots(&mut self, model: &str, args: &[String]) -> Model {
        let path = if model.is_empty() { "/slots".to_string() } else { format!("/slots?model={}", http::quote(model)) };
        let slots: Vec<Map<String, Value>> = match http::json(self.ports["llamacpp"], &path) {
            Some(Value::Array(slots)) => slots.into_iter().filter_map(|slot| slot.as_object().cloned()).collect(),
            _ => Vec::new(),
        };
        if slots.is_empty() {
            return Model::new();
        }
        let used: f64 = slots.iter().map(|slot| num(slot.get("n_prompt_tokens")).trunc()).sum();
        let largest = slots.iter().map(|slot| num(slot.get("n_ctx")).trunc()).fold(0.0, f64::max);
        let split: f64 = slots.iter().map(|slot| num(slot.get("n_ctx")).trunc()).sum();
        let (configured, unified) = context_args(args);
        // Shared pool: each slot sees more than an equal share of it.
        let shared = match (configured, unified) {
            (Some(pool), _) => largest * slots.len() as f64 > pool + 0.5,
            (None, Some(flag)) => flag,
            (None, None) => slots.len() > 1, // llama.cpp unifies when it picks the slot count
        };
        let size = configured.unwrap_or(if shared { largest } else { split });
        let (mut output_used, mut output_limit, mut generating, mut open_ended) = (0.0, 0.0, false, false);
        let mut tasks = Vec::new();
        for slot in slots.iter().filter(|slot| slot.get("is_processing").and_then(Value::as_bool).unwrap_or(false)) {
            tasks.push(text(slot.get("id_task")));
            let decoded: f64 = slot
                .get("next_token")
                .and_then(Value::as_array)
                .map_or(0.0, |tokens| tokens.iter().map(|token| num(token.get("n_decoded")).trunc()).sum());
            let mut limit = slot.get("params").map_or(0.0, |params| num(params.get("n_predict")).trunc());
            if limit <= 0.0 {
                // unlimited: the reply can grow until the context is full
                if shared {
                    limit = decoded; // the pool's free room is added once, below
                    open_ended = true;
                } else {
                    let left = num(slot.get("n_ctx")).trunc() - num(slot.get("n_prompt_tokens")).trunc() + decoded;
                    limit = decoded.max(left);
                }
            }
            output_used += decoded;
            output_limit += limit;
            generating = true;
        }
        if open_ended {
            output_limit += (size - used).max(0.0);
        }
        tasks.sort();

        let key = format!("llamacpp/{model}");
        let now = self.mono();
        let state = self.speed.entry(key.clone()).or_default();
        let live = state.live.take();
        state.now = None;
        if generating {
            if let Some((_, live_used, live_time, live_now)) = live.filter(|live| live.0 == tasks) {
                state.now = if output_used > live_used {
                    Some((output_used - live_used) / (now - live_time).max(0.001))
                } else {
                    live_now // no new token since the last look: keep the last value
                };
            }
            state.live = Some((tasks, output_used, now, state.now));
        }
        self.llamacpp_speed(model, &key);

        let mut output = Model::new();
        output.insert("output_used".into(), json!(output_used as i64));
        output.insert("output_limit".into(), json!(output_limit as i64));
        output.insert("generating".into(), json!(generating));
        if generating {
            self.last_output.insert(model.to_string(), output.clone());
        } else if let Some(last) = self.last_output.get(model) {
            output = last.clone();
            output.insert("generating".into(), json!(false));
        }
        let mut result = Model::new();
        result.insert("context_used".into(), json!(used as i64));
        result.insert("context".into(), if size > 0.0 { json!(size as i64) } else { Value::Null });
        result.extend(output);
        result.insert("speed".into(), self.speed[&key].report());
        result
    }

    fn llamacpp_models(&mut self, processes: &[Proc]) -> Vec<Model> {
        let (tools, servers): (Vec<&Proc>, Vec<&Proc>) =
            processes.iter().partition(|process| LLAMACPP_TOOLS.contains(&process.comm.as_str()));
        let servers: Vec<Proc> = servers.into_iter().cloned().collect();
        let mut models = if servers.is_empty() { Vec::new() } else { self.llamacpp_server_models(&servers) };
        for tool in tools {
            let name = model_from_cmdline(&tool.cmdline);
            if !name.is_empty() && models.iter().all(|model| model.get("name") != Some(&json!(name))) {
                models.push(base_model(name, "loaded", Value::Null));
            }
        }
        models
    }

    fn llamacpp_server_models(&mut self, processes: &[Proc]) -> Vec<Model> {
        let mut models = Vec::new();
        let data = http::json(self.ports["llamacpp"], "/models");
        for row in rows(&data, "data") {
            let status = row.get("status");
            let state = text(status.and_then(|status| status.get("value")));
            if !matches!(state.as_str(), "loaded" | "loading" | "sleeping") {
                continue;
            }
            let args: Vec<String> = status
                .and_then(|status| status.get("args"))
                .and_then(Value::as_array)
                .map_or_else(Vec::new, |args| args.iter().map(|arg| text(Some(arg))).collect());
            let ctx = context_args(&args).0.map_or(Value::Null, |size| Value::from(size as i64));
            let id = text(row.get("id"));
            let mut model = base_model(clean(&id, 120), &state, ctx.clone());
            if state == "loaded" {
                let slots = self.llamacpp_slots(&id, &args);
                let pid = server_for(processes, &args);
                let context = slots.get("context").filter(|context| !context.is_null()).cloned().unwrap_or(ctx);
                model.extend(slots);
                model.insert("context".into(), context);
                let memory = pid.and_then(|pid| self.context_memory(&pid));
                model.insert("context_memory".into(), json!(memory));
            }
            models.push(model);
        }
        if models.is_empty() {
            for process in processes {
                let name = model_from_cmdline(&process.cmdline);
                if !name.is_empty() {
                    let mut model = base_model(name, "loaded", Value::Null);
                    let argv = argv(&process.pid);
                    model.extend(self.llamacpp_slots("", &argv));
                    let memory = self.context_memory(&process.pid);
                    model.insert("context_memory".into(), json!(memory));
                    models.push(model);
                }
            }
        }
        models
    }

    // --- Ollama, LM Studio ---

    fn ollama_models(&self) -> Vec<Model> {
        let data = http::json(self.ports["ollama"], "/api/ps");
        rows(&data, "models")
            .iter()
            .map(|row| {
                let name = text(row.get("name"));
                let name = name.strip_suffix(":latest").unwrap_or(&name);
                let mut model =
                    base_model(clean(name, 120), "loaded", row.get("context_length").cloned().unwrap_or(Value::Null));
                model.insert("vram".into(), row.get("size_vram").cloned().unwrap_or(Value::Null));
                model
            })
            .collect()
    }

    fn lmstudio_models(&self, processes: &[Proc]) -> Vec<Model> {
        let port = self.ports["lmstudio"];
        let data = if http::port_open(port) { http::json(port, "/api/v1/models") } else { None };
        let mut models = Vec::new();
        for row in rows(&data, "models") {
            for instance in row.get("loaded_instances").and_then(Value::as_array).into_iter().flatten() {
                let context = instance.get("config").and_then(|config| config.get("context_length")).cloned();
                models.push(base_model(clean(&text(row.get("key")), 120), "loaded", context.unwrap_or(Value::Null)));
            }
        }
        if models.is_empty() {
            // The daemon may run without its HTTP server; the engine's cmdline still names the model.
            for process in processes.iter().filter(|process| process.comm == "llama-server") {
                let name = model_from_cmdline(&process.cmdline);
                if !name.is_empty() {
                    models.push(base_model(name, "loaded", Value::Null));
                }
            }
        }
        models
    }

    // --- vLLM ---

    /// Model, KV-cache fill and activity of a vLLM server.
    ///
    /// vLLM keeps one KV-cache pool for all requests (num_gpu_blocks x block_size
    /// tokens), reserved at start-up; kv_cache_usage_perc (gpu_cache_usage_perc
    /// before v0.10) is how full that pool is, which is what "Context buffer" shows.
    fn vllm_models(&mut self) -> Vec<Model> {
        let port = self.ports["vllm"];
        let data = http::json(port, "/v1/models");
        let metrics = prometheus(port, "/metrics", "vllm:");
        let usage = ["vllm:kv_cache_usage_perc", "vllm:gpu_cache_usage_perc"]
            .iter()
            .find_map(|name| metrics.get(*name).filter(|samples| !samples.is_empty()))
            .map(|samples| samples[0].1);
        let mut capacity = None;
        for (labels, _) in metrics.get("vllm:cache_config_info").into_iter().flatten() {
            let blocks = labels.get("num_gpu_blocks").and_then(|value| value.parse::<i64>().ok());
            let size = labels.get("block_size").and_then(|value| value.parse::<i64>().ok());
            if let (Some(blocks), Some(size)) = (blocks, size) {
                capacity = Some(blocks * size);
            }
        }
        let running = total(&metrics, "vllm:num_requests_running");
        let generated = total(&metrics, "vllm:generation_tokens_total");
        let now = self.mono();
        let state = self.speed.entry(format!("vllm/{port}")).or_default();
        state.now = None;
        match state.counters {
            Some(previous) if generated >= previous.0 && running > 0.0 => {
                state.now = Some((generated - previous.0) / (now - previous.1).max(0.001));
                state.add(generated - previous.0, now - previous.1);
            }
            Some(previous) if generated < previous.0 => state.reset(), // server restarted
            _ => {}
        }
        if !metrics.is_empty() {
            state.counters = Some((generated, now));
        }
        let speed = state.report();
        let mut models = Vec::new();
        for row in rows(&data, "data") {
            // skip LoRA adapters
            if !row.is_object() || row.get("parent").is_some_and(|parent| !parent.is_null() && parent != "") {
                continue;
            }
            let mut model = base_model(
                clean(&text(row.get("id")), 120),
                "loaded",
                row.get("max_model_len").cloned().unwrap_or(Value::Null),
            );
            model.insert("generating".into(), json!(running > 0.0));
            model.insert("speed".into(), speed.clone());
            if let (Some(capacity), Some(usage)) = (capacity.filter(|capacity| *capacity > 0), usage) {
                model.insert("context".into(), json!(capacity));
                model.insert("context_used".into(), json!((usage * capacity as f64).round() as i64));
            }
            models.push(model);
        }
        models
    }

    /// Which runtimes exist on this machine, refreshed every `every` snapshots (about a minute).
    ///
    /// Lets the panel say "not installed" instead of "stopped". A runtime counts as
    /// installed when its command is on PATH, a systemd unit for it exists, or its
    /// data folder exists.
    pub fn installed(&mut self, every: u64) -> &HashMap<&'static str, bool> {
        const UNIT_DIRS: [&str; 5] = [
            "~/.config/systemd/user",
            "/etc/systemd/user",
            "/usr/lib/systemd/user",
            "/etc/systemd/system",
            "/usr/lib/systemd/system",
        ];
        const HINTS: [InstallHint; 4] = [
            ("llamacpp", &["llama-server"], &["llama-server.service"], &[]),
            ("ollama", &["ollama"], &["ollama.service"], &[]),
            ("lmstudio", &["lms", "lm-studio"], &[], &["~/.lmstudio"]),
            ("vllm", &["vllm"], &["vllm.service"], &[]),
        ];
        self.installed_tick += 1;
        if self.installed_tick % every != 1 {
            return &self.installed;
        }
        let home = std::env::var("HOME").unwrap_or_default();
        let expand = |path: &str| path.replacen('~', &home, 1);
        let path_var = std::env::var("PATH").unwrap_or_default();
        let which = |command: &str| path_var.split(':').any(|dir| Path::new(dir).join(command).is_file());
        for (runtime, commands, units, paths) in HINTS {
            let hit = commands.iter().any(|command| which(command))
                || units
                    .iter()
                    .any(|unit| UNIT_DIRS.iter().any(|dir| Path::new(&expand(&format!("{dir}/{unit}"))).exists()))
                || paths.iter().any(|path| Path::new(&expand(path)).exists());
            self.installed.insert(runtime, hit);
        }
        &self.installed
    }
}

/// Context pool size (`-c` / `--ctx-size`, 0 = the model's own) and the KV-cache
/// unification switch, from a llama-server command line.
fn context_args(args: &[String]) -> (Option<f64>, Option<bool>) {
    let mut size = None;
    let mut unified = None;
    for (index, arg) in args.iter().enumerate() {
        let value = match arg.as_str() {
            "-c" | "--ctx-size" => args.get(index + 1).map(String::as_str),
            _ => arg.strip_prefix("--ctx-size="),
        };
        if let Some(parsed) = value.and_then(|value| value.parse::<f64>().ok()).filter(|value| *value > 0.0) {
            size = Some(parsed);
        }
        match arg.as_str() {
            "-kvu" | "--kv-unified" => unified = Some(true),
            "-no-kvu" | "--no-kv-unified" => unified = Some(false),
            _ => {}
        }
    }
    (size, unified)
}

/// The trusted llama-server process running the model the API describes with `args`.
///
/// Router mode starts one child per model; the API only says which one, the
/// child's own /proc entry supplies everything that is acted on.
fn server_for(processes: &[Proc], args: &[String]) -> Option<String> {
    fn model_path(argv: &[String]) -> Option<&String> {
        let flags = argv.get(..argv.len().saturating_sub(1))?;
        ["-m", "--model"]
            .iter()
            .find_map(|wanted| flags.iter().position(|flag| flag == wanted))
            .map(|index| &argv[index + 1])
    }
    let wanted_args = args.get(1..).unwrap_or(&[]);
    let wanted = model_path(wanted_args);
    processes.iter().filter(|process| process.comm == "llama-server").find_map(|process| {
        let argv = procs::argv(&process.pid);
        let own = argv.get(1..).unwrap_or(&[]);
        (own == wanted_args || (wanted.is_some() && model_path(own) == wanted)).then(|| process.pid.clone())
    })
}

/// The API port from the `vllm serve` command line (default 8000).
pub fn vllm_port(processes: &[Proc]) -> u16 {
    static PORT: OnceLock<Regex> = OnceLock::new();
    let port = PORT.get_or_init(|| Regex::new(r"--port[=\s]+(\d+)").unwrap());
    processes.iter().find_map(|process| port.captures(&process.cmdline)?[1].parse().ok()).unwrap_or(8000)
}
