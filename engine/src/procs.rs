//! /proc: runtime processes, their CPU and memory, and the clients talking to them.

use std::collections::{BTreeMap, HashMap, HashSet};
use std::fs;
use std::os::unix::fs::MetadataExt;
use std::path::{Path, PathBuf};
use std::sync::OnceLock;

use regex::Regex;

pub fn read(path: &str) -> String {
    fs::read(path).map(|bytes| String::from_utf8_lossy(&bytes).into_owned()).unwrap_or_default()
}

pub fn pids() -> impl Iterator<Item = String> {
    fs::read_dir("/proc").into_iter().flatten().flatten().filter_map(|entry| {
        let name = entry.file_name().into_string().ok()?;
        name.bytes().all(|byte| byte.is_ascii_digit()).then_some(name)
    })
}

pub fn comm(pid: &str) -> String {
    read(&format!("/proc/{pid}/comm")).trim().to_string()
}

pub fn argv(pid: &str) -> Vec<String> {
    read(&format!("/proc/{pid}/cmdline")).split('\0').filter(|arg| !arg.is_empty()).map(String::from).collect()
}

pub fn cmdline(pid: &str) -> String {
    read(&format!("/proc/{pid}/cmdline")).replace('\0', " ").trim().to_string()
}

/// Names from runtime APIs and /proc, safe to show in any Qt label.
///
/// Without "<" and ">" Qt never treats the text as rich text, so a model
/// or process name cannot carry markup such as remote images.
pub fn clean(text: &str, limit: usize) -> String {
    let text: String = text.chars().filter(|ch| !ch.is_control() && !"<>&".contains(*ch)).collect();
    text.trim().chars().take(limit).collect()
}

fn my_uid() -> u32 {
    static UID: OnceLock<u32> = OnceLock::new();
    *UID.get_or_init(|| fs::metadata("/proc/self").map(|meta| meta.uid()).unwrap_or(u32::MAX))
}

/// Our own processes, or system services, which only root can start.
///
/// Another local account's processes would let that account choose the
/// names, model names and API answers this widget shows.
pub fn trusted(pid: &str) -> bool {
    match fs::metadata(format!("/proc/{pid}")) {
        Ok(meta) if meta.uid() == my_uid() => true,
        Ok(_) => read(&format!("/proc/{pid}/cgroup"))
            .lines()
            .any(|line| line.splitn(3, ':').last().unwrap_or("").starts_with("/system.slice/")),
        Err(_) => false,
    }
}

/// `path` resolved, if only root or we can change what it runs.
///
/// A trusted process may still run as a service account; a helper found next
/// to its binary is only run when the file and every directory above it belong
/// to root or to us and nobody else can write them, so that account cannot
/// plant code that runs as the desktop user.
pub fn safe_executable(path: &Path) -> Option<PathBuf> {
    let path = fs::canonicalize(path).ok()?;
    let safe = |part: &Path| {
        fs::metadata(part).is_ok_and(|meta| (meta.uid() == 0 || meta.uid() == my_uid()) && meta.mode() & 0o022 == 0)
    };
    (fs::metadata(&path).is_ok_and(|meta| meta.is_file()) && path.ancestors().all(safe)).then_some(path)
}

// One-shot llama.cpp programs: they load a model on the GPU for one run and serve
// no HTTP API, so they report VRAM, CPU and RAM but no context or output buffers.
// (/proc/<pid>/comm is cut to 15 characters.)
pub const LLAMACPP_TOOLS: [&str; 5] = ["llama-tts", "llama-cli", "llama-mtmd-cli", "llama-run", "llama-simple"];

#[derive(Clone)]
pub struct Proc {
    pub pid: String,
    pub comm: String,
    pub cmdline: String,
}

fn classify(pid: &str, comm: &str, cmdline: &str) -> Option<&'static str> {
    static VLLM: OnceLock<Regex> = OnceLock::new();
    // Several runtimes ship an engine called llama-server (Ollama 0.3x, LM Studio),
    // so the owning systemd unit and the executable path decide, not the name.
    let cgroup = read(&format!("/proc/{pid}/cgroup"));
    if cgroup.contains("ollama.service")
        || comm == "ollama"
        || cmdline.contains("/ollama/")
        || cmdline.contains("/blobs/sha256-")
    {
        return Some("ollama");
    }
    if cmdline.contains(".lmstudio") || cmdline.contains("lm-studio") || comm.starts_with("lm-studio") {
        return Some("lmstudio");
    }
    if cgroup.contains("llama-server.service") || comm == "llama-server" || LLAMACPP_TOOLS.contains(&comm) {
        return Some("llamacpp");
    }
    // vLLM renames its engine and worker processes to VLLM::EngineCore, VLLM::Worker...
    let vllm = VLLM.get_or_init(|| Regex::new(r"\bvllm(\s+serve\b|\.entrypoints)").unwrap());
    if comm.to_lowercase().starts_with("vllm") || vllm.is_match(cmdline) {
        return Some("vllm");
    }
    None
}

/// Runtime processes, grouped by runtime id.
pub fn process_table() -> BTreeMap<&'static str, Vec<Proc>> {
    let mut groups: BTreeMap<&'static str, Vec<Proc>> = BTreeMap::new();
    for pid in pids() {
        let comm = comm(&pid);
        // vLLM runs as a Python program until it renames its workers.
        let maybe_vllm = comm.to_lowercase().starts_with("vllm") || comm.starts_with("python");
        if !matches!(comm.as_str(), "llama-server" | "ollama")
            && !LLAMACPP_TOOLS.contains(&comm.as_str())
            && !comm.starts_with("lm-studio")
            && !maybe_vllm
        {
            continue;
        }
        if !trusted(&pid) {
            continue;
        }
        let cmdline = cmdline(&pid);
        if comm.starts_with("python") && !cmdline.contains("vllm") {
            continue;
        }
        if let Some(runtime) = classify(&pid, &comm, &cmdline) {
            groups.entry(runtime).or_default().push(Proc { pid, comm, cmdline });
        }
    }
    groups
}

/// The field at `index` of /proc/<pid>/stat, counted after the "(comm)" field.
fn stat_field(pid: &str, index: usize) -> Option<String> {
    let stat = read(&format!("/proc/{pid}/stat"));
    let end = stat.rfind(')')?;
    stat.get(end + 2..)?.split_whitespace().nth(index).map(String::from)
}

pub fn ticks(pid: &str) -> u64 {
    let stat = read(&format!("/proc/{pid}/stat"));
    let Some(end) = stat.rfind(')') else { return 0 };
    let mut fields = stat.get(end + 2..).unwrap_or("").split_whitespace().skip(11);
    match (
        fields.next().and_then(|value| value.parse::<u64>().ok()),
        fields.next().and_then(|value| value.parse::<u64>().ok()),
    ) {
        (Some(user), Some(system)) => user + system,
        _ => 0,
    }
}

pub fn parent(pid: &str) -> Option<String> {
    stat_field(pid, 1)
}

fn kib_field(text: &str, key: &str) -> Option<u64> {
    text.lines()
        .find(|line| line.starts_with(key))
        .and_then(|line| line.split_whitespace().nth(1)?.parse::<u64>().ok())
        .map(|kib| kib * 1024)
}

pub fn pss(pid: &str) -> u64 {
    kib_field(&read(&format!("/proc/{pid}/smaps_rollup")), "Pss:")
        .or_else(|| kib_field(&read(&format!("/proc/{pid}/status")), "VmRSS:"))
        .unwrap_or(0)
}

pub fn model_from_cmdline(cmdline: &str) -> String {
    static MODEL: OnceLock<Regex> = OnceLock::new();
    let model = MODEL.get_or_init(|| Regex::new(r"(?:--model|-m)\s+(\S+)").unwrap());
    let Some(path) = model.captures(cmdline).map(|caps| caps[1].to_string()) else {
        return String::new();
    };
    let name = path.rsplit('/').next().unwrap_or(&path);
    clean(name.strip_suffix(".gguf").unwrap_or(name), 120)
}

// --- Clients: who is talking to a runtime right now ----------------------------

/// Owning pid of each wanted socket inode; stops scanning once all are found.
fn socket_owners(wanted: &HashSet<&str>) -> HashMap<String, String> {
    let mut owners = HashMap::new();
    for pid in pids() {
        let Ok(fds) = fs::read_dir(format!("/proc/{pid}/fd")) else { continue };
        for fd in fds.flatten() {
            let Ok(target) = fs::read_link(fd.path()) else { continue };
            let target = target.to_string_lossy();
            if let Some(inode) = target.strip_prefix("socket:[").and_then(|rest| rest.strip_suffix(']'))
                && wanted.contains(inode)
            {
                owners.insert(inode.to_string(), pid.clone());
            }
        }
        if owners.len() == wanted.len() {
            break;
        }
    }
    owners
}

pub fn client_label(pid: &str) -> Option<String> {
    let cmdline = read(&format!("/proc/{pid}/cmdline")).replace('\0', " ");
    let comm = comm(pid);
    if cmdline.contains("app.native") || cmdline.contains("simple-recipes") {
        return Some("Simple Recipes".into());
    }
    if cmdline.contains("/pi/") || comm == "pi" {
        return Some("pi".into());
    }
    if cmdline.contains("opencode") {
        return Some("opencode".into());
    }
    if cmdline.contains("kindle-reader") || cmdline.contains("KindleReader") || cmdline.contains("simple-reader") {
        return Some("Simple Reader".into());
    }
    if cmdline.contains("lm-studio") {
        return None;
    }
    Some(clean(&comm, 40)).filter(|label| !label.is_empty())
}

/// Programs with an established connection to a runtime's port, by runtime id.
pub fn clients_by_port(ports: &BTreeMap<&'static str, u16>) -> HashMap<&'static str, Vec<String>> {
    let wanted: HashMap<u16, &'static str> = ports.iter().map(|(runtime, port)| (*port, *runtime)).collect();
    let mut inodes = Vec::new();
    for table in ["/proc/net/tcp", "/proc/net/tcp6"] {
        for line in read(table).lines().skip(1) {
            let parts: Vec<&str> = line.split_whitespace().collect();
            if parts.len() < 10 || parts[3] != "01" {
                continue; // not ESTABLISHED
            }
            let remote = parts[2].rsplit(':').next().and_then(|port| u16::from_str_radix(port, 16).ok());
            if let Some(runtime) = remote.and_then(|port| wanted.get(&port)) {
                inodes.push((parts[9].to_string(), *runtime));
            }
        }
    }
    let mut found: HashMap<&'static str, Vec<String>> = HashMap::new();
    if inodes.is_empty() {
        return found;
    }
    let owners = socket_owners(&inodes.iter().map(|(inode, _)| inode.as_str()).collect());
    for (inode, runtime) in inodes {
        let label = owners.get(&inode).filter(|pid| trusted(pid)).and_then(|pid| client_label(pid));
        let labels = found.entry(runtime).or_default();
        if let Some(label) = label.filter(|label| !labels.contains(label)) {
            labels.push(label);
        }
    }
    found
}

/// The programs that started one-shot llama.cpp tools (they have no socket to trace).
pub fn tool_clients(processes: &[Proc]) -> Vec<String> {
    let mut found = Vec::new();
    for process in processes.iter().filter(|process| LLAMACPP_TOOLS.contains(&process.comm.as_str())) {
        let Some(parent) = parent(&process.pid) else { continue };
        if let Some(label) = trusted(&parent).then(|| client_label(&parent)).flatten()
            && !found.contains(&label)
        {
            found.push(label);
        }
    }
    found
}
