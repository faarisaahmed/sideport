// Reads what the app shows about an IPA (name, version, icon, extensions) straight from the zip, without
// unpacking it, so even a 1.4 GB IPA opens instantly.

use std::fs::File;
use std::io::Read;
use std::path::{Path, PathBuf};

use anyhow::{Context, Result, anyhow};
use plist::{Dictionary, Value as Plist};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use zip::ZipArchive;

pub fn inspect(path: &Path, icon_dir: &Path) -> Result<Value> {
    let file = File::open(path).with_context(|| format!("can't open {}", path.display()))?;
    let size = file.metadata()?.len();
    let modified = file.metadata()?.modified().ok().map(|t| chrono::DateTime::<chrono::Utc>::from(t).to_rfc3339());
    let mut zip = ZipArchive::new(file).context("not a valid IPA (it isn't a zip file)")?;
    let names: Vec<String> = zip.file_names().map(String::from).collect();

    // Payload/<Name>.app/Info.plist, the top-level app only.
    let info_name = names
        .iter()
        .find(|n| {
            let parts: Vec<&str> = n.split('/').collect();
            parts.len() == 3 && parts[0] == "Payload" && parts[1].ends_with(".app") && parts[2] == "Info.plist"
        })
        .cloned()
        .ok_or_else(|| anyhow!("no app inside this IPA (Payload/*.app/Info.plist is missing)"))?;
    let app_dir = info_name.trim_end_matches("Info.plist").to_string();
    let info = read_plist(&mut zip, &info_name)?;

    let text = |key: &str| info.get(key).and_then(Plist::as_string).map(String::from);
    let name = text("CFBundleDisplayName").or_else(|| text("CFBundleName")).unwrap_or_default();

    // App extensions and a Watch app each need their own App ID with a free account, so the app shows them.
    let mut extensions = Vec::new();
    let mut has_watch = false;
    for n in &names {
        if let Some(rest) = n.strip_prefix(&app_dir) {
            let parts: Vec<&str> = rest.split('/').collect();
            if parts.len() >= 2 && (parts[0] == "PlugIns" || parts[0] == "Extensions") && parts[1].ends_with(".appex") && parts.len() == 3 && parts[2] == "Info.plist" {
                extensions.push(parts[1].trim_end_matches(".appex").to_string());
            }
            if parts[0] == "Watch" && parts.len() > 1 {
                has_watch = true;
            }
        }
    }

    let icon = extract_icon(&mut zip, &names, &app_dir, &info, path, icon_dir).ok().flatten();

    Ok(json!({
        "path": path,
        "name": name,
        "bundle_id": text("CFBundleIdentifier").unwrap_or_default(),
        "version": text("CFBundleShortVersionString").unwrap_or_default(),
        "build": text("CFBundleVersion").unwrap_or_default(),
        "min_os": text("MinimumOSVersion").unwrap_or_default(),
        "executable": text("CFBundleExecutable").unwrap_or_default(),
        "size": size,
        "modified": modified,
        "icon": icon,
        "extensions": extensions,
        "has_watch": has_watch,
        "device_limited": info.contains_key("UISupportedDevices"),
        "file_sharing": info.get("UIFileSharingEnabled").and_then(Plist::as_boolean).unwrap_or(false),
    }))
}

fn read_plist(zip: &mut ZipArchive<File>, name: &str) -> Result<Dictionary> {
    let mut data = Vec::new();
    zip.by_name(name)?.read_to_end(&mut data)?;
    let value = Plist::from_reader(std::io::Cursor::new(data)).context("Info.plist can't be read")?;
    value.into_dictionary().ok_or_else(|| anyhow!("Info.plist isn't a dictionary"))
}

/// Saves the app's largest icon as <icon_dir>/<hash>.png and returns that path. iOS icons are often in
/// Apple's CgBI PNG variant, which macOS's own image loading reads fine.
fn extract_icon(
    zip: &mut ZipArchive<File>,
    names: &[String],
    app_dir: &str,
    info: &Dictionary,
    ipa: &Path,
    icon_dir: &Path,
) -> Result<Option<PathBuf>> {
    let mut prefixes: Vec<String> = Vec::new();
    for key in ["CFBundleIcons", "CFBundleIcons~ipad"] {
        if let Some(files) = info
            .get(key)
            .and_then(Plist::as_dictionary)
            .and_then(|d| d.get("CFBundlePrimaryIcon"))
            .and_then(Plist::as_dictionary)
            .and_then(|d| d.get("CFBundleIconFiles"))
            .and_then(Plist::as_array)
        {
            prefixes.extend(files.iter().filter_map(Plist::as_string).map(String::from));
        }
    }
    if let Some(files) = info.get("CFBundleIconFiles").and_then(Plist::as_array) {
        prefixes.extend(files.iter().filter_map(Plist::as_string).map(|s| s.trim_end_matches(".png").to_string()));
    }
    if let Some(file) = info.get("CFBundleIconFile").and_then(Plist::as_string) {
        prefixes.push(file.trim_end_matches(".png").to_string());
    }
    if prefixes.is_empty() {
        prefixes.push("AppIcon".into());
    }

    // The biggest matching PNG at the top of the .app is the best one.
    let mut best: Option<(String, u64)> = None;
    for n in names {
        let Some(file) = n.strip_prefix(app_dir) else { continue };
        if file.contains('/') || !file.ends_with(".png") || !prefixes.iter().any(|p| file.starts_with(p.as_str())) {
            continue;
        }
        let size = zip.by_name(n).map(|f| f.size()).unwrap_or(0);
        if best.as_ref().is_none_or(|(_, s)| size > *s) {
            best = Some((n.clone(), size));
        }
    }
    let Some((icon_name, _)) = best else { return Ok(None) };

    let mut data = Vec::new();
    zip.by_name(&icon_name)?.read_to_end(&mut data)?;
    let mut hasher = Sha256::new();
    hasher.update(ipa.to_string_lossy().as_bytes());
    hasher.update(&data);
    let out = icon_dir.join(format!("{}.png", &hex::encode(hasher.finalize())[..16]));
    std::fs::create_dir_all(icon_dir)?;
    if !out.exists() {
        std::fs::write(&out, &data)?;
    }
    Ok(Some(out))
}
