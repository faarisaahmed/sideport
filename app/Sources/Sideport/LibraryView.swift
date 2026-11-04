import SwiftUI
import UniformTypeIdentifiers

struct LibraryView: View {
    @EnvironmentObject var store: Store
    @State private var dropTargeted = false
    @State private var search = ""

    private var apps: [LibraryApp] {
        let all = store.appsForSelectedDevice
        guard !search.isEmpty else { return all }
        return all.filter { $0.displayName.localizedCaseInsensitiveContains(search) || $0.originalBundleId.localizedCaseInsensitiveContains(search) }
    }

    private var dueCount: Int {
        store.appsForSelectedDevice.filter { $0.isInstalled && (($0.daysLeft ?? 0) < store.refreshWhenDaysLeft || store.hasNewBuild($0)) }.count
    }

    // What Refresh All will do (the same apps as Store.refreshAll), for its badge.
    private var refreshAllCount: Int {
        store.appsForSelectedDevice.filter { $0.isInstalled && $0.sourcePath != nil }.count
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header
                if apps.isEmpty && search.isEmpty {
                    EmptyLibrary()
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 290, maximum: 420), spacing: 14)], spacing: 14) {
                        ForEach(apps) { app in AppCard(app: app) }
                    }
                }
            }
            .padding(26)
        }
        .searchable(text: $search, placement: .toolbar, prompt: "Search apps")
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            for p in providers {
                _ = p.loadObject(ofClass: URL.self) { url, _ in
                    guard let url, url.pathExtension.lowercased() == "ipa" else { return }
                    Task { @MainActor in store.add(url: url) }
                }
            }
            return true
        }
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [10, 6]))
                    .background(Color.accentColor.opacity(0.06), in: RoundedRectangle(cornerRadius: 20))
                    .overlay(Label("Drop to add", systemImage: "arrow.down.app").font(.title2.weight(.semibold)).foregroundStyle(Color.accentColor))
                    .padding(12)
                    .allowsHitTesting(false)
            }
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Your apps").font(.system(size: 28, weight: .bold, design: .rounded))
                Text(subtitle).font(.system(size: 13)).foregroundStyle(.secondary)
            }
            Spacer()
            FolderChip()
            DeviceChip()
            Button {
                for url in pickFiles(types: ["ipa"], multiple: true, message: "Choose IPAs to add") { store.add(url: url) }
            } label: {
                Label("Add IPA", systemImage: "plus")
            }
            .controlSize(.large)
            Button {
                store.refreshAll(onlyDue: false)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.clockwise")
                    Text("Refresh All")
                    if refreshAllCount > 0 {
                        Text("\(refreshAllCount)").font(.system(size: 11, weight: .bold))
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(.white.opacity(0.25), in: Capsule())
                    }
                }
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(store.appsForSelectedDevice.isEmpty || store.selectedDevice == nil)
            .keyboardShortcut("r", modifiers: [.command, .shift])
            .help("Re-sign and reinstall every app on this device (⇧⌘R)")
        }
    }

    private var subtitle: String {
        let all = store.appsForSelectedDevice.filter(\.isInstalled)
        if all.isEmpty { return "Drop an IPA anywhere in this window, or put some in your library folder." }
        let expired = all.filter { $0.health == .expired }.count
        if expired > 0 { return "\(expired) expired, \(dueCount) to refresh." }
        if dueCount > 0 { return "\(dueCount) of \(all.count) due for a refresh." }
        if let soonest = all.compactMap(\.daysLeft).min() { return "All \(all.count) apps are signed. Next one expires in \(Int(soonest)) days." }
        return "\(all.count) apps."
    }
}

/// The connected phone, with a menu to switch between several.
struct DeviceChip: View {
    @EnvironmentObject var store: Store

    var body: some View {
        Menu {
            if store.devices.isEmpty {
                Text("No devices. Plug in your iPhone, or turn on Wi-Fi syncing in Finder.")
            }
            ForEach(store.devices) { d in
                Button {
                    store.selectedDeviceUDID = d.udid
                } label: {
                    Label("\(d.name) · iOS \(d.ios) · \(d.wifi ? "Wi-Fi" : "USB")", systemImage: d.udid == store.selectedDevice?.udid ? "checkmark" : d.symbol)
                }
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: store.selectedDevice?.symbol ?? "iphone.slash")
                    .font(.system(size: 15))
                VStack(alignment: .leading, spacing: 0) {
                    Text(store.selectedDevice?.name ?? "No device").font(.system(size: 12, weight: .semibold))
                    Text(store.selectedDevice.map { "iOS \($0.ios) · \($0.wifi ? "Wi-Fi" : "USB")" } ?? "Plug in your iPhone")
                        .font(.system(size: 10.5)).foregroundStyle(.secondary)
                }
                Circle().fill(store.selectedDevice == nil ? Color.red : Color.green).frame(width: 7, height: 7)
            }
            .padding(.horizontal, 10).padding(.vertical, 5)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .card()
    }
}

/// The library folder, with a menu to open or change it.
struct FolderChip: View {
    @EnvironmentObject var store: Store

    var body: some View {
        Menu {
            Button("Show in Finder") { NSWorkspace.shared.open(store.folderURL) }
            Button("Choose Another Folder…") {
                if let url = pickFiles(types: [], directories: true, message: "Choose the folder where you keep your IPAs").first { store.watchFolder = url.path }
            }
        } label: {
            HStack(spacing: 7) {
                Image(systemName: "folder.fill").foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 0) {
                    Text((store.watchFolder as NSString).lastPathComponent).font(.system(size: 12, weight: .semibold))
                    Text("Library folder").font(.system(size: 10.5)).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 5)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .card()
        .help("Every IPA in \((store.watchFolder as NSString).abbreviatingWithTildeInPath) shows up here")
    }
}

struct AppCard: View {
    @EnvironmentObject var store: Store
    var app: LibraryApp
    @State private var hovering = false
    @State private var confirmRemove = false

    private var job: Job? { store.jobs.first { $0.appId == app.id } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                AppIcon(path: app.shownIcon, size: 58, name: app.displayName)
                VStack(alignment: .leading, spacing: 3) {
                    Text(app.displayName).font(.system(size: 15, weight: .semibold)).lineLimit(1)
                    Text("\(app.version.isEmpty ? "" : "v\(app.version) · ")\(app.deviceName ?? "No device")")
                        .font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1)
                    HStack(spacing: 5) {
                        if store.hasNewBuild(app) { Pill(text: "New build", symbol: "sparkles", color: .blue) }
                        if app.sourcePath == nil { Pill(text: "IPA missing", symbol: "exclamationmark.triangle.fill", color: .red) }
                        if app.importedFrom != nil && app.lastSigned != nil && app.installedVersion == nil { Pill(text: "From Sideloadly", color: .purple) }
                        ForEach(app.options.summary.prefix(2), id: \.self) { Pill(text: $0, color: .secondary) }
                    }
                }
                Spacer(minLength: 4)
                if app.isInstalled {
                    ExpiryRing(app: app)
                } else {
                    Pill(text: "Not installed", symbol: "arrow.down.circle", color: .secondary)
                }
            }
            if let job {
                VStack(alignment: .leading, spacing: 4) {
                    ProgressView(value: job.percent, total: 100).tint(.accentColor)
                    Text(job.stage).font(.system(size: 11)).foregroundStyle(.secondary)
                }
            } else if let err = app.lastError {
                Text(err).font(.system(size: 11)).foregroundStyle(.red).lineLimit(2).help(err)
            } else if !app.isInstalled {
                Text("In your library folder. Install it to put it on your phone.").font(.system(size: 11)).foregroundStyle(.secondary)
            } else {
                Text(expiryText(app)).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                if app.isInstalled {
                    Button {
                        store.install(app)
                    } label: {
                        Label(store.hasNewBuild(app) ? "Update" : "Refresh", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(PrimaryButtonStyle(color: app.health == .expired ? .red : .accentColor))
                    .disabled(job != nil || app.sourcePath == nil || !store.isConnected(app))
                } else {
                    Button {
                        store.edit(app)
                    } label: {
                        Label("Install…", systemImage: "arrow.down.to.line")
                    }
                    .buttonStyle(PrimaryButtonStyle(color: .green))
                    .disabled(job != nil || app.sourcePath == nil)
                }

                Button("Edit") { store.edit(app) }
                    .disabled(job != nil)
                Spacer()
                Menu {
                    Button("Export Signed IPA…") { export() }
                    Button("Show IPA in Finder") {
                        if let p = app.sourcePath { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: p)]) }
                    }
                    Divider()
                    Toggle("Refresh Automatically", isOn: binding(\.autoRefresh))
                    Toggle("Pin to Top", isOn: binding(\.pinned))
                    Divider()
                    if let udid = app.deviceUDID, let id = app.installedBundleId {
                        Button("Delete from \(app.deviceName ?? "Device")…") {
                            Task { await store.uninstall(bundleId: id, from: udid) }
                        }
                    }
                    Button("Remove…", role: .destructive) { confirmRemove = true }
                } label: {
                    Image(systemName: "ellipsis.circle").font(.system(size: 15))
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            }
        }
        .padding(16)
        .card(highlighted: hovering)
        .overlay(alignment: .topLeading) {
            if hovering && job == nil {
                Button { confirmRemove = true } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 18))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, Color.gray.opacity(0.85))
                }
                .buttonStyle(.plain)
                .offset(x: -7, y: -7)
                .help("Remove \(app.displayName)")
                .transition(.scale.combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .onHover { hovering = $0 }
        .confirmationDialog("Remove \(app.displayName)?", isPresented: $confirmRemove) {
            Button("Remove from Sideport") { store.remove(app, .libraryOnly) }
            if app.isInstalled, app.installedBundleId != nil, store.isConnected(app) {
                Button("Remove and Delete from \(app.deviceName ?? "iPhone")", role: .destructive) { store.remove(app, .alsoFromDevice) }
            }
            if FileManager.default.fileExists(atPath: app.ipaPath) {
                Button("Remove and Move the IPA to the Trash", role: .destructive) { store.remove(app, .alsoTrashIPA) }
            }
        } message: {
            Text(app.isInstalled ? "Removing it from Sideport doesn't touch the copy on your phone unless you choose to delete it." : "It won't come back from your library folder unless you add it again.")
        }
        .contextMenu {
            Button("Refresh") { store.install(app) }
            Button("Edit…") { store.edit(app) }
            Button("Export Signed IPA…") { export() }
            Divider()
            Button("Remove…", role: .destructive) { confirmRemove = true }
        }
    }

    private func binding(_ key: WritableKeyPath<LibraryApp, Bool>) -> Binding<Bool> {
        Binding(get: { app[keyPath: key] }, set: { v in var a = app; a[keyPath: key] = v; store.update(a) })
    }

    private func export() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "ipa") ?? .data]
        panel.nameFieldStringValue = "\(app.displayName) (signed).ipa"
        if panel.runModal() == .OK, let url = panel.url { store.install(app, exportTo: url, exportOnly: true) }
    }
}

struct EmptyLibrary: View {
    @EnvironmentObject var store: Store

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "square.and.arrow.down.on.square").font(.system(size: 46, weight: .light)).foregroundStyle(Color.accentColor)
            Text("Drop an IPA here").font(.title2.weight(.semibold))
            Text("Sideport signs it with your Apple ID, installs it, and keeps it refreshed every week.")
                .foregroundStyle(.secondary).multilineTextAlignment(.center)
            HStack {
                Button("Choose IPA…") {
                    for url in pickFiles(types: ["ipa"], multiple: true) { store.add(url: url) }
                }
                if store.canImportSideloadly {
                    Button("Import My Apps from Sideloadly") { Task { await store.importSideloadly() } }
                        .buttonStyle(PrimaryButtonStyle())
                }
            }
            .controlSize(.large)
        }
        .frame(maxWidth: .infinity)
        .padding(50)
        .card()
    }
}

/// Floating panel listing running installs.
struct JobsPanel: View {
    @EnvironmentObject var store: Store

    var body: some View {
        if !store.jobs.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(store.jobs) { job in
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.small).opacity(job.stage == "Waiting" ? 0 : 1)
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text(job.title).font(.system(size: 12, weight: .semibold))
                                Spacer()
                                Text(job.stage == "Waiting" ? "Queued" : "\(Int(job.percent))%").font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
                            }
                            ProgressView(value: job.percent, total: 100)
                            Text(job.stage).font(.system(size: 10.5)).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .padding(14)
            .frame(width: 320)
            .card()
            .shadow(color: .black.opacity(0.15), radius: 16, y: 6)
            .padding(18)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
}
