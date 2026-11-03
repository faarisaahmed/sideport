import Foundation

/// How an app is customised and signed. Saved with each library entry, so a refresh repeats it exactly.
struct AppOptions: Codable, Equatable {
    var name = ""
    var bundleId = ""
    var version = ""
    var iconPath = ""
    var minOS = ""
    var removeDeviceLimits = false
    var lowerMinOS = false
    var fileSharing = false
    var iPadFullscreen = false
    var gameMode = false
    var proMotion = false
    var liquidGlass = false
    var removeURLSchemes = false
    var removeExtensions = false
    var removeWatch = false
    var elleKit = false
    var tweaks: [String] = []
    var replaceFiles: [String: String] = [:]

    var engineJSON: [String: Any] {
        var o: [String: Any] = [
            "remove_device_limits": removeDeviceLimits, "lower_min_os": lowerMinOS, "file_sharing": fileSharing,
            "ipad_fullscreen": iPadFullscreen, "game_mode": gameMode, "pro_motion": proMotion,
            "liquid_glass": liquidGlass, "remove_url_schemes": removeURLSchemes,
            "remove_extensions": removeExtensions, "remove_watch": removeWatch, "ellekit": elleKit,
            "tweaks": tweaks, "replace_files": replaceFiles,
        ]
        if !name.isEmpty { o["name"] = name }
        if !bundleId.isEmpty { o["bundle_id"] = bundleId }
        if !version.isEmpty { o["version"] = version }
        if !iconPath.isEmpty { o["icon"] = iconPath }
        if !minOS.isEmpty { o["min_os"] = minOS }
        return o
    }

    /// Options that change something, for the little summary under each app.
    var summary: [String] {
        var s: [String] = []
        if !name.isEmpty { s.append("Renamed") }
        if !iconPath.isEmpty { s.append("Custom icon") }
        if fileSharing { s.append("File sharing") }
        if removeDeviceLimits { s.append("No device limits") }
        if removeExtensions { s.append("No extensions") }
        if proMotion { s.append("120 Hz") }
        if gameMode { s.append("Game Mode") }
        if !tweaks.isEmpty { s.append("\(tweaks.count) tweak\(tweaks.count == 1 ? "" : "s")") }
        return s
    }
}

struct IPAInfo: Equatable {
    var path: String
    var name: String
    var bundleId: String
    var version: String
    var build: String
    var minOS: String
    var size: Int64
    var modified: Date?
    var icon: String?
    var extensions: [String]
    var hasWatch: Bool
    var deviceLimited: Bool
    var fileSharing: Bool

    init(_ d: [String: Any]) {
        path = d["path"] as? String ?? ""
        name = d["name"] as? String ?? ""
        bundleId = d["bundle_id"] as? String ?? ""
        version = d["version"] as? String ?? ""
        build = d["build"] as? String ?? ""
        minOS = d["min_os"] as? String ?? ""
        size = (d["size"] as? NSNumber)?.int64Value ?? 0
        modified = (d["modified"] as? String).flatMap(parseDate)
        icon = d["icon"] as? String
        extensions = d["extensions"] as? [String] ?? []
        hasWatch = d["has_watch"] as? Bool ?? false
        deviceLimited = d["device_limited"] as? Bool ?? false
        fileSharing = d["file_sharing"] as? Bool ?? false
    }
}

enum Signing: String, Codable, CaseIterable, Identifiable {
    case appleID = "apple_id", certificate, adhoc
    var id: String { rawValue }
    var label: String {
        switch self {
        case .appleID: return "Apple ID"
        case .certificate: return "My own certificate"
        case .adhoc: return "Ad-hoc (jailbroken / TrollStore)"
        }
    }
}

/// One sideloaded app: where its IPA lives, how it's customised, and when it was last signed.
struct LibraryApp: Codable, Identifiable, Equatable {
    var id = UUID()
    var ipaPath: String
    var backupIPAPath: String?           // e.g. Sideloadly's cached copy, used if ipaPath is gone
    var originalName: String
    var originalBundleId: String
    var version: String
    var iconPath: String?
    var options = AppOptions()
    var signing: Signing = .appleID
    var certFiles: [String] = []
    var profilePath: String?
    var deviceUDID: String?
    var deviceName: String?
    var account: String?
    var installedBundleId: String?       // the final ID on the phone, kept on refresh so app data stays
    var installedVersion: String?
    var lastSigned: Date?
    var expires: Date?
    var ipaModifiedAtSign: Date?
    var lastError: String?
    var autoRefresh = true
    var pinned = false
    var importedFrom: String?

    var displayName: String { options.name.isEmpty ? originalName : options.name }
    /// False for IPAs that are only in the library folder so far.
    var isInstalled: Bool { lastSigned != nil || installedBundleId != nil }
    var shownIcon: String? { options.iconPath.isEmpty ? iconPath : options.iconPath }

    var sourcePath: String? {
        if FileManager.default.fileExists(atPath: ipaPath) { return ipaPath }
        if let b = backupIPAPath, FileManager.default.fileExists(atPath: b) { return b }
        return nil
    }

    var daysLeft: Double? {
        guard let e = expires else { return nil }
        return e.timeIntervalSinceNow / 86_400
    }

    enum Health { case fresh, soon, urgent, expired, unknown }
    var health: Health {
        guard let d = daysLeft else { return .unknown }
        if d <= 0 { return .expired }
        if d < 1.5 { return .urgent }
        if d < 3.5 { return .soon }
        return .fresh
    }
}

struct DeviceInfo: Identifiable, Equatable, Hashable {
    var id: String { udid }
    var udid: String
    var name: String
    var model: String
    var ios: String
    var wifi: Bool

    init(_ d: [String: Any]) {
        udid = d["udid"] as? String ?? ""
        name = d["name"] as? String ?? "iPhone"
        model = d["model"] as? String ?? ""
        ios = d["ios"] as? String ?? ""
        wifi = (d["connection"] as? String) == "wifi"
    }

    var symbol: String { model.hasPrefix("iPad") ? "ipad" : model.hasPrefix("AppleTV") ? "appletv" : "iphone" }
}

struct AccountInfo: Identifiable, Equatable {
    var id: String { email }
    var email: String
    var firstName: String
    var team: String
    var selected: Bool

    init(_ d: [String: Any]) {
        email = d["email"] as? String ?? ""
        firstName = d["first_name"] as? String ?? ""
        team = d["team"] as? String ?? ""
        selected = d["selected"] as? Bool ?? false
    }
}

struct DeviceApp: Identifiable, Equatable {
    var id: String { bundleId }
    var bundleId: String
    var name: String
    var version: String
    var sideloaded: Bool

    init(_ d: [String: Any]) {
        bundleId = d["bundle_id"] as? String ?? ""
        name = d["name"] as? String ?? ""
        version = d["version"] as? String ?? ""
        let signer = d["signer"] as? String ?? ""
        sideloaded = signer.contains("Apple Development") || signer.isEmpty
    }
}

struct ActivityEntry: Codable, Identifiable {
    var id = UUID()
    var date = Date()
    var title: String
    var detail: String
    var ok: Bool
}

/// A running install or refresh, shown as a progress card.
struct Job: Identifiable, Equatable {
    var id: String
    var appId: UUID?
    var title: String
    var stage = "Starting"
    var percent = 0.0
}

/// A question from the engine the user has to answer.
struct Prompt: Identifiable, Equatable {
    var id: String
    var kind: String
    var method: String
    var phones: [(id: Int, label: String)]
    var message: String

    static func == (a: Prompt, b: Prompt) -> Bool { a.id == b.id }
}

func parseDate(_ s: String) -> Date? {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let d = f.date(from: s) { return d }
    f.formatOptions = [.withInternetDateTime]
    return f.date(from: s)
}
