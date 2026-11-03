import SwiftUI

// MARK: - Devices

struct DevicesView: View {
    @EnvironmentObject var store: Store
    @State private var loading = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Devices").font(.system(size: 28, weight: .bold, design: .rounded))
                if store.devices.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "cable.connector").font(.system(size: 40, weight: .light)).foregroundStyle(.secondary)
                        Text("No devices connected").font(.title3.weight(.semibold))
                        Text("Plug your iPhone in with a cable and tap Trust. To use Wi-Fi after that, open it in Finder and turn on \"Show this iPhone when on Wi-Fi\".")
                            .foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 420)
                    }
                    .frame(maxWidth: .infinity).padding(40).card()
                }
                ForEach(store.devices) { d in
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(spacing: 14) {
                            Image(systemName: d.symbol).font(.system(size: 30)).foregroundStyle(Color.accentColor).frame(width: 40)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(d.name).font(.system(size: 16, weight: .semibold))
                                Text("\(d.model) · iOS \(d.ios)").font(.system(size: 12)).foregroundStyle(.secondary)
                                Text(d.udid).font(.system(size: 10.5, design: .monospaced)).foregroundStyle(.tertiary).textSelection(.enabled)
                            }
                            Spacer()
                            Pill(text: d.wifi ? "Wi-Fi" : "USB", symbol: d.wifi ? "wifi" : "cable.connector", color: d.wifi ? .blue : .green)
                            Button("Apps on This Device") { Task { loading = true; await store.loadDeviceApps(d.udid); loading = false } }
                        }
                        if let apps = store.deviceApps[d.udid] {
                            Divider()
                            Text("\(apps.count) apps installed. The ones Sideport signed are marked.").font(.system(size: 11.5)).foregroundStyle(.secondary)
                            ForEach(apps) { a in
                                let ours = store.library.contains { $0.installedBundleId == a.bundleId }
                                HStack {
                                    Text(a.name).font(.system(size: 12.5, weight: .medium))
                                    if ours { Pill(text: "In library", color: .green) }
                                    Spacer()
                                    Text(a.version).font(.system(size: 11)).foregroundStyle(.secondary)
                                    Text(a.bundleId).font(.system(size: 10.5, design: .monospaced)).foregroundStyle(.tertiary).frame(width: 260, alignment: .trailing).lineLimit(1)
                                    Button(role: .destructive) {
                                        Task { await store.uninstall(bundleId: a.bundleId, from: d.udid) }
                                    } label: { Image(systemName: "trash") }
                                    .buttonStyle(.borderless)
                                    .help("Delete \(a.name) from the device")
                                }
                            }
                        } else if loading {
                            ProgressView().controlSize(.small)
                        }
                    }
                    .padding(16).card()
                }
            }
            .padding(26)
        }
    }
}

// MARK: - Account

struct AccountView: View {
    @EnvironmentObject var store: Store
    @State private var showLogin = false
    @State private var appIds: [[String: Any]] = []
    @State private var certs: [[String: Any]] = []
    @State private var loadingIds = false
    @State private var error: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Text("Apple ID").font(.system(size: 28, weight: .bold, design: .rounded))
                    Spacer()
                    Button("Sign In…") { showLogin = true }.buttonStyle(PrimaryButtonStyle())
                }
                if store.accounts.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "person.crop.circle.badge.plus").font(.system(size: 40, weight: .light)).foregroundStyle(Color.accentColor)
                        Text("Sign in with your Apple ID").font(.title3.weight(.semibold))
                        Text("Sideport uses it to sign apps, the same way Sideloadly does. Your password goes only to Apple; Sideport keeps a login token on this Mac.")
                            .foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 440)
                    }
                    .frame(maxWidth: .infinity).padding(40).card()
                }
                ForEach(store.accounts) { a in
                    HStack(spacing: 14) {
                        Image(systemName: "person.crop.circle.fill").font(.system(size: 34)).foregroundStyle(Color.accentColor)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(a.firstName.isEmpty ? a.email : a.firstName).font(.system(size: 15, weight: .semibold))
                            Text(a.email).font(.system(size: 12)).foregroundStyle(.secondary)
                            Text("Team \(a.team.isEmpty ? "not chosen" : a.team)").font(.system(size: 11)).foregroundStyle(.tertiary)
                        }
                        Spacer()
                        if a.selected { Pill(text: "Default", color: .green) }
                        Button("App IDs & Certificates") { Task { await loadDetails(a.email) } }
                        Button("Sign Out", role: .destructive) { Task { await store.logout(a.email) } }
                    }
                    .padding(16).card()
                }
                if !store.accounts.isEmpty {
                    Label("Free Apple IDs sign apps for 7 days, can have 3 sideloaded apps active per device, and can make 10 App IDs a week.", systemImage: "info.circle")
                        .font(.system(size: 11.5)).foregroundStyle(.secondary)
                }
                if loadingIds { ProgressView().controlSize(.small) }
                if let error { Text(error).foregroundStyle(.red).font(.system(size: 12)) }
                if !appIds.isEmpty { appIdList }
                if !certs.isEmpty { certList }
            }
            .padding(26)
        }
        .sheet(isPresented: $showLogin) { LoginSheet() }
    }

    private var appIdList: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionTitle(title: "App IDs (\(appIds.count))", subtitle: "Free accounts can make 10 a week. Deleting unused ones doesn't give them back early, but keeps the list tidy.")
            ForEach(appIds.indices, id: \.self) { i in
                let id = appIds[i]
                HStack {
                    Text(id["identifier"] as? String ?? "").font(.system(size: 12, design: .monospaced))
                    Spacer()
                    if store.library.contains(where: { $0.installedBundleId == id["identifier"] as? String }) { Pill(text: "In library", color: .green) }
                    Button(role: .destructive) {
                        Task {
                            guard let email = store.currentAccount?.email else { return }
                            try? await store.engine.call("delete_app_id", ["email": email, "app_id": id["id"] as? String ?? ""])
                            await loadDetails(email)
                        }
                    } label: { Image(systemName: "trash") }.buttonStyle(.borderless)
                }
                .padding(.vertical, 2)
            }
        }
        .padding(16).card()
    }

    private var certList: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionTitle(title: "Signing certificates", subtitle: "Revoking one stops every app signed with it from opening until it's refreshed.")
            ForEach(certs.indices, id: \.self) { i in
                let c = certs[i]
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(c["machine"] as? String ?? c["name"] as? String ?? "").font(.system(size: 12.5, weight: .medium))
                        Text("Serial \(c["serial"] as? String ?? "") · \(c["status"] as? String ?? "")").font(.system(size: 10.5, design: .monospaced)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Revoke", role: .destructive) {
                        Task {
                            guard let email = store.currentAccount?.email else { return }
                            try? await store.engine.call("revoke_certificate", ["email": email, "serial": c["serial"] as? String ?? ""])
                            await loadDetails(email)
                        }
                    }
                }
            }
        }
        .padding(16).card()
    }

    private func loadDetails(_ email: String) async {
        loadingIds = true
        error = nil
        defer { loadingIds = false }
        do {
            appIds = try await store.engine.call("app_ids", ["email": email]) as? [[String: Any]] ?? []
            certs = try await store.engine.call("certificates", ["email": email]) as? [[String: Any]] ?? []
        } catch {
            self.error = error.localizedDescription
        }
    }
}

struct LoginSheet: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    @State private var email = ""
    @State private var password = ""
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "apple.logo").font(.system(size: 34))
            Text("Sign in with your Apple ID").font(.title3.weight(.semibold))
            TextField("Email", text: $email).textFieldStyle(.roundedBorder).textContentType(.username)
            SecureField("Password", text: $password).textFieldStyle(.roundedBorder).textContentType(.password)
            if let error { Text(error).foregroundStyle(.red).font(.system(size: 12)).multilineTextAlignment(.center) }
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                if busy { ProgressView().controlSize(.small) }
                Button("Sign In") {
                    busy = true
                    error = nil
                    Task {
                        do {
                            try await store.login(email: email, password: password)
                            dismiss()
                        } catch {
                            self.error = error.localizedDescription
                        }
                        busy = false
                    }
                }
                .buttonStyle(PrimaryButtonStyle())
                .keyboardShortcut(.defaultAction)
                .disabled(email.isEmpty || password.isEmpty || busy)
            }
        }
        .padding(26)
        .frame(width: 380)
    }
}

/// Two-factor code entry and other questions from the engine.
struct PromptSheet: View {
    @EnvironmentObject var store: Store
    var prompt: Prompt
    @State private var code = ""

    var body: some View {
        VStack(spacing: 16) {
            if prompt.kind == "two_factor" {
                Image(systemName: "lock.shield").font(.system(size: 34)).foregroundStyle(Color.accentColor)
                Text("Enter the verification code").font(.title3.weight(.semibold))
                Text(prompt.method == "sms" ? "Apple sent a code by text message." : "Apple sent a code to your other devices.")
                    .foregroundStyle(.secondary)
                TextField("123456", text: $code)
                    .font(.system(size: 26, weight: .semibold, design: .monospaced))
                    .multilineTextAlignment(.center)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 180)
                    .onChange(of: code) { v in
                        code = String(v.filter(\.isNumber).prefix(6))
                        if code.count == 6 { store.answerPrompt(["code": code]) }
                    }
                if !prompt.phones.isEmpty {
                    Menu("Text Me a Code Instead") {
                        ForEach(prompt.phones, id: \.id) { p in Button(p.label) { store.answerPrompt(["sms_phone": p.id]) } }
                    }
                    .fixedSize()
                }
                HStack {
                    Button("Cancel") { store.answerPrompt(["cancel": true]) }
                    Spacer()
                    Button("Continue") { store.answerPrompt(["code": code]) }.buttonStyle(PrimaryButtonStyle()).disabled(code.count < 6)
                }
            } else {
                Image(systemName: "exclamationmark.triangle").font(.system(size: 34)).foregroundStyle(.orange)
                Text(prompt.message).multilineTextAlignment(.center)
                HStack {
                    Button("Cancel") { store.answerPrompt(["confirm": false]) }
                    Spacer()
                    Button("Revoke and Continue") { store.answerPrompt(["confirm": true]) }.buttonStyle(PrimaryButtonStyle(color: .orange))
                }
            }
        }
        .padding(26)
        .frame(width: 400)
    }
}

// MARK: - Activity

struct ActivityView: View {
    @EnvironmentObject var store: Store
    @State private var showLog = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Activity").font(.system(size: 28, weight: .bold, design: .rounded))
                Spacer()
                Toggle("Engine log", isOn: $showLog).toggleStyle(.switch)
            }
            .padding(26)
            if showLog {
                ScrollView {
                    Text(store.engineLog.suffix(600).joined(separator: "\n"))
                        .font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(16)
                }
            } else if store.activity.isEmpty {
                Text("Installs and refreshes will show up here.").foregroundStyle(.secondary).padding(.horizontal, 26)
                Spacer()
            } else {
                List(store.activity) { e in
                    HStack(spacing: 12) {
                        Image(systemName: e.ok ? "checkmark.circle.fill" : "xmark.octagon.fill").foregroundStyle(e.ok ? .green : .red)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(e.title).font(.system(size: 12.5, weight: .medium))
                            Text(e.detail).font(.system(size: 11.5)).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                        Spacer()
                        Text(relative(e.date)).font(.system(size: 11)).foregroundStyle(.tertiary)
                    }
                    .padding(.vertical, 3)
                }
            }
        }
    }
}

// MARK: - Settings

struct SettingsView: View {
    @EnvironmentObject var store: Store

    var body: some View {
        Form {
            Section("Refreshing") {
                Toggle("Refresh apps automatically when a device is connected", isOn: $store.autoRefresh)
                Stepper("Refresh when there are less than \(Int(store.refreshWhenDaysLeft)) days left", value: $store.refreshWhenDaysLeft, in: 1...6)
                Toggle("Notify me when an app is about to expire", isOn: $store.notify)
            }
            Section("IPAs") {
                HStack {
                    Text("Watch folder")
                    Spacer()
                    Text((store.watchFolder as NSString).abbreviatingWithTildeInPath).foregroundStyle(.secondary)
                    Button("Change…") {
                        if let url = pickFiles(types: [], directories: true).first { store.watchFolder = url.path }
                    }
                }
                Text("New IPAs in this folder show up in the library, and apps whose IPA changes there get a \"New build\" badge.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Section("Certificate") {
                Picker("Signing certificate", selection: $store.certificateMode) {
                    Text("Sideloadly's, if it's still valid (recommended)").tag("auto")
                    Text("Sideport's own").tag("own")
                }
                Text("Using Sideloadly's certificate means nothing gets revoked, so apps you installed with Sideloadly keep opening.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Section("Sideloadly") {
                Button("Import Apps from Sideloadly") { Task { await store.importSideloadly() } }
                    .disabled(!store.canImportSideloadly)
            }
        }
        .formStyle(.grouped)
        .frame(width: 560, height: 520)
    }
}
