// Sideport's engine: a background process the app talks to over stdin/stdout, one JSON object per line.
//
//   request   {"id": 1, "cmd": "devices", ...args}
//   reply     {"id": 1, "ok": true, "result": ...}  or  {"id": 1, "ok": false, "error": "..."}
//   event     {"event": "progress", "job": "...", ...}  (sent any time, not tied to a request)
//
// Requests run concurrently. The Apple ID login, signing and device code come from Impactor
// (https://github.com/claration/Impactor, MIT/MPL-2.0).

mod ipa;
mod ops;

use std::io::{BufRead, Write};
use std::sync::{Mutex, OnceLock};

use serde_json::{Value, json};

static OUT: OnceLock<Mutex<std::io::Stdout>> = OnceLock::new();

/// Writes one line of JSON to the app.
pub fn send(value: Value) {
    let out = OUT.get_or_init(|| Mutex::new(std::io::stdout()));
    let mut out = out.lock().unwrap();
    let _ = writeln!(out, "{}", value);
    let _ = out.flush();
}

pub fn event(name: &str, mut fields: Value) {
    if let Value::Object(ref mut map) = fields {
        map.insert("event".into(), Value::String(name.into()));
    }
    send(fields);
}

fn main() -> anyhow::Result<()> {
    // Logs go to stderr; the app keeps them for the activity log.
    env_logger::Builder::from_env(env_logger::Env::default().default_filter_or("info"))
        .target(env_logger::Target::Stderr)
        .init();
    let _ = rustls::crypto::ring::default_provider().install_default();

    event("ready", json!({ "version": env!("CARGO_PKG_VERSION") }));

    let stdin = std::io::stdin();
    for line in stdin.lock().lines() {
        let Ok(line) = line else { break };
        if line.trim().is_empty() {
            continue;
        }
        let request: Value = match serde_json::from_str(&line) {
            Ok(v) => v,
            Err(e) => {
                send(json!({ "id": null, "ok": false, "error": format!("bad request: {e}") }));
                continue;
            }
        };
        let id = request.get("id").cloned().unwrap_or(Value::Null);
        let cmd = request.get("cmd").and_then(Value::as_str).unwrap_or("").to_string();

        // Answers to a waiting prompt (two-factor codes) are handled right away, since the request that
        // asked is blocked waiting for them.
        if cmd == "answer" {
            ops::answer(&request);
            send(json!({ "id": id, "ok": true, "result": null }));
            continue;
        }

        // Each request gets its own thread and runtime: some of the signing library's types can't move
        // between threads, and a request waiting on a prompt only blocks itself.
        std::thread::spawn(move || {
            let reply = match tokio::runtime::Builder::new_current_thread().enable_all().build() {
                Ok(rt) => match rt.block_on(ops::handle(&cmd, &request)) {
                    Ok(result) => json!({ "id": id, "ok": true, "result": result }),
                    Err(e) => json!({ "id": id, "ok": false, "error": format!("{e:#}") }),
                },
                Err(e) => json!({ "id": id, "ok": false, "error": format!("can't start: {e}") }),
            };
            send(reply);
        });
    }
    Ok(())
}
