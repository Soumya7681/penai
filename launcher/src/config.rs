//! `config/config.json` loading, with defaults and range clamping.
//!
//! A missing config is normal (defaults are sane). A *malformed* config is an
//! error we report rather than silently ignore -- otherwise a typo would
//! quietly change which model runs.

use crate::json::Json;
use std::path::Path;

#[derive(Debug, Clone, PartialEq)]
pub struct Config {
    // --- server ---
    pub preferred_port: u16,
    pub port_scan_from: u16,
    pub port_scan_to: u16,

    // --- model / llama.cpp ---
    pub model_file: String,
    pub ctx_size: u32,
    pub threads: u32, // 0 = auto-detect
    pub parallel: u32,
    pub flash_attn: String, // on | off | auto
    pub extra_args: Vec<String>,

    // --- launcher ---
    pub open_browser: bool,
    pub startup_timeout_secs: u64,
    pub instance_port: u16,
    pub store_port: u16,
    pub portable_storage: bool,

    // --- network: the one part of PenAI that can reach outside the machine,
    //     and it stays off until someone deliberately turns it on ---
    pub network_enabled: bool,
    pub network_timeout_secs: u64,
    pub network_max_bytes: usize,

    // --- logging ---
    pub log_max_bytes: u64,
    pub log_keep: u32,

    // --- UI defaults, forwarded to the browser ---
    pub ui_temperature: f64,
    pub ui_top_p: f64,
    pub ui_max_tokens: u32,
    pub ui_system_prompt: String,
}

impl Default for Config {
    fn default() -> Self {
        Config {
            preferred_port: 8080,
            port_scan_from: 8081,
            port_scan_to: 8180,

            model_file: String::new(),
            ctx_size: 4096,
            threads: 0,
            parallel: 1,
            flash_attn: "auto".to_string(),
            extra_args: Vec::new(),

            open_browser: true,
            startup_timeout_secs: 300,
            instance_port: 47610,
            store_port: 47611,
            portable_storage: true,

            network_enabled: false,
            network_timeout_secs: 20,
            network_max_bytes: 2 * 1024 * 1024,

            log_max_bytes: 2 * 1024 * 1024,
            log_keep: 3,

            ui_temperature: 0.7,
            ui_top_p: 0.95,
            ui_max_tokens: 1024,
            ui_system_prompt: "You are PenAI, a helpful offline assistant running \
                               entirely on the user's own computer. Be concise and correct. \
                               When you write code, use fenced code blocks with a language tag."
                .to_string(),
        }
    }
}

/// Non-fatal complaints raised while reading the config.
pub type Warnings = Vec<String>;

impl Config {
    /// Load from disk. `Ok((cfg, warnings))`; `Err` only for unreadable or
    /// malformed JSON, which the caller turns into a clear startup failure.
    pub fn load(path: &Path) -> Result<(Config, Warnings), String> {
        if !path.exists() {
            return Ok((Config::default(), vec![]));
        }
        let text = std::fs::read_to_string(path)
            .map_err(|e| format!("cannot read {}: {}", path.display(), e))?;
        Self::from_str(&text)
            .map_err(|e| format!("{} is not valid JSON: {}", path.display(), e))
    }

    pub fn from_str(text: &str) -> Result<(Config, Warnings), String> {
        // A UTF-8 BOM is common when a config is edited with Notepad on Windows.
        let text = text.trim_start_matches('\u{feff}');
        let root = Json::parse(text)?;
        let mut c = Config::default();
        let mut w = Warnings::new();

        let take_u32 = |sec: Option<&Json>, key: &str, dst: &mut u32, w: &mut Warnings| {
            if let Some(v) = sec.and_then(|s| s.get(key)) {
                match v.as_u32() {
                    Some(n) => *dst = n,
                    None => w.push(format!("`{}` must be a non-negative integer; kept {}", key, dst)),
                }
            }
        };

        // -- server --
        let server = root.get("server");
        let mut p = c.preferred_port as u32;
        take_u32(server, "port", &mut p, &mut w);
        let mut from = c.port_scan_from as u32;
        take_u32(server, "portScanFrom", &mut from, &mut w);
        let mut to = c.port_scan_to as u32;
        take_u32(server, "portScanTo", &mut to, &mut w);
        c.preferred_port = clamp_port(p, c.preferred_port, "server.port", &mut w);
        c.port_scan_from = clamp_port(from, c.port_scan_from, "server.portScanFrom", &mut w);
        c.port_scan_to = clamp_port(to, c.port_scan_to, "server.portScanTo", &mut w);
        if c.port_scan_to < c.port_scan_from {
            w.push(format!(
                "server.portScanTo ({}) is below portScanFrom ({}); swapping them",
                c.port_scan_to, c.port_scan_from
            ));
            std::mem::swap(&mut c.port_scan_from, &mut c.port_scan_to);
        }

        // -- llama --
        let llama = root.get("llama");
        if let Some(v) = root.get("model").and_then(|m| m.get("file")).and_then(Json::as_str) {
            c.model_file = v.to_string();
        }
        take_u32(llama, "ctxSize", &mut c.ctx_size, &mut w);
        take_u32(llama, "threads", &mut c.threads, &mut w);
        take_u32(llama, "parallel", &mut c.parallel, &mut w);
        if let Some(v) = llama.and_then(|l| l.get("flashAttn")).and_then(Json::as_str) {
            match v {
                "on" | "off" | "auto" => c.flash_attn = v.to_string(),
                other => w.push(format!(
                    "llama.flashAttn must be on/off/auto, got `{}`; kept `{}`",
                    other, c.flash_attn
                )),
            }
        }
        if let Some(Json::Arr(a)) = llama.and_then(|l| l.get("extraArgs")) {
            for item in a {
                match item.as_str() {
                    Some(s) if !s.trim().is_empty() => c.extra_args.push(s.to_string()),
                    _ => w.push("llama.extraArgs entries must be non-empty strings".into()),
                }
            }
        }

        // Clamp to values llama.cpp and this machine can actually honour.
        if c.ctx_size != 0 && !(512..=131_072).contains(&c.ctx_size) {
            w.push(format!(
                "llama.ctxSize {} out of range 512..131072; using 4096",
                c.ctx_size
            ));
            c.ctx_size = 4096;
        }
        if c.threads > 256 {
            w.push(format!("llama.threads {} is implausible; using auto", c.threads));
            c.threads = 0;
        }
        if c.parallel == 0 || c.parallel > 16 {
            w.push(format!("llama.parallel {} out of range 1..16; using 1", c.parallel));
            c.parallel = 1;
        }

        // -- launcher --
        let l = root.get("launcher");
        if let Some(v) = l.and_then(|x| x.get("openBrowser")).and_then(Json::as_bool) {
            c.open_browser = v;
        }
        if let Some(v) = l.and_then(|x| x.get("portableStorage")).and_then(Json::as_bool) {
            c.portable_storage = v;
        }
        let mut t = c.startup_timeout_secs as u32;
        take_u32(l, "startupTimeoutSecs", &mut t, &mut w);
        c.startup_timeout_secs = (t as u64).clamp(10, 3600);
        let mut ip = c.instance_port as u32;
        take_u32(l, "instancePort", &mut ip, &mut w);
        c.instance_port = clamp_port(ip, c.instance_port, "launcher.instancePort", &mut w);
        let mut sp = c.store_port as u32;
        take_u32(l, "storePort", &mut sp, &mut w);
        c.store_port = clamp_port(sp, c.store_port, "launcher.storePort", &mut w);

        // -- network --
        let n = root.get("network");
        if let Some(v) = n.and_then(|x| x.get("enabled")).and_then(Json::as_bool) {
            c.network_enabled = v;
        }
        let mut nt = c.network_timeout_secs as u32;
        take_u32(n, "timeoutSecs", &mut nt, &mut w);
        c.network_timeout_secs = (nt as u64).clamp(5, 120);
        let mut nb = (c.network_max_bytes / 1024) as u32;
        take_u32(n, "maxKilobytes", &mut nb, &mut w);
        c.network_max_bytes = (nb as usize).clamp(16, 32 * 1024) * 1024;

        // -- logging --
        let lg = root.get("logging");
        if let Some(v) = lg.and_then(|x| x.get("maxFileBytes")).and_then(Json::as_f64) {
            if v >= 65536.0 && v <= 268_435_456.0 {
                c.log_max_bytes = v as u64;
            } else {
                w.push(format!(
                    "logging.maxFileBytes {} out of range 65536..268435456; using {}",
                    v, c.log_max_bytes
                ));
            }
        }
        take_u32(lg, "keepFiles", &mut c.log_keep, &mut w);
        if c.log_keep > 20 {
            w.push(format!("logging.keepFiles {} capped to 20", c.log_keep));
            c.log_keep = 20;
        }

        // -- ui --
        let ui = root.get("ui");
        if let Some(v) = ui.and_then(|x| x.get("temperature")).and_then(Json::as_f64) {
            if (0.0..=2.0).contains(&v) {
                c.ui_temperature = v;
            } else {
                w.push(format!("ui.temperature {} out of range 0..2; kept default", v));
            }
        }
        if let Some(v) = ui.and_then(|x| x.get("topP")).and_then(Json::as_f64) {
            if (0.0..=1.0).contains(&v) {
                c.ui_top_p = v;
            } else {
                w.push(format!("ui.topP {} out of range 0..1; kept default", v));
            }
        }
        take_u32(ui, "maxTokens", &mut c.ui_max_tokens, &mut w);
        if c.ui_max_tokens == 0 || c.ui_max_tokens > 32_768 {
            w.push(format!(
                "ui.maxTokens {} out of range 1..32768; using 1024",
                c.ui_max_tokens
            ));
            c.ui_max_tokens = 1024;
        }
        if let Some(v) = ui.and_then(|x| x.get("systemPrompt")).and_then(Json::as_str) {
            c.ui_system_prompt = v.to_string();
        }

        if c.instance_port == c.store_port {
            w.push(format!(
                "launcher.instancePort and launcher.storePort are both {}; moving storePort to {}",
                c.store_port,
                c.store_port.wrapping_add(1)
            ));
            c.store_port = c.store_port.wrapping_add(1).max(1024);
        }

        Ok((c, w))
    }

    /// The document handed to the browser as `web/runtime-config.json`.
    pub fn ui_runtime_json(&self, llama_port: u16, store_port: Option<u16>, model_name: &str, engine: &str) -> String {
        Json::obj(vec![
            // Empty string = same origin. The UI never talks to another host.
            ("apiBase", Json::s("")),
            (
                "storeBase",
                match store_port {
                    Some(p) => Json::s(format!("http://127.0.0.1:{}", p)),
                    None => Json::Null,
                },
            ),
            ("llamaPort", Json::n(llama_port as f64)),
            ("modelName", Json::s(model_name)),
            ("engineVersion", Json::s(engine)),
            ("offline", Json::Bool(true)),
            (
                "defaults",
                Json::obj(vec![
                    ("temperature", Json::n(self.ui_temperature)),
                    ("topP", Json::n(self.ui_top_p)),
                    ("maxTokens", Json::n(self.ui_max_tokens as f64)),
                    ("ctxSize", Json::n(self.ctx_size as f64)),
                    ("systemPrompt", Json::s(self.ui_system_prompt.clone())),
                ]),
            ),
        ])
        .dump()
    }
}

fn clamp_port(v: u32, fallback: u16, name: &str, w: &mut Warnings) -> u16 {
    // Ports below 1024 need privileges we must never ask for.
    if (1024..=65535).contains(&v) {
        v as u16
    } else {
        w.push(format!(
            "{} {} out of range 1024..65535; using {}",
            name, v, fallback
        ));
        fallback
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn defaults_are_localhost_and_conservative() {
        let c = Config::default();
        assert_eq!(c.preferred_port, 8080);
        assert_eq!(c.ctx_size, 4096);
        assert_eq!(c.threads, 0, "0 means auto-detect");
        assert_eq!(c.parallel, 1);
        assert!(c.open_browser);
    }

    #[test]
    fn missing_file_yields_defaults_without_error() {
        let p = std::env::temp_dir().join("pai-definitely-absent-config.json");
        let (c, w) = Config::load(&p).unwrap();
        assert_eq!(c, Config::default());
        assert!(w.is_empty());
    }

    #[test]
    fn reads_a_full_config() {
        let (c, w) = Config::from_str(
            r#"{
              "server": { "port": 9090, "portScanFrom": 9091, "portScanTo": 9099 },
              "model":  { "file": "custom.gguf" },
              "llama":  { "ctxSize": 8192, "threads": 6, "parallel": 2,
                          "flashAttn": "on", "extraArgs": ["--no-warmup"] },
              "launcher": { "openBrowser": false, "startupTimeoutSecs": 120,
                            "instancePort": 47700, "storePort": 47701,
                            "portableStorage": false },
              "logging": { "maxFileBytes": 1048576, "keepFiles": 5 },
              "ui": { "temperature": 0.3, "topP": 0.8, "maxTokens": 2048 }
            }"#,
        )
        .unwrap();
        assert!(w.is_empty(), "unexpected warnings: {:?}", w);
        assert_eq!(c.preferred_port, 9090);
        assert_eq!(c.model_file, "custom.gguf");
        assert_eq!(c.ctx_size, 8192);
        assert_eq!(c.threads, 6);
        assert_eq!(c.parallel, 2);
        assert_eq!(c.flash_attn, "on");
        assert_eq!(c.extra_args, vec!["--no-warmup"]);
        assert!(!c.open_browser);
        assert!(!c.portable_storage);
        assert_eq!(c.startup_timeout_secs, 120);
        assert_eq!(c.log_keep, 5);
        assert_eq!(c.ui_max_tokens, 2048);
    }

    #[test]
    fn malformed_json_is_an_error_not_a_silent_default() {
        assert!(Config::from_str("{ not json").is_err());
        assert!(Config::from_str("").is_err());
    }

    #[test]
    fn bom_prefixed_config_still_parses() {
        let (c, _) = Config::from_str("\u{feff}{\"server\":{\"port\":8123}}").unwrap();
        assert_eq!(c.preferred_port, 8123);
    }

    #[test]
    fn out_of_range_values_are_clamped_with_warnings() {
        let (c, w) = Config::from_str(
            r#"{ "server": {"port": 80, "portScanFrom": 9000, "portScanTo": 8000},
                 "llama": {"ctxSize": 99, "threads": 9999, "parallel": 0},
                 "ui": {"temperature": 9.0, "topP": 5.0, "maxTokens": 0},
                 "logging": {"keepFiles": 999} }"#,
        )
        .unwrap();
        assert_eq!(c.preferred_port, 8080, "privileged port must be refused");
        assert_eq!(c.ctx_size, 4096);
        assert_eq!(c.threads, 0);
        assert_eq!(c.parallel, 1);
        assert_eq!(c.ui_max_tokens, 1024);
        assert_eq!(c.log_keep, 20);
        assert_eq!(c.ui_temperature, 0.7);
        assert!(c.port_scan_from <= c.port_scan_to, "range must be ordered");
        assert!(w.len() >= 7, "each clamp should be reported, got {:?}", w);
    }

    #[test]
    fn wrong_types_warn_and_keep_defaults() {
        let (c, w) = Config::from_str(
            r#"{ "llama": {"ctxSize": "big", "flashAttn": "maybe", "extraArgs": [1, ""]} }"#,
        )
        .unwrap();
        assert_eq!(c.ctx_size, 4096);
        assert_eq!(c.flash_attn, "auto");
        assert!(c.extra_args.is_empty());
        assert!(w.len() >= 3, "{:?}", w);
    }

    #[test]
    fn colliding_helper_ports_are_separated() {
        let (c, w) = Config::from_str(
            r#"{ "launcher": {"instancePort": 47610, "storePort": 47610} }"#,
        )
        .unwrap();
        assert_ne!(c.instance_port, c.store_port);
        assert!(w.iter().any(|m| m.contains("storePort")));
    }

    #[test]
    fn ui_runtime_json_is_same_origin_and_offline() {
        let c = Config::default();
        let s = c.ui_runtime_json(8080, Some(47611), "model.gguf", "b10549");
        let v = Json::parse(&s).unwrap();
        assert_eq!(v.get("apiBase").and_then(Json::as_str), Some(""));
        assert_eq!(v.get("offline").and_then(Json::as_bool), Some(true));
        assert_eq!(
            v.get("storeBase").and_then(Json::as_str),
            Some("http://127.0.0.1:47611")
        );
        // No non-loopback host may ever appear in what we hand the browser.
        assert!(!s.contains("0.0.0.0"));
        assert!(!s.contains("http://") || s.matches("http://").count() == 1);
        assert!(s.contains("127.0.0.1"));
    }

    #[test]
    fn ui_runtime_json_handles_disabled_store() {
        let c = Config::default();
        let s = c.ui_runtime_json(8080, None, "m.gguf", "b1");
        let v = Json::parse(&s).unwrap();
        assert_eq!(v.get("storeBase"), Some(&Json::Null));
    }
}
