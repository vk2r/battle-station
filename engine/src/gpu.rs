//! GPU metrics through all-smi (NVIDIA via NVML, AMD via liball_smi_amd.so, Intel via i915/xe).

use std::collections::HashMap;
use std::fs;
use std::sync::OnceLock;

use all_smi::device::{GpuInfo, GpuReader, get_gpu_readers};
use regex::Regex;
use serde_json::{Value, json};

use crate::procs::read;

pub struct Gpu {
    readers: Vec<Box<dyn GpuReader>>,
    /// Every GPU this machine has, largest memory first.
    devices: Vec<Device>,
    /// The GPU this monitor follows: an index into `devices`.
    selected: Option<usize>,
}

/// One GPU: where to read it and the id the panel selects it by.
struct Device {
    /// Reader (driver) and the device's position in its listing; both are
    /// stable while the engine runs, so they address the device without
    /// relying on the uuid, which some drivers leave empty.
    reader: usize,
    index: usize,
    name: String,
    /// The uuid all-smi reports, used to attribute per-process memory.
    uuid: String,
    /// The id handed to the panel and back through `--gpu`: the all-smi uuid,
    /// or the PCI slot when the driver has no uuid.
    id: String,
    vendor: &'static str,
    total_memory: u64,
    /// PCI slot of the DRM card behind this GPU, for AMD spilled-memory accounting.
    drm_slot: Option<String>,
}

fn vendor_of(name: &str) -> &'static str {
    let name = name.to_lowercase();
    if name.contains("nvidia") {
        "nvidia"
    } else if name.contains("amd") || name.contains("radeon") || name.contains("advanced micro") {
        "amd"
    } else if name.contains("intel") {
        "intel"
    } else {
        ""
    }
}

/// The brand colour of a vendor, sent to the QML for the load ring and the bar
/// meters: NVIDIA green, AMD red, Intel blue; none for anything else.
fn color_of(vendor: &str) -> Option<&'static str> {
    match vendor {
        "nvidia" => Some("#76b900"),
        "amd" => Some("#ed1c24"),
        "intel" => Some("#0071c5"),
        _ => None,
    }
}

impl Gpu {
    pub fn new(preferred: Option<&str>) -> Self {
        let readers = get_gpu_readers();
        let mut devices: Vec<Device> = Vec::new();
        for (reader, gpu_reader) in readers.iter().enumerate() {
            for (index, info) in gpu_reader.get_gpu_info().into_iter().enumerate() {
                let vendor = vendor_of(&info.name);
                let slot = pci_slot(&info);
                devices.push(Device {
                    reader,
                    index,
                    name: info.name.clone(),
                    uuid: info.uuid.clone(),
                    id: if info.uuid.is_empty() {
                        slot.clone().unwrap_or_else(|| format!("{reader}:{index}"))
                    } else {
                        info.uuid.clone()
                    },
                    vendor,
                    total_memory: info.total_memory,
                    // amdgpu evicts buffers to system RAM when VRAM runs full;
                    // other drivers do not, so only AMD cards need a DRM slot.
                    drm_slot: if vendor == "amd" { slot.and_then(|slot| drm_slot(&slot)) } else { None },
                });
            }
        }
        // Largest memory first: the auto pick skips an iGPU next to the discrete GPU.
        devices.sort_by(|a, b| b.total_memory.cmp(&a.total_memory));
        // The card the panel picked, or the one with the largest memory.
        let selected = preferred
            .and_then(|id| devices.iter().position(|device| device.id == id))
            .or_else(|| (!devices.is_empty()).then_some(0));
        Gpu { readers, devices, selected }
    }

    fn selected(&self) -> Option<&Device> {
        self.selected.and_then(|index| self.devices.get(index))
    }

    fn info(&self) -> Option<GpuInfo> {
        let device = self.selected()?;
        self.readers[device.reader].get_gpu_info().into_iter().nth(device.index)
    }

    pub fn stats(&self) -> Option<Value> {
        let info = self.info()?;
        let vendor = vendor_of(&info.name);
        // all-smi reads AMD load from gpu_metrics, whose APU tables (v2.x) count
        // in hundredths of a percent, so an iGPU always shows 100 %; amdgpu's
        // own busy counter is right on every card. Socket power has the same
        // problem (watts on APUs, divided by 1000 as if milliwatts), so it
        // comes from amdgpu's hwmon sensor too.
        let amd_slot = (vendor == "amd").then(|| pci_slot(&info)).flatten();
        let busy = amd_slot.as_deref().and_then(amd_busy);
        let power = amd_slot.as_deref().and_then(amd_power);
        Some(json!({
            "vendor": vendor,
            "color": color_of(vendor),
            "vram_used": info.used_memory,
            "vram_total": info.total_memory,
            "busy": busy.unwrap_or(info.utilization),
            // 0 °C means the driver reported nothing.
            "temp": (info.temperature > 0).then_some(info.temperature),
            "power": power.unwrap_or(info.power_consumption),
            "slot": pci_slot(&info).unwrap_or_default(),
        }))
    }

    /// The GPUs on this machine, for the panel's settings selector.
    pub fn list(&self) -> Value {
        json!(
            self.devices
                .iter()
                .map(|device| json!({
                    "id": device.id,
                    "name": device.name,
                    "vendor": device.vendor,
                    "vram_total": device.total_memory,
                }))
                .collect::<Vec<_>>()
        )
    }

    /// GPU memory per process on the selected GPU, in bytes.
    pub fn process_vram(&self) -> HashMap<String, u64> {
        let mut usage = HashMap::new();
        let Some(device) = self.selected() else { return usage };
        let (processes, _) = self.readers[device.reader].get_gpu_processes();
        for process in
            processes.iter().filter(|process| process.device_uuid == device.uuid || process.device_uuid.is_empty())
        {
            *usage.entry(process.pid.to_string()).or_insert(0) += process.used_memory;
        }
        usage
    }

    /// Bytes of `pid`'s GPU memory that amdgpu moved to system RAM, on the GPU
    /// this monitor follows.
    pub fn spilled(&self, pid: &str) -> u64 {
        let Some(slot) = self.selected().and_then(|device| device.drm_slot.as_deref()) else { return 0 };
        spilled(pid, slot)
    }
}

/// The PCI slot an all-smi reader reports in its details, if any.
fn pci_slot(info: &GpuInfo) -> Option<String> {
    ["PCI Bus ID", "PCI Bus"].iter().find_map(|key| info.detail.get(*key)).cloned().filter(|slot| !slot.is_empty())
}

/// GPU load in percent from amdgpu's sysfs counter, for the card at a PCI slot
/// as all-smi's AMD reader names it (0000:04:00.0).
fn amd_busy(slot: &str) -> Option<f64> {
    let busy = read(&format!("/sys/bus/pci/devices/{slot}/gpu_busy_percent")).trim().parse::<f64>().ok()?;
    Some(busy.clamp(0.0, 100.0))
}

/// Power draw in watts from amdgpu's hwmon sensor (microwatts), for the card at
/// a PCI slot: the average where the card has one, else the current reading.
/// On an APU this is the whole package (PPT), as the GPU has no sensor of its own.
fn amd_power(slot: &str) -> Option<f64> {
    let hwmon = fs::read_dir(format!("/sys/bus/pci/devices/{slot}/hwmon")).ok()?.flatten().next()?.path();
    ["power1_average", "power1_input"].iter().find_map(|file| {
        let microwatts = read(&hwmon.join(file).to_string_lossy()).trim().parse::<u64>().ok()?;
        Some(microwatts as f64 / 1_000_000.0)
    })
}

/// The DRM card behind an all-smi PCI slot. DRM names slots like 0000:0b:00.0
/// and NVML like 00000000:0B:00.0, so they are compared without leading zeros;
/// when nothing matches, the largest AMD card wins (the old auto pick).
fn drm_slot(slot: &str) -> Option<String> {
    let cards = amd_drm_slots();
    let want = canonical_slot(slot);
    cards
        .iter()
        .find(|(known, _)| canonical_slot(known) == want)
        .or_else(|| cards.iter().find(|(known, _)| canonical_slot(known).ends_with(&want)))
        .or_else(|| cards.first())
        .map(|(known, _)| known.clone())
}

/// PCI slot in one comparable form: lowercase, each colon segment without leading zeros.
fn canonical_slot(slot: &str) -> String {
    slot.trim().to_lowercase().split(':').map(|part| part.trim_start_matches('0')).collect::<Vec<_>>().join(":")
}

/// PCI slot and VRAM size of every DRM card that reports VRAM (i.e. AMD), largest first.
fn amd_drm_slots() -> &'static Vec<(String, u64)> {
    static SLOTS: OnceLock<Vec<(String, u64)>> = OnceLock::new();
    SLOTS.get_or_init(|| {
        let mut cards: HashMap<String, u64> = HashMap::new();
        if let Ok(entries) = fs::read_dir("/sys/class/drm") {
            for entry in entries.flatten() {
                let device = entry.path().join("device");
                let Ok(size) = read(&device.join("mem_info_vram_total").to_string_lossy()).trim().parse::<u64>() else {
                    continue;
                };
                let uevent = read(&device.join("uevent").to_string_lossy());
                if let Some(slot) = uevent.lines().find_map(|line| line.strip_prefix("PCI_SLOT_NAME=")) {
                    // Connectors and render nodes share the card's device dir.
                    cards.insert(slot.trim().to_string(), size);
                }
            }
        }
        let mut slots: Vec<(String, u64)> = cards.into_iter().collect();
        slots.sort_by(|a, b| b.1.cmp(&a.1));
        slots
    })
}

// --- Spilled memory (amdgpu) ----------------------------------------------------
//
// all-smi reports what a process holds on the GPU. amdgpu also evicts buffers to
// system RAM when VRAM runs full; its DRM fdinfo tells what was requested
// (`amd-requested-vram`) and what is really resident (`drm-resident-vram`).
// Other drivers do not expose both, so they never report spilled memory.

fn kib(info: &str, keys: &[&str]) -> u64 {
    static FIELD: OnceLock<Regex> = OnceLock::new();
    let field = FIELD.get_or_init(|| Regex::new(r"(?m)^([\w-]+):\s*(\d+)\s*KiB").unwrap());
    let values: HashMap<&str, u64> = field
        .captures_iter(info)
        .filter_map(|caps| Some((caps.get(1)?.as_str(), caps[2].parse::<u64>().ok()?)))
        .collect();
    keys.iter().find_map(|key| values.get(key)).map_or(0, |value| value * 1024)
}

/// Bytes of `pid`'s GPU memory that amdgpu moved to system RAM on the DRM card
/// with the given PCI slot, one entry per DRM client.
fn spilled(pid: &str, slot: &str) -> u64 {
    let Ok(fds) = fs::read_dir(format!("/proc/{pid}/fd")) else { return 0 };
    let mut clients: HashMap<String, u64> = HashMap::new();
    for fd in fds.flatten() {
        let is_drm = fs::read_link(fd.path()).is_ok_and(|target| target.starts_with("/dev/dri/"));
        if !is_drm {
            continue;
        }
        let info = read(&format!("/proc/{pid}/fdinfo/{}", fd.file_name().to_string_lossy()));
        let client = info.lines().find_map(|line| line.strip_prefix("drm-client-id:")).map(str::trim);
        let other_gpu = info.contains("drm-pdev:") && !info.contains(&format!("drm-pdev:\t{slot}"));
        let (Some(client), false) = (client, other_gpu) else { continue };
        let resident = kib(&info, &["drm-resident-vram", "drm-memory-vram"]);
        let requested = resident.max(kib(&info, &["amd-requested-vram", "drm-total-vram", "drm-memory-vram"]));
        clients.insert(client.to_string(), requested - resident);
    }
    clients.values().sum()
}
