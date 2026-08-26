//! Optional portable chat storage.
//!
//! Browser storage (IndexedDB) is keyed to the origin *and the host machine*, so
//! chats saved on one computer do not travel with the pendrive. This tiny
//! sidecar closes that gap: it persists a single JSON blob to
//! `data/chats/chats.json` on the drive itself, with no database, no Node.js and
//! no Python.
//!
//! Security posture:
//!   * binds 127.0.0.1 only;
//!   * requires a loopback `Host` header (blocks DNS-rebinding);
//!   * `Origin`, when present, must be the exact llama-server origin;
//!   * only fixed routes exist -- no request-supplied path ever reaches the
//!     filesystem, so path traversal is structurally impossible;
//!   * request bodies are capped.
//!
//! If it cannot start (read-only drive, port taken) the UI silently falls back
//! to IndexedDB, so this is an enhancement and never a hard dependency.

use crate::json::Json;
use crate::logging::Logger;
use crate::net::loopback;
use std::io::{BufReader, Read, Write};
use std::net::{TcpListener, TcpStream};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::Arc;
use std::time::Duration;

/// Hard cap on a stored payload. Generous for text chats, small enough that a
/// runaway client cannot fill the drive.
pub const MAX_BODY: usize = 32 * 1024 * 1024;
const MAX_HEADERS: usize = 64;
const MAX_HEADER_LINE: usize = 8 * 1024;
const MAX_CONNS: usize = 16;

pub struct Store {
    pub port: u16,
    stop: Arc<AtomicBool>,
}

impl Store {
    /// Start the sidecar. `allowed_origins` are the exact `Origin` values the
    /// browser may present (the llama-server origin, in both host spellings).
    pub fn start(
        port: u16,
        chats_dir: PathBuf,
        allowed_origins: Vec<String>,
        log: Logger,
    ) -> std::io::Result<Store> {
        let listener = TcpListener::bind(loopback(port))?;
        let port = listener.local_addr()?.port();
        let stop = Arc::new(AtomicBool::new(false));
        let stop_thread = Arc::clone(&stop);
        let conns = Arc::new(AtomicUsize::new(0));

        std::thread::spawn(move || {
            let file = chats_dir.join("chats.json");
            for incoming in listener.incoming() {
                if stop_thread.load(Ordering::SeqCst) {
                    break;
                }
                let Ok(stream) = incoming else { continue };
                if conns.load(Ordering::SeqCst) >= MAX_CONNS {
                    // Shed load rather than spawn unbounded threads.
                    let _ = respond(
                        stream,
                        503,
                        "text/plain",
                        b"busy",
                        None,
                    );
                    continue;
                }
                conns.fetch_add(1, Ordering::SeqCst);
                let file = file.clone();
                let origins = allowed_origins.clone();
                let log = log.clone();
                let conns2 = Arc::clone(&conns);
                std::thread::spawn(move || {
                    if let Err(e) = handle(stream, &file, &origins) {
                        log.trace(format!("store: connection error: {}", e));
                    }
                    conns2.fetch_sub(1, Ordering::SeqCst);
                });
            }
        });

        Ok(Store { port, stop })
    }

    pub fn shutdown(&self) {
        self.stop.store(true, Ordering::SeqCst);
        // Unblock the accept loop with a throwaway connection.
        let _ = std::net::TcpStream::connect_timeout(
            &loopback(self.port),
            Duration::from_millis(300),
        );
    }
}

struct Request {
    method: String,
    path: String,
    host: Option<String>,
    origin: Option<String>,
    content_length: usize,
}

fn handle(s: TcpStream, file: &Path, allowed: &[String]) -> std::io::Result<()> {
    s.set_read_timeout(Some(Duration::from_secs(15)))?;
    s.set_write_timeout(Some(Duration::from_secs(15)))?;

    let mut reader = BufReader::new(s.try_clone()?);
    let req = match parse_request(&mut reader)? {
        Some(r) => r,
        None => return respond(s, 400, "text/plain", b"bad request", None),
    };

    // --- DNS-rebinding guard: the Host header must be loopback. ---
    let host_ok = req
        .host
        .as_deref()
        .map(is_loopback_host)
        .unwrap_or(false);
    if !host_ok {
        return respond(s, 421, "text/plain", b"bad host", None);
    }

    // --- Cross-origin guard. Absent Origin is fine (same-origin GET, curl). ---
    let origin = req.origin.clone();
    if let Some(o) = &origin {
        if !allowed.iter().any(|a| a == o) {
            return respond(s, 403, "text/plain", b"origin not allowed", None);
        }
    }
    let cors = origin.filter(|o| allowed.iter().any(|a| a == o));

    match (req.method.as_str(), req.path.as_str()) {
        ("OPTIONS", _) => respond(s, 204, "text/plain", b"", cors),

        ("GET", "/api/health") => {
            let body = Json::obj(vec![
                ("ok", Json::Bool(true)),
                // Wire identity, not a brand name: the page matches on this
                // exact string, and an older packaged drive serves a page that
                // only knows the pre-rename value.
                ("kind", Json::s("pendriveai-store")),
                ("maxBody", Json::n(MAX_BODY as f64)),
            ])
            .dump();
            respond(s, 200, "application/json", body.as_bytes(), cors)
        }

        ("GET", "/api/chats") => match std::fs::read(file) {
            Ok(bytes) => respond(s, 200, "application/json", &bytes, cors),
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => {
                let empty = Json::obj(vec![
                    ("version", Json::n(1.0)),
                    ("chats", Json::Arr(vec![])),
                    ("messages", Json::Arr(vec![])),
                ])
                .dump();
                respond(s, 200, "application/json", empty.as_bytes(), cors)
            }
            Err(e) => {
                let msg = format!("{{\"error\":\"cannot read store: {}\"}}", e);
                respond(s, 500, "application/json", msg.as_bytes(), cors)
            }
        },

        ("PUT", "/api/chats") | ("POST", "/api/chats") => {
            if req.content_length > MAX_BODY {
                return respond(
                    s,
                    413,
                    "application/json",
                    b"{\"error\":\"payload too large\"}",
                    cors,
                );
            }
            let mut body = vec![0u8; req.content_length];
            reader.read_exact(&mut body)?;

            // Refuse to persist anything that is not valid JSON: a corrupt file
            // would break the UI on the next launch.
            let text = match std::str::from_utf8(&body) {
                Ok(t) => t,
                Err(_) => {
                    return respond(
                        s,
                        400,
                        "application/json",
                        b"{\"error\":\"body is not UTF-8\"}",
                        cors,
                    )
                }
            };
            if let Err(e) = Json::parse(text) {
                let msg = format!("{{\"error\":\"body is not valid JSON: {}\"}}", e);
                return respond(s, 400, "application/json", msg.as_bytes(), cors);
            }

            match write_atomic(file, &body) {
                Ok(()) => respond(
                    s,
                    200,
                    "application/json",
                    format!("{{\"ok\":true,\"bytes\":{}}}", body.len()).as_bytes(),
                    cors,
                ),
                Err(e) => {
                    let msg = format!(
                        "{{\"error\":\"cannot write store (drive read-only or full): {}\"}}",
                        e
                    );
                    respond(s, 507, "application/json", msg.as_bytes(), cors)
                }
            }
        }

        _ => respond(s, 404, "application/json", b"{\"error\":\"not found\"}", cors),
    }
}

/// Write via a temporary file plus rename so a yanked drive cannot leave a
/// half-written chat history behind.
fn write_atomic(file: &Path, bytes: &[u8]) -> std::io::Result<()> {
    if let Some(dir) = file.parent() {
        std::fs::create_dir_all(dir)?;
    }
    let tmp = file.with_extension("json.tmp");
    {
        let mut f = std::fs::File::create(&tmp)?;
        f.write_all(bytes)?;
        f.sync_all()?;
    }
    // std::fs::rename replaces an existing destination on both Unix and Windows.
    match std::fs::rename(&tmp, file) {
        Ok(()) => Ok(()),
        Err(e) => {
            let _ = std::fs::remove_file(&tmp);
            Err(e)
        }
    }
}

fn parse_request(reader: &mut BufReader<TcpStream>) -> std::io::Result<Option<Request>> {
    let mut line = String::new();
    if read_line_capped(reader, &mut line)? == 0 {
        return Ok(None);
    }
    let mut parts = line.trim_end().split_whitespace();
    let (Some(method), Some(path)) = (parts.next(), parts.next()) else {
        return Ok(None);
    };
    let mut req = Request {
        method: method.to_ascii_uppercase(),
        // Strip any query string; routes are exact matches.
        path: path.split('?').next().unwrap_or(path).to_string(),
        host: None,
        origin: None,
        content_length: 0,
    };

    for _ in 0..MAX_HEADERS {
        line.clear();
        if read_line_capped(reader, &mut line)? == 0 {
            break;
        }
        let l = line.trim_end();
        if l.is_empty() {
            break;
        }
        let Some((k, v)) = l.split_once(':') else { continue };
        let (k, v) = (k.trim().to_ascii_lowercase(), v.trim().to_string());
        match k.as_str() {
            "host" => req.host = Some(v),
            "origin" => req.origin = Some(v),
            "content-length" => {
                req.content_length = v.parse().unwrap_or(0);
            }
            _ => {}
        }
    }
    Ok(Some(req))
}

fn read_line_capped(reader: &mut BufReader<TcpStream>, out: &mut String) -> std::io::Result<usize> {
    let mut buf = Vec::new();
    let mut total = 0usize;
    loop {
        let mut byte = [0u8; 1];
        match reader.read(&mut byte) {
            Ok(0) => break,
            Ok(_) => {
                total += 1;
                if byte[0] == b'\n' {
                    buf.push(byte[0]);
                    break;
                }
                buf.push(byte[0]);
                if total > MAX_HEADER_LINE {
                    return Err(std::io::Error::new(
                        std::io::ErrorKind::InvalidData,
                        "header line too long",
                    ));
                }
            }
            Err(e) => return Err(e),
        }
    }
    out.push_str(&String::from_utf8_lossy(&buf));
    Ok(total)
}

fn is_loopback_host(host: &str) -> bool {
    let h = host.rsplit_once(':').map(|(a, _)| a).unwrap_or(host);
    let h = h.trim_start_matches('[').trim_end_matches(']');
    matches!(h, "127.0.0.1" | "localhost" | "::1")
}

fn respond(
    mut s: TcpStream,
    status: u16,
    content_type: &str,
    body: &[u8],
    cors_origin: Option<String>,
) -> std::io::Result<()> {
    let reason = match status {
        200 => "OK",
        204 => "No Content",
        400 => "Bad Request",
        403 => "Forbidden",
        404 => "Not Found",
        413 => "Payload Too Large",
        421 => "Misdirected Request",
        500 => "Internal Server Error",
        503 => "Service Unavailable",
        507 => "Insufficient Storage",
        _ => "Error",
    };
    let mut head = format!(
        "HTTP/1.1 {} {}\r\nContent-Type: {}\r\nContent-Length: {}\r\n\
         Cache-Control: no-store\r\nX-Content-Type-Options: nosniff\r\n\
         Connection: close\r\n",
        status,
        reason,
        content_type,
        body.len()
    );
    if let Some(o) = cors_origin {
        head.push_str(&format!(
            "Access-Control-Allow-Origin: {}\r\n\
             Access-Control-Allow-Methods: GET, PUT, POST, OPTIONS\r\n\
             Access-Control-Allow-Headers: Content-Type\r\n\
             Access-Control-Max-Age: 600\r\nVary: Origin\r\n",
            o
        ));
    }
    head.push_str("\r\n");
    s.write_all(head.as_bytes())?;
    s.write_all(body)?;
    s.flush()?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;


    fn tmpdir(tag: &str) -> PathBuf {
        let p = std::env::temp_dir().join(format!("pai-store-{}-{}", tag, std::process::id()));
        std::fs::create_dir_all(&p).unwrap();
        p
    }

    fn boot(tag: &str) -> (Store, PathBuf, String) {
        let dir = tmpdir(tag);
        let origin = "http://127.0.0.1:8080".to_string();
        let log = Logger::new(dir.join("t.log"), 65536, 1, false);
        let s = Store::start(0, dir.clone(), vec![origin.clone()], log).unwrap();
        (s, dir, origin)
    }

    /// Raw request helper: returns (status_line, body).
    fn raw(port: u16, req: &str) -> (String, String) {
        let mut c = TcpStream::connect(loopback(port)).unwrap();
        c.set_read_timeout(Some(Duration::from_secs(5))).unwrap();
        c.write_all(req.as_bytes()).unwrap();
        c.flush().unwrap();
        let mut out = String::new();
        let _ = c.read_to_string(&mut out);
        let status = out.lines().next().unwrap_or("").to_string();
        let body = out.split("\r\n\r\n").nth(1).unwrap_or("").to_string();
        (status, body)
    }

    fn get(port: u16, path: &str, origin: Option<&str>) -> (String, String) {
        let o = origin
            .map(|o| format!("Origin: {}\r\n", o))
            .unwrap_or_default();
        raw(
            port,
            &format!(
                "GET {} HTTP/1.1\r\nHost: 127.0.0.1:{}\r\n{}Connection: close\r\n\r\n",
                path, port, o
            ),
        )
    }

    fn put(port: u16, path: &str, body: &str, origin: Option<&str>) -> (String, String) {
        let o = origin
            .map(|o| format!("Origin: {}\r\n", o))
            .unwrap_or_default();
        raw(
            port,
            &format!(
                "PUT {} HTTP/1.1\r\nHost: 127.0.0.1:{}\r\n{}Content-Type: application/json\r\n\
                 Content-Length: {}\r\nConnection: close\r\n\r\n{}",
                path,
                port,
                o,
                body.len(),
                body
            ),
        )
    }

    #[test]
    fn health_reports_ok() {
        let (s, dir, _) = boot("health");
        let (st, body) = get(s.port, "/api/health", None);
        assert!(st.contains("200"), "{}", st);
        assert!(body.contains("pendriveai-store"), "{}", body);
        s.shutdown();
        std::fs::remove_dir_all(&dir).ok();
    }

    #[test]
    fn empty_store_returns_empty_document() {
        let (s, dir, o) = boot("empty");
        let (st, body) = get(s.port, "/api/chats", Some(&o));
        assert!(st.contains("200"));
        let v = Json::parse(&body).unwrap();
        assert_eq!(v.get("version").and_then(Json::as_u32), Some(1));
        assert_eq!(v.get("chats"), Some(&Json::Arr(vec![])));
        s.shutdown();
        std::fs::remove_dir_all(&dir).ok();
    }

    #[test]
    fn round_trips_a_payload_to_the_drive() {
        let (s, dir, o) = boot("roundtrip");
        let payload = r#"{"version":1,"chats":[{"id":"c1","title":"Hi"}],"messages":[]}"#;
        let (st, body) = put(s.port, "/api/chats", payload, Some(&o));
        assert!(st.contains("200"), "{} / {}", st, body);

        // It must actually be on disk, not just in memory.
        let on_disk = std::fs::read_to_string(dir.join("chats.json")).unwrap();
        assert_eq!(on_disk, payload);

        let (st2, body2) = get(s.port, "/api/chats", Some(&o));
        assert!(st2.contains("200"));
        assert_eq!(body2, payload);
        s.shutdown();
        std::fs::remove_dir_all(&dir).ok();
    }

    #[test]
    fn rejects_invalid_json_so_the_file_never_corrupts() {
        let (s, dir, o) = boot("badjson");
        let (st, _) = put(s.port, "/api/chats", "{not json", Some(&o));
        assert!(st.contains("400"), "{}", st);
        assert!(!dir.join("chats.json").exists(), "nothing should be written");
        s.shutdown();
        std::fs::remove_dir_all(&dir).ok();
    }

    #[test]
    fn rejects_foreign_origin() {
        let (s, dir, _) = boot("origin");
        let (st, _) = put(
            s.port,
            "/api/chats",
            "{\"a\":1}",
            Some("http://evil.example.com"),
        );
        assert!(st.contains("403"), "{}", st);
        assert!(!dir.join("chats.json").exists());
        s.shutdown();
        std::fs::remove_dir_all(&dir).ok();
    }

    #[test]
    fn rejects_non_loopback_host_header() {
        let (s, dir, _) = boot("host");
        let (st, _) = raw(
            s.port,
            "GET /api/chats HTTP/1.1\r\nHost: attacker.example.com\r\nConnection: close\r\n\r\n",
        );
        assert!(st.contains("421"), "{}", st);
        s.shutdown();
        std::fs::remove_dir_all(&dir).ok();
    }

    #[test]
    fn rejects_oversized_declared_body() {
        let (s, dir, o) = boot("toobig");
        let (st, _) = raw(
            s.port,
            &format!(
                "PUT /api/chats HTTP/1.1\r\nHost: 127.0.0.1\r\nOrigin: {}\r\n\
                 Content-Length: {}\r\nConnection: close\r\n\r\n",
                o,
                MAX_BODY + 1
            ),
        );
        assert!(st.contains("413"), "{}", st);
        s.shutdown();
        std::fs::remove_dir_all(&dir).ok();
    }

    #[test]
    fn unknown_route_is_404_and_touches_no_files() {
        let (s, dir, o) = boot("404");
        for p in [
            "/api/nope",
            "/",
            "/../../etc/passwd",
            "/api/chats/../../secret",
        ] {
            let (st, _) = get(s.port, p, Some(&o));
            assert!(st.contains("404"), "{} -> {}", p, st);
        }
        s.shutdown();
        std::fs::remove_dir_all(&dir).ok();
    }

    #[test]
    fn preflight_returns_cors_headers() {
        let (s, dir, o) = boot("preflight");
        let (st, _) = raw(
            s.port,
            &format!(
                "OPTIONS /api/chats HTTP/1.1\r\nHost: 127.0.0.1\r\nOrigin: {}\r\n\
                 Access-Control-Request-Method: PUT\r\nConnection: close\r\n\r\n",
                o
            ),
        );
        assert!(st.contains("204"), "{}", st);
        s.shutdown();
        std::fs::remove_dir_all(&dir).ok();
    }

    #[test]
    fn atomic_write_leaves_no_temp_file() {
        let d = tmpdir("atomic");
        let f = d.join("chats.json");
        write_atomic(&f, b"{\"a\":1}").unwrap();
        write_atomic(&f, b"{\"a\":2}").unwrap();
        assert_eq!(std::fs::read_to_string(&f).unwrap(), "{\"a\":2}");
        let leftovers: Vec<_> = std::fs::read_dir(&d)
            .unwrap()
            .flatten()
            .map(|e| e.file_name().to_string_lossy().to_string())
            .filter(|n| n.contains("tmp"))
            .collect();
        assert!(leftovers.is_empty(), "temp files left: {:?}", leftovers);
        std::fs::remove_dir_all(&d).ok();
    }

    #[test]
    fn loopback_host_detection() {
        assert!(is_loopback_host("127.0.0.1"));
        assert!(is_loopback_host("127.0.0.1:8080"));
        assert!(is_loopback_host("localhost:47611"));
        assert!(is_loopback_host("[::1]:8080"));
        assert!(!is_loopback_host("example.com"));
        assert!(!is_loopback_host("127.0.0.1.example.com"));
        assert!(!is_loopback_host("192.168.0.5:8080"));
    }
}
