//! Hardware probing: OS, architecture, CPU cores, total and available RAM.
//!
//! Implemented with `std` plus one FFI call per platform, so the launcher keeps
//! zero external dependencies. Every value is optional: when a platform cannot
//! be probed we report `None` and the caller degrades gracefully rather than
//! inventing a number.

#[derive(Debug, Clone)]
pub struct SysInfo {
    pub os: &'static str,
    pub arch: &'static str,
    pub cores: usize,
    /// Bytes of physical RAM, if it could be determined.
    pub total_ram: Option<u64>,
    /// Bytes of RAM currently available, if it could be determined.
    pub avail_ram: Option<u64>,
}

pub const MIB: u64 = 1024 * 1024;
pub const GIB: u64 = 1024 * MIB;

impl SysInfo {
    pub fn probe() -> SysInfo {
        let (total, avail) = probe_memory();
        SysInfo {
            os: std::env::consts::OS,
            arch: std::env::consts::ARCH,
            cores: std::thread::available_parallelism()
                .map(|n| n.get())
                .unwrap_or(1),
            total_ram: total,
            avail_ram: avail,
        }
    }

    /// Threads to hand llama.cpp.
    ///
    /// llama.cpp is memory-bandwidth-bound on CPU inference, so using every
    /// logical core is usually *slower* than using the physical cores and it
    /// makes the machine unusable meanwhile. We leave headroom and cap the
    /// count, which matters on a portable tool that runs on unknown hardware.
    pub fn recommended_threads(&self) -> u32 {
        let c = self.cores;
        let t = if c <= 2 {
            c
        } else if c <= 4 {
            c - 1
        } else {
            // Assume SMT above 4 logical cores; half is a good proxy for
            // physical core count, and never fewer than 4.
            (c / 2).max(4)
        };
        t.clamp(1, 16) as u32
    }

    pub fn describe(&self) -> String {
        let fmt = |v: Option<u64>| match v {
            Some(b) => format!("{:.1} GiB", b as f64 / GIB as f64),
            None => "unknown".to_string(),
        };
        format!(
            "{}/{} | {} logical cores | RAM total {}, available {}",
            self.os,
            self.arch,
            self.cores,
            fmt(self.total_ram),
            fmt(self.avail_ram)
        )
    }
}

/// Verdict of the capability check. We deliberately never *promise* the model
/// will run -- CPU speed, swap pressure and other processes all matter.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Capability {
    /// Comfortable headroom.
    Ok,
    /// Should work, but tight. Carries a warning and a reduced context size.
    Tight { warning: String, ctx_cap: u32 },
    /// Very likely to fail or thrash swap. Still allowed with `--force`.
    Unlikely { warning: String, ctx_cap: u32 },
    /// RAM could not be determined; proceed without claims.
    Unknown,
}

/// Estimate the resident footprint of a run, in bytes.
///
/// Weights (the file size on disk, which is what gets mmapped) plus KV cache
/// plus compute buffers.
///
/// The KV figure is derived from the shipped model, Qwen3-4B-Instruct-2507:
/// 36 layers, 8 KV heads (GQA), head_dim 128, K and V, f16 =
/// `2 * 36 * 8 * 128 * 2 = 147456` bytes per token (144 KiB). Other 1.5B-4B
/// models are in the same order of magnitude, and erring high is the safe
/// direction for a capability check.
pub fn estimate_footprint(model_bytes: u64, ctx: u32) -> u64 {
    const KV_BYTES_PER_TOKEN: u64 = 144 * 1024;
    let kv = (ctx as u64) * KV_BYTES_PER_TOKEN;
    let overhead = 400 * MIB; // compute buffers, runtime, HTTP server
    model_bytes.saturating_add(kv).saturating_add(overhead)
}

/// Decide whether to run, and with what context ceiling.
pub fn assess(info: &SysInfo, model_bytes: u64, wanted_ctx: u32) -> Capability {
    let Some(total) = info.total_ram else {
        return Capability::Unknown;
    };
    let need = estimate_footprint(model_bytes, wanted_ctx);
    // Compare against available RAM when we have it, since another application
    // holding 8 GiB is the common real-world failure.
    let usable = info.avail_ram.unwrap_or(total).max(total / 4);

    if need + 512 * MIB <= usable {
        return Capability::Ok;
    }

    let smaller = shrink_ctx(wanted_ctx, model_bytes, usable);
    let need_gib = need as f64 / GIB as f64;
    let usable_gib = usable as f64 / GIB as f64;

    if estimate_footprint(model_bytes, smaller) <= usable {
        Capability::Tight {
            warning: format!(
                "estimated need {:.1} GiB at ctx {} but only {:.1} GiB is available; \
                 reducing context to {}",
                need_gib, wanted_ctx, usable_gib, smaller
            ),
            ctx_cap: smaller,
        }
    } else {
        Capability::Unlikely {
            warning: format!(
                "estimated need {:.1} GiB but only {:.1} GiB is available -- the model is \
                 larger than this machine's free RAM. Expect heavy swapping or an \
                 out-of-memory failure. Close other applications, or use a smaller \
                 quantisation.",
                need_gib, usable_gib
            ),
            ctx_cap: smaller,
        }
    }
}

/// Largest power-of-two-ish context that fits, floored at 512.
fn shrink_ctx(wanted: u32, model_bytes: u64, usable: u64) -> u32 {
    let mut ctx = wanted;
    while ctx > 512 {
        ctx /= 2;
        if estimate_footprint(model_bytes, ctx) <= usable {
            return ctx;
        }
    }
    512
}

// --------------------------------------------------------------------------
// Platform memory probes
// --------------------------------------------------------------------------

#[cfg(target_os = "linux")]
fn probe_memory() -> (Option<u64>, Option<u64>) {
    let Ok(text) = std::fs::read_to_string("/proc/meminfo") else {
        return (None, None);
    };
    let field = |name: &str| -> Option<u64> {
        for line in text.lines() {
            if let Some(rest) = line.strip_prefix(name) {
                let rest = rest.trim_start_matches(':').trim();
                let kb: u64 = rest.split_whitespace().next()?.parse().ok()?;
                return Some(kb * 1024);
            }
        }
        None
    };
    // MemAvailable is the kernel's own estimate and is far better than MemFree.
    (field("MemTotal"), field("MemAvailable").or_else(|| field("MemFree")))
}

#[cfg(windows)]
#[repr(C)]
struct MemoryStatusEx {
    length: u32,
    memory_load: u32,
    total_phys: u64,
    avail_phys: u64,
    total_page_file: u64,
    avail_page_file: u64,
    total_virtual: u64,
    avail_virtual: u64,
    avail_extended_virtual: u64,
}

#[cfg(windows)]
extern "system" {
    fn GlobalMemoryStatusEx(buffer: *mut MemoryStatusEx) -> i32;
}

#[cfg(windows)]
fn probe_memory() -> (Option<u64>, Option<u64>) {
    let mut st = MemoryStatusEx {
        length: std::mem::size_of::<MemoryStatusEx>() as u32,
        memory_load: 0,
        total_phys: 0,
        avail_phys: 0,
        total_page_file: 0,
        avail_page_file: 0,
        total_virtual: 0,
        avail_virtual: 0,
        avail_extended_virtual: 0,
    };
    // SAFETY: `st` is a correctly sized, correctly initialised MEMORYSTATUSEX
    // and the API only writes into it.
    let ok = unsafe { GlobalMemoryStatusEx(&mut st) } != 0;
    if ok {
        (Some(st.total_phys), Some(st.avail_phys))
    } else {
        (None, None)
    }
}

#[cfg(not(any(target_os = "linux", windows)))]
fn probe_memory() -> (Option<u64>, Option<u64>) {
    // macOS/BSD would need sysctl; PendriveAI v1 does not ship a macOS runtime,
    // so report unknown rather than guessing.
    (None, None)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn info(total_gib: f64, avail_gib: f64, cores: usize) -> SysInfo {
        SysInfo {
            os: "linux",
            arch: "x86_64",
            cores,
            total_ram: Some((total_gib * GIB as f64) as u64),
            avail_ram: Some((avail_gib * GIB as f64) as u64),
        }
    }

    #[test]
    fn probe_returns_sane_values_on_this_machine() {
        let i = SysInfo::probe();
        assert!(i.cores >= 1);
        assert!(!i.os.is_empty());
        if let Some(t) = i.total_ram {
            assert!(t > 256 * MIB, "implausible total RAM: {}", t);
        }
    }

    #[test]
    fn thread_recommendation_leaves_headroom_and_is_bounded() {
        let t = |c| info(16.0, 8.0, c).recommended_threads();
        assert_eq!(t(1), 1);
        assert_eq!(t(2), 2);
        assert_eq!(t(4), 3);
        assert_eq!(t(8), 4);
        assert_eq!(t(12), 6);
        assert_eq!(t(64), 16, "must be capped");
        for c in 1..=128 {
            let n = info(16.0, 8.0, c).recommended_threads();
            assert!((1..=16).contains(&n), "cores={} gave threads={}", c, n);
        }
    }

    #[test]
    fn plenty_of_ram_is_ok() {
        let m = 2_497_281_120u64; // the shipped Q4_K_M model
        assert_eq!(assess(&info(16.0, 12.0, 8), m, 4096), Capability::Ok);
    }

    #[test]
    fn tight_ram_reduces_context_instead_of_refusing() {
        let m = 2_497_281_120u64;
        match assess(&info(4.0, 3.1, 4), m, 8192) {
            Capability::Tight { ctx_cap, .. } => {
                assert!(ctx_cap < 8192 && ctx_cap >= 512, "ctx_cap={}", ctx_cap);
            }
            other => panic!("expected Tight, got {:?}", other),
        }
    }

    #[test]
    fn far_too_little_ram_is_flagged_unlikely_but_not_impossible() {
        let m = 2_497_281_120u64;
        match assess(&info(2.0, 0.6, 2), m, 4096) {
            Capability::Unlikely { warning, ctx_cap } => {
                assert!(warning.contains("larger than this machine"));
                assert_eq!(ctx_cap, 512);
            }
            other => panic!("expected Unlikely, got {:?}", other),
        }
    }

    #[test]
    fn unknown_ram_is_reported_not_guessed() {
        let i = SysInfo {
            os: "linux",
            arch: "x86_64",
            cores: 4,
            total_ram: None,
            avail_ram: None,
        };
        assert_eq!(assess(&i, 2_497_281_120, 4096), Capability::Unknown);
        assert!(i.describe().contains("unknown"));
    }

    #[test]
    fn footprint_grows_with_context() {
        let m = 1_000_000_000u64;
        assert!(estimate_footprint(m, 8192) > estimate_footprint(m, 2048));
        assert!(estimate_footprint(m, 512) > m);
    }

    #[test]
    fn shrink_never_returns_below_floor() {
        assert_eq!(shrink_ctx(4096, u64::MAX / 4, 1), 512);
        assert!(shrink_ctx(512, 1000, 1) == 512);
    }
}
