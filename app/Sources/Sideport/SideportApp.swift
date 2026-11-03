import SwiftUI

@main
struct SideportApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var store = Store.shared

    var body: some Scene {
        WindowGroup("Sideport") {
            RootView().environmentObject(store)
                .handlesExternalEvents(preferring: ["*"], allowing: ["*"])
                .onOpenURL { url in if url.pathExtension.lowercased() == "ipa" { store.add(url: url) } }
        }
        .handlesExternalEvents(matching: ["*"])
        .defaultSize(width: 1080, height: 720)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Add IPA…") {
                    for url in pickFiles(types: ["ipa"], multiple: true) { store.add(url: url) }
                }
                .keyboardShortcut("o")
            }
            CommandMenu("Apps") {
                Button("Refresh All") { store.refreshAll() }.keyboardShortcut("r", modifiers: [.command, .shift])
                Button("Refresh What's Due") { store.refreshAll(onlyDue: true) }.keyboardShortcut("r")
                Divider()
                Button("Import from Sideloadly") { Task { await store.importSideloadly() } }.disabled(!store.canImportSideloadly)
            }
        }

        Settings {
            SettingsView().environmentObject(store)
        }

        MenuBarExtra {
            MenuBarContent().environmentObject(store)
        } label: {
            Image(systemName: store.isBusy ? "arrow.triangle.2.circlepath" : "app.badge.checkmark")
        }
        .menuBarExtraStyle(.window)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
    }

    // Double-clicked IPAs, or IPAs dropped on the Dock icon, open the install sheet.
    @MainActor func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where url.pathExtension.lowercased() == "ipa" { Store.shared.add(url: url) }
    }

    // Closing the window keeps Sideport in the menu bar, so automatic refresh keeps working.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    @MainActor func applicationWillTerminate(_ notification: Notification) {
        Store.shared.engine.stop()
    }
}

enum Page: String, CaseIterable, Identifiable {
    case library = "Apps", devices = "Devices", account = "Apple ID", activity = "Activity"
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .library: return "square.grid.2x2.fill"
        case .devices: return "iphone"
        case .account: return "person.crop.circle"
        case .activity: return "clock.arrow.circlepath"
        }
    }
}

struct RootView: View {
    @EnvironmentObject var store: Store
    @State private var page: Page? = Page(rawValue: UserDefaults.standard.string(forKey: "page") ?? "") ?? .library

    var body: some View {
        NavigationSplitView {
            List(selection: $page) {
                ForEach(Page.allCases) { p in
                    Label(p.rawValue, systemImage: p.symbol).tag(p)
                        .badge(badge(p))
                }
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200)
            .safeAreaInset(edge: .bottom) { sidebarFooter }
        } detail: {
            ZStack(alignment: .bottomTrailing) {
                switch page ?? .library {
                case .library: LibraryView()
                case .devices: DevicesView()
                case .account: AccountView()
                case .activity: ActivityView()
                }
                JobsPanel()
            }
            .animation(.spring(response: 0.35), value: store.jobs)
            .overlay(alignment: .top) {
                if let toast = store.toast {
                    Text(toast)
                        .font(.system(size: 12.5, weight: .medium))
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(.regularMaterial, in: Capsule())
                        .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
                        .padding(.top, 12)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .animation(.spring(response: 0.3), value: store.toast)
        }
        .sheet(item: $store.draft) { d in InstallSheet(draft: d).environmentObject(store) }
        .sheet(item: $store.prompt) { p in PromptSheet(prompt: p).environmentObject(store) }
        .alert("Sideport can't run", isPresented: .constant(store.engineError != nil)) {
            Button("Quit") { NSApp.terminate(nil) }
        } message: {
            Text(store.engineError ?? "")
        }
    }

    private func badge(_ p: Page) -> Int {
        switch p {
        case .library: return store.library.filter { $0.health == .expired || $0.health == .urgent }.count
        case .devices: return store.devices.count
        default: return 0
        }
    }

    private var sidebarFooter: some View {
        HStack(spacing: 8) {
            Circle().fill(store.engineReady ? Color.green : Color.orange).frame(width: 7, height: 7)
            Text(store.currentAccount?.email ?? "Not signed in").font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
        }
        .padding(12)
    }
}

/// The menu bar window: what expires next and one-click refresh.
struct MenuBarContent: View {
    @EnvironmentObject var store: Store

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Sideport").font(.system(size: 13, weight: .semibold))
                Spacer()
                Text(store.selectedDevice?.name ?? "No device").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            ForEach(store.appsForSelectedDevice.prefix(8)) { app in
                HStack(spacing: 10) {
                    AppIcon(path: app.shownIcon, size: 26, name: app.displayName)
                    Text(app.displayName).font(.system(size: 12)).lineLimit(1)
                    Spacer()
                    if let job = store.jobs.first(where: { $0.appId == app.id }) {
                        Text("\(Int(job.percent))%").font(.system(size: 11)).monospacedDigit().foregroundStyle(.secondary)
                    } else {
                        Text(app.daysLeft.map { $0 <= 0 ? "Expired" : "\(Int($0))d" } ?? "—")
                            .font(.system(size: 11, weight: .semibold)).foregroundStyle(app.health.color)
                    }
                }
            }
            Divider()
            HStack {
                Button("Refresh All") { store.refreshAll() }.buttonStyle(PrimaryButtonStyle()).disabled(store.selectedDevice == nil)
                Spacer()
                Button("Open Sideport") {
                    NSApp.activate(ignoringOtherApps: true)
                    NSApp.windows.first { $0.canBecomeMain }?.makeKeyAndOrderFront(nil)
                }
            }
        }
        .padding(14)
        .frame(width: 300)
    }
}
