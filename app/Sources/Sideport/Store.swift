import AppKit
import Foundation
import ServiceManagement
import SQLite3
import UserNotifications

@MainActor
final class Store: ObservableObject {
    static let shared = Store()
    /// Sideloaded apps a free Apple ID can have on one phone at a time.
    static let freeAppLimit = 3

    @Published var library: [LibraryApp] = []
    @Published var devices: [DeviceInfo] = []
    @Published var accounts: [AccountInfo] = []
    @Published var jobs: [Job] = []
    @Published var prompt: Prompt?
    /// The sign-in sheet is open; it shows two-factor prompts itself.
    @Published var signingIn = false
    @Published var activity: [ActivityEntry] = []
    @Published var engineLog: [String] = []
    @Published var engineReady = false
    @Published var engineError: String?
    @Published var toast: String?
    @Published var draft: Draft?
    @Published var deviceApps: [String: [DeviceApp]] = [:]
    @Published var appIdQuota: AppIdQuota?

    @Published var selectedDeviceUDID: String? {
        didSet { UserDefaults.standard.set(selectedDeviceUDID, forKey: "device") }
    }
    @Published var autoRefresh: Bool = UserDefaults.standard.object(forKey: "autoRefresh") as? Bool ?? true {
        didSet { UserDefaults.standard.set(autoRefresh, forKey: "autoRefresh") }
    }
    @Published var refreshWhenDaysLeft: Double = UserDefaults.standard.object(forKey: "refreshDays") as? Double ?? 2 {
        didSet { UserDefaults.standard.set(refreshWhenDaysLeft, forKey: "refreshDays") }
    }
    /// The library folder: every IPA in it shows up as an app, like a games folder in an emulator.
    @Published var watchFolder: String = UserDefaults.standard.string(forKey: "watchFolder") ?? (NSHomeDirectory() + "/IPAs") {
        didSet {
            UserDefaults.standard.set(watchFolder, forKey: "watchFolder")
            Task { await syncFolder() }
        }
    }
    /// IPAs removed from the library, so the folder sync doesn't bring them back.
    private var hiddenIPAs: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "hiddenIPAs") ?? []) {
        didSet { UserDefaults.standard.set(Array(hiddenIPAs), forKey: "hiddenIPAs") }
    }
    @Published var openAtLogin: Bool = SMAppService.mainApp.status == .enabled {
        didSet {
            guard openAtLogin != (SMAppService.mainApp.status == .enabled) else { return }
            do {
                if openAtLogin { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                showToast("Couldn't change Open at Login: \(error.localizedDescription)")
            }
        }
    }
    @Published var notify: Bool = UserDefaults.standard.object(forKey: "notify") as? Bool ?? true {
        didSet { UserDefaults.standard.set(notify, forKey: "notify") }
    }
    @Published var certificateMode: String = UserDefaults.standard.string(forKey: "certificateMode") ?? "auto" {
        didSet { UserDefaults.standard.set(certificateMode, forKey: "certificateMode") }
    }

    /// The install sheet's working copy: a new IPA, or an existing app being edited.
    struct Draft: Identifiable {
        var id = UUID()
        var app: LibraryApp
        var info: IPAInfo
        var isNew: Bool
        var exportOnly = false
    }

    let engine = Engine()
    private var timers: [Timer] = []
    private var jobQueue: [() async -> Void] = []
    private var running = false

    static var dataDir: URL {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Sideport")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private init() {
        selectedDeviceUDID = UserDefaults.standard.string(forKey: "device")
        loadLibrary()
        loadActivity()
        engine.onEvent = { e in Task { @MainActor in Store.shared.handle(event: e) } }
        engine.onLog = { line in Task { @MainActor in Store.shared.appendLog(line) } }
        do {
            try engine.start()
        } catch {
            engineError = "Couldn't start the engine: \(error.localizedDescription)"
        }
        Task {
            await reloadAccounts()
            await reloadQuota()
            await reloadDevices()
            // `open Sideport.app --args -importSideloadly YES` runs the import at launch (used for testing).
            if UserDefaults.standard.bool(forKey: "importSideloadly"), library.isEmpty { await importSideloadly() }
            await syncFolder()
        }
        timers.append(Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { _ in
            Task { @MainActor in await Store.shared.syncFolder() }
        })
        timers.append(Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { _ in
            Task { @MainActor in await Store.shared.reloadDevices() }
        })
        // Every 15 minutes: refresh what's due on a connected device, warn about what's about to expire.
        timers.append(Timer.scheduledTimer(withTimeInterval: 900, repeats: true) { _ in
            Task { @MainActor in Store.shared.backgroundCheck() }
        })
        if notify { UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in } }
    }

    // MARK: - Persistence

    private var libraryURL: URL { Store.dataDir.appendingPathComponent("library.json") }
    private var activityURL: URL { Store.dataDir.appendingPathComponent("activity.json") }

    private func loadLibrary() {
        guard let data = try? Data(contentsOf: libraryURL) else { return }
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        library = (try? d.decode([LibraryApp].self, from: data)) ?? []
    }

    func saveLibrary() {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? e.encode(library).write(to: libraryURL, options: .atomic)
    }

    private func loadActivity() {
        guard let data = try? Data(contentsOf: activityURL) else { return }
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        activity = (try? d.decode([ActivityEntry].self, from: data)) ?? []
    }

    private func log(_ title: String, _ detail: String, ok: Bool) {
        activity.insert(ActivityEntry(title: title, detail: detail, ok: ok), at: 0)
        if activity.count > 300 { activity.removeLast(activity.count - 300) }
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        try? e.encode(activity).write(to: activityURL, options: .atomic)
    }

    private func appendLog(_ line: String) {
        engineLog.append(line)
        if engineLog.count > 2000 { engineLog.removeFirst(engineLog.count - 2000) }
    }

    func showToast(_ text: String) {
        toast = text
        Task {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            if toast == text { toast = nil }
        }
    }

    // MARK: - Engine events

    private func handle(event e: [String: Any]) {
        switch e["event"] as? String {
        case "ready":
            engineReady = true
        case "progress":
            guard let job = e["job"] as? String, let i = jobs.firstIndex(where: { $0.id == job }) else { return }
            jobs[i].stage = e["stage"] as? String ?? jobs[i].stage
            jobs[i].percent = (e["percent"] as? NSNumber)?.doubleValue ?? jobs[i].percent
        case "prompt":
            let phones = (e["phones"] as? [[String: Any]] ?? []).map { p in
                (id: (p["id"] as? NSNumber)?.intValue ?? 0, label: "Phone ending in \(p["last_two"] as? String ?? "??")")
            }
            prompt = Prompt(id: e["prompt"] as? String ?? "", kind: e["kind"] as? String ?? "",
                            method: e["method"] as? String ?? "device", phones: phones,
                            message: e["message"] as? String ?? "")
            NSApp.activate(ignoringOtherApps: true)
        default:
            break
        }
    }

    func answerPrompt(_ fields: [String: Any]) {
        guard let p = prompt else { return }
        engine.answer(p.id, fields)
        prompt = nil
    }

    // MARK: - Devices and accounts

    var selectedDevice: DeviceInfo? {
        devices.first { $0.udid == selectedDeviceUDID } ?? devices.first
    }

    func reloadDevices() async {
        guard let list = try? await engine.call("devices") as? [[String: Any]] else { return }
        let new = list.map(DeviceInfo.init)
        if new != devices {
            let appeared = new.filter { d in !devices.contains { $0.udid == d.udid } }
            devices = new
            if selectedDeviceUDID == nil || !new.contains(where: { $0.udid == selectedDeviceUDID }) {
                if let first = new.first { selectedDeviceUDID = first.udid }
            }
            if !appeared.isEmpty { backgroundCheck() }
        }
    }

    func loadDeviceApps(_ udid: String) async {
        do {
            let list = try await engine.call("installed_apps", ["udid": udid]) as? [[String: Any]] ?? []
            deviceApps[udid] = list.map(DeviceApp.init)
        } catch {
            showToast(error.localizedDescription)
        }
    }

    func uninstall(bundleId: String, from udid: String) async {
        do {
            try await engine.call("uninstall", ["udid": udid, "bundle_id": bundleId])
            log("Removed \(bundleId)", "from \(devices.first { $0.udid == udid }?.name ?? "device")", ok: true)
            await loadDeviceApps(udid)
        } catch {
            showToast(error.localizedDescription)
        }
    }

    var currentAccount: AccountInfo? { accounts.first { $0.selected } ?? accounts.first }

    func reloadAccounts() async {
        if let list = try? await engine.call("accounts") as? [[String: Any]] {
            accounts = list.map(AccountInfo.init)
        }
    }

    /// The free account's App IDs left this week (nil for a paid account, or when it can't be read).
    func reloadQuota() async {
        guard let email = currentAccount?.email,
              let r = try? await engine.call("app_id_quota", ["email": email]) as? [String: Any],
              let available = r["available"] as? Int, let max = r["max"] as? Int else {
            appIdQuota = nil
            return
        }
        appIdQuota = AppIdQuota(available: available, max: max)
    }

    func login(email: String, password: String) async throws {
        let list = try await engine.call("login", ["email": email, "password": password, "job": "login"]) as? [[String: Any]] ?? []
        accounts = list.map(AccountInfo.init)
        log("Signed in", email, ok: true)
        Task { await reloadQuota() }
        for i in library.indices where library[i].lastError?.contains("isn't signed in") == true { library[i].lastError = nil }
        saveLibrary()
    }

    func logout(_ email: String) async {
        if let list = try? await engine.call("logout", ["email": email]) as? [[String: Any]] {
            accounts = list.map(AccountInfo.init)
            log("Signed out", email, ok: true)
            await reloadQuota()
        }
    }

    // MARK: - Adding and editing apps

    func inspect(_ path: String) async throws -> IPAInfo {
        let d = try await engine.call("inspect", ["path": path]) as? [String: Any] ?? [:]
        return IPAInfo(d)
    }

    /// Opens the install sheet for a new IPA (or the existing entry for that app, if it's already in the library).
    func add(url: URL) {
        Task {
            do {
                let info = try await inspect(url.path)
                let device = selectedDevice?.udid
                if let existing = library.first(where: { $0.originalBundleId == info.bundleId && (device == nil || $0.deviceUDID == device) }) {
                    var app = existing
                    app.ipaPath = url.path
                    draft = Draft(app: app, info: info, isNew: false)
                    return
                }
                var app = LibraryApp(ipaPath: url.path, originalName: info.name, originalBundleId: info.bundleId,
                                     version: info.version, iconPath: info.icon)
                app.deviceUDID = selectedDevice?.udid
                app.deviceName = selectedDevice?.name
                app.account = currentAccount?.email
                app.options.fileSharing = false
                draft = Draft(app: app, info: info, isNew: true)
            } catch {
                showToast(error.localizedDescription)
            }
        }
    }

    func edit(_ app: LibraryApp) {
        Task {
            guard let path = app.sourcePath else {
                showToast("The IPA for \(app.displayName) is missing. Drop it in again.")
                return
            }
            do {
                draft = Draft(app: app, info: try await inspect(path), isNew: !app.isInstalled)
            } catch {
                showToast(error.localizedDescription)
            }
        }
    }

    enum Removal { case libraryOnly, alsoFromDevice, alsoTrashIPA }

    func remove(_ app: LibraryApp, _ how: Removal = .libraryOnly) {
        library.removeAll { $0.id == app.id }
        hiddenIPAs.insert(standard(app.ipaPath))
        saveLibrary()
        switch how {
        case .libraryOnly:
            log("Removed \(app.displayName)", "from Sideport", ok: true)
        case .alsoFromDevice:
            if let udid = app.deviceUDID, let id = app.installedBundleId {
                Task { await uninstall(bundleId: id, from: udid) }
            }
        case .alsoTrashIPA:
            if FileManager.default.fileExists(atPath: app.ipaPath) {
                NSWorkspace.shared.recycle([URL(fileURLWithPath: app.ipaPath)])
            }
            log("Removed \(app.displayName)", "and moved its IPA to the Trash", ok: true)
        }
        showToast("Removed \(app.displayName)")
    }

    private func standard(_ path: String) -> String { URL(fileURLWithPath: path).standardizedFileURL.path }

    var folderURL: URL { URL(fileURLWithPath: (watchFolder as NSString).expandingTildeInPath) }

    /// Adds IPAs that appeared in the library folder, and points apps at the folder's copy of their IPA.
    private var syncing = false
    func syncFolder() async {
        guard !syncing else { return }
        syncing = true
        defer { syncing = false }
        let files = ((try? FileManager.default.contentsOfDirectory(at: folderURL, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension.lowercased() == "ipa" }
        let known = Set(library.map { standard($0.ipaPath) })
        var changed = false
        for url in files {
            let path = standard(url.path)
            if known.contains(path) || hiddenIPAs.contains(path) { continue }
            guard let info = try? await inspect(path) else { continue }
            // An app already in the library (e.g. imported, pointing at Sideloadly's cache) gets this IPA instead.
            if let i = library.firstIndex(where: { app in
                app.originalBundleId == info.bundleId
                    && (!FileManager.default.fileExists(atPath: app.ipaPath) || app.ipaPath.contains("/Caches/sideloadly/"))
            }) {
                library[i].backupIPAPath = library[i].backupIPAPath ?? library[i].ipaPath
                library[i].ipaPath = path
            } else {
                var app = LibraryApp(ipaPath: path, originalName: info.name, originalBundleId: info.bundleId,
                                     version: info.version, iconPath: info.icon)
                app.account = currentAccount?.email
                library.append(app)
            }
            changed = true
        }
        if changed { saveLibrary() }
    }

    func update(_ app: LibraryApp) {
        hiddenIPAs.remove(standard(app.ipaPath))
        if let i = library.firstIndex(where: { $0.id == app.id }) { library[i] = app } else { library.append(app) }
        saveLibrary()
    }

    // MARK: - Installing

    var isBusy: Bool { !jobs.isEmpty }

    /// Queues a sign-and-install (or export). Installs run one at a time, since a phone takes one at a time.
    func install(_ app: LibraryApp, exportTo: URL? = nil, exportOnly: Bool = false) {
        update(app)
        let job = Job(id: UUID().uuidString, appId: app.id, title: app.displayName, stage: "Waiting")
        jobs.append(job)
        enqueue { [weak self] in await self?.run(job: job.id, appId: app.id, exportTo: exportTo, exportOnly: exportOnly) }
    }

    private func enqueue(_ work: @escaping () async -> Void) {
        jobQueue.append(work)
        guard !running else { return }
        running = true
        Task {
            while !jobQueue.isEmpty {
                let next = jobQueue.removeFirst()
                await next()
            }
            running = false
        }
    }

    private func run(job: String, appId: UUID, exportTo: URL?, exportOnly: Bool) async {
        defer { jobs.removeAll { $0.id == job } }
        guard var app = library.first(where: { $0.id == appId }) else { return }
        guard let source = app.sourcePath else {
            fail(&app, "The IPA isn't at \(app.ipaPath) any more. Drop it in again.")
            return
        }
        var options = app.options.engineJSON
        // Keep the ID already on the phone, so a refresh replaces the app and keeps its data.
        if app.options.bundleId.isEmpty, let installed = app.installedBundleId { options["bundle_id"] = installed }

        var args: [String: Any] = ["job": job, "ipa": source, "options": options, "signing": app.signing.rawValue,
                                   "certificate": certificateMode]
        if let email = app.account ?? currentAccount?.email { args["email"] = email }
        if app.signing == .certificate {
            args["cert_files"] = app.certFiles
            if let p = app.profilePath { args["profile"] = p }
        }
        if !exportOnly {
            let udid = app.deviceUDID.flatMap { u in devices.contains { $0.udid == u } ? u : nil } ?? selectedDevice?.udid
            guard let udid else {
                fail(&app, "No device connected. Plug in your iPhone (or turn on Wi-Fi syncing in Finder).")
                return
            }
            args["udid"] = udid
            app.deviceUDID = udid
            app.deviceName = devices.first { $0.udid == udid }?.name ?? app.deviceName
        }
        if let exportTo { args["export"] = exportTo.path }

        let started = Date()
        do {
            let r = try await engine.call("install", args) as? [String: Any] ?? [:]
            if !exportOnly {
                app.installedBundleId = r["bundle_id"] as? String ?? app.installedBundleId
                app.installedVersion = r["version"] as? String
                app.lastSigned = Date()
                app.expires = (r["expires"] as? String).flatMap(parseDate) ?? Calendar.current.date(byAdding: .day, value: 7, to: Date())
                app.ipaModifiedAtSign = fileDate(source)
                app.account = args["email"] as? String
            }
            app.lastError = nil
            if let fresh = try? await inspect(source) {
                app.version = fresh.version
                app.originalName = fresh.name
                app.iconPath = fresh.icon ?? app.iconPath
            }
            update(app)
            let secs = Int(Date().timeIntervalSince(started))
            let what = exportOnly ? "Exported" : "Installed"
            log("\(what) \(app.displayName)", "\(app.version) on \(app.deviceName ?? "device") in \(secs)s", ok: true)
            showToast("\(app.displayName) \(exportOnly ? "exported" : "is ready") ✓")
            Task { await reloadQuota() }
        } catch {
            fail(&app, error.localizedDescription)
        }
    }

    private func fail(_ app: inout LibraryApp, _ message: String) {
        app.lastError = message
        update(app)
        log("\(app.displayName) failed", message, ok: false)
        showToast("\(app.displayName): \(message)")
    }

    func fileDate(_ path: String) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
    }

    /// True when the IPA on disk is newer than the one last installed (e.g. a fresh Silksong build).
    func hasNewBuild(_ app: LibraryApp) -> Bool {
        guard let signedAt = app.ipaModifiedAtSign, let now = fileDate(app.ipaPath) else { return false }
        return now.timeIntervalSince(signedAt) > 1
    }

    func isConnected(_ app: LibraryApp) -> Bool {
        guard let u = app.deviceUDID else { return selectedDevice != nil }
        return devices.contains { $0.udid == u }
    }

    var appsForSelectedDevice: [LibraryApp] {
        let u = selectedDevice?.udid
        return library
            .filter { u == nil || $0.deviceUDID == nil || $0.deviceUDID == u }
            .sorted { a, b in
                if a.pinned != b.pinned { return a.pinned }
                if a.isInstalled != b.isInstalled { return a.isInstalled }
                if !a.isInstalled { return a.displayName.localizedCaseInsensitiveCompare(b.displayName) == .orderedAscending }
                return (a.daysLeft ?? -99) < (b.daysLeft ?? -99)
            }
    }

    func refreshAll(onlyDue: Bool = false) {
        let due = appsForSelectedDevice.filter { app in
            guard app.sourcePath != nil, app.isInstalled else { return false }
            if !onlyDue { return true }
            return (app.daysLeft ?? 0) < refreshWhenDaysLeft || hasNewBuild(app)
        }
        if due.isEmpty {
            showToast(onlyDue ? "Nothing needs refreshing yet" : "No apps to refresh")
            return
        }
        for app in due where !jobs.contains(where: { $0.appId == app.id }) { install(app) }
    }

    private func backgroundCheck() {
        guard engineReady, !isBusy else { return }
        if autoRefresh {
            // Only apps that are still signed: an expired one has probably been dropped, and a free Apple ID
            // can only have 3 apps active on a device, so reviving it could just fail. Those are refreshed by hand.
            let due = library.filter { app in
                guard app.autoRefresh, isConnected(app), app.sourcePath != nil, app.lastError == nil, let days = app.daysLeft else { return false }
                return days > 0 && days < refreshWhenDaysLeft
            }
            for app in due { install(app) }
        }
        if notify {
            let expiring = library.filter { ($0.daysLeft ?? 99) < 1 && ($0.daysLeft ?? 0) > 0 }
            for app in expiring { notifyOnce(app) }
        }
    }

    private func notifyOnce(_ app: LibraryApp) {
        let key = "notified-\(app.id)-\(app.expires?.timeIntervalSince1970 ?? 0)"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        let c = UNMutableNotificationContent()
        c.title = "\(app.displayName) expires soon"
        c.body = "Connect your \(app.deviceName ?? "iPhone") and Sideport will refresh it."
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: key, content: c, trigger: nil))
    }

    // MARK: - Import from Sideloadly

    var sideloadlyDatabase: URL {
        URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support/sideloadly/installations.db")
    }

    var canImportSideloadly: Bool { FileManager.default.fileExists(atPath: sideloadlyDatabase.path) }

    /// Adds every app Sideloadly has installed, with its custom name and the bundle ID already on the phone,
    /// so the first refresh from Sideport replaces it in place.
    func importSideloadly() async {
        var db: OpaquePointer?
        guard sqlite3_open_v2(sideloadlyDatabase.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            showToast("Couldn't open Sideloadly's database")
            return
        }
        defer { sqlite3_close(db) }
        let sql = """
            select i.name, i.final_bundle_id, i.device_udid, i.apple_id, i.last_updated, i.known_ttl, s.nickname, s.stored_name, d.name
            from installations i join stored_files s on s.id = i.ipa_id left join devices d on d.udid = i.device_udid
            where i.deleted_at is null
            """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        func col(_ i: Int32) -> String { sqlite3_column_text(stmt, i).map { String(cString: $0) } ?? "" }

        var added = 0
        let cache = NSHomeDirectory() + "/Library/Caches/sideloadly/"
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.dateFormat = "yyyy-MM-dd HH:mm:ss.SSSSSSZZZZZ"
        while sqlite3_step(stmt) == SQLITE_ROW {
            let name = col(0), finalId = col(1), udid = col(2), appleId = col(3)
            let nickname = col(6), cached = cache + col(7), deviceName = col(8)
            if library.contains(where: { $0.installedBundleId == finalId && $0.deviceUDID == udid }) { continue }
            let original = (watchFolder as NSString).expandingTildeInPath + "/" + nickname
            let path = FileManager.default.fileExists(atPath: original) ? original : cached
            guard let info = try? await inspect(path) else { continue }
            var app = LibraryApp(ipaPath: path, backupIPAPath: cached, originalName: info.name,
                                 originalBundleId: info.bundleId, version: info.version, iconPath: info.icon)
            if !name.isEmpty, !name.hasSuffix(".ipa"), name != info.name { app.options.name = name }
            app.installedBundleId = finalId
            app.deviceUDID = udid
            app.deviceName = deviceName.isEmpty ? nil : deviceName
            app.account = appleId.isEmpty ? currentAccount?.email : appleId
            app.importedFrom = "Sideloadly"
            if let signed = fmt.date(from: col(4)) {
                app.lastSigned = signed
                let ttl = Int(col(5)) ?? 7
                app.expires = Calendar.current.date(byAdding: .day, value: ttl, to: signed)
                app.ipaModifiedAtSign = fileDate(path) == nil ? nil : min(fileDate(path)!, signed)
            }
            app.autoRefresh = (app.daysLeft ?? 0) > 0
            library.append(app)
            added += 1
        }
        saveLibrary()
        log("Imported from Sideloadly", "\(added) app\(added == 1 ? "" : "s")", ok: true)
        showToast(added == 0 ? "Everything from Sideloadly is already here" : "Imported \(added) app\(added == 1 ? "" : "s") from Sideloadly")
    }
}
