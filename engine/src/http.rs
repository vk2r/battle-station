//! Minimal HTTP/1.1 GET against the runtimes' local ports.
//!
//! Whoever listens on a runtime's port answers, not necessarily the runtime:
//! replies are capped in size and in total time, headers included, so they can
//! neither exhaust memory nor stall the engine.

use std::io::{Read, Write};
use std::net::{SocketAddr, TcpStream};
use std::time::{Duration, Instant};

use serde_json::Value;

const LIMIT: usize = 4 << 20;
const HEADER_LIMIT: usize = 64 << 10;
const DEADLINE: Duration = Duration::from_secs(2);
const TIMEOUT: Duration = Duration::from_millis(600);

fn local(port: u16) -> SocketAddr {
    SocketAddr::from(([127, 0, 0, 1], port))
}

/// Body of a local GET, or None when it fails, is not 2xx, exceeds LIMIT or DEADLINE.
pub fn get(port: u16, path: &str) -> Option<Vec<u8>> {
    let deadline = Instant::now() + DEADLINE;
    let mut stream = TcpStream::connect_timeout(&local(port), TIMEOUT).ok()?;
    stream.set_write_timeout(Some(TIMEOUT)).ok()?;
    let request = format!(
        "GET {path} HTTP/1.1\r\nHost: 127.0.0.1:{port}\r\n\
         Accept: application/json, text/plain\r\nConnection: close\r\n\r\n"
    );
    stream.write_all(request.as_bytes()).ok()?;

    let mut raw = Vec::new();
    let mut chunk = [0u8; 65536];
    loop {
        let remaining = deadline.checked_duration_since(Instant::now())?;
        stream.set_read_timeout(Some(remaining.min(TIMEOUT).max(Duration::from_millis(1)))).ok()?;
        match stream.read(&mut chunk) {
            Ok(0) => break,
            Ok(read) => raw.extend_from_slice(&chunk[..read]),
            Err(_) => return None,
        }
        if raw.len() > LIMIT + HEADER_LIMIT {
            return None;
        }
    }
    parse(&raw)
}

fn parse(raw: &[u8]) -> Option<Vec<u8>> {
    let split = raw.windows(4).position(|window| window == b"\r\n\r\n")?;
    if split > HEADER_LIMIT {
        return None;
    }
    let head = std::str::from_utf8(&raw[..split]).ok()?;
    let body = &raw[split + 4..];
    let mut lines = head.split("\r\n");
    let status: u16 = lines.next()?.split_whitespace().nth(1)?.parse().ok()?;
    if !(200..300).contains(&status) {
        return None;
    }
    let mut chunked = false;
    let mut length = None;
    for line in lines {
        let Some((name, value)) = line.split_once(':') else { continue };
        let value = value.trim();
        if name.eq_ignore_ascii_case("content-length") {
            length = Some(value.parse::<usize>().ok()?);
        } else if name.eq_ignore_ascii_case("transfer-encoding") {
            chunked = value.to_ascii_lowercase().contains("chunked");
        }
    }
    if length.is_some_and(|length| length > LIMIT) {
        return None;
    }
    let body = if chunked { dechunk(body)? } else { body[..length.unwrap_or(body.len()).min(body.len())].to_vec() };
    (body.len() <= LIMIT).then_some(body)
}

fn dechunk(mut data: &[u8]) -> Option<Vec<u8>> {
    let mut body = Vec::new();
    loop {
        let end = data.windows(2).position(|window| window == b"\r\n")?;
        let size_text = std::str::from_utf8(&data[..end]).ok()?;
        let size = usize::from_str_radix(size_text.split(';').next()?.trim(), 16).ok()?;
        data = &data[end + 2..];
        if size == 0 {
            return Some(body);
        }
        if size > LIMIT || data.len() < size {
            return None;
        }
        body.extend_from_slice(&data[..size]);
        data = data.get(size + 2..)?;
    }
}

pub fn json(port: u16, path: &str) -> Option<Value> {
    serde_json::from_slice(&get(port, path)?).ok()
}

pub fn port_open(port: u16) -> bool {
    TcpStream::connect_timeout(&local(port), Duration::from_millis(200)).is_ok()
}

/// Percent-encoding like Python's urllib.parse.quote (keeps "/").
pub fn quote(text: &str) -> String {
    let mut out = String::new();
    for byte in text.bytes() {
        if byte.is_ascii_alphanumeric() || b"_.-~/".contains(&byte) {
            out.push(byte as char);
        } else {
            out.push_str(&format!("%{byte:02X}"));
        }
    }
    out
}
