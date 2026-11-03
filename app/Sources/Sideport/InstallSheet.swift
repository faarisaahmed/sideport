import SwiftUI
import UniformTypeIdentifiers

/// Customise and install a new IPA, or change how an app in the library is signed.
struct InstallSheet: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    @State var draft: Store.Draft
    @State private var section = 0
    @State private var iconDrop = false

    private var app: Binding<LibraryApp> { $draft.app }
    private var o: Binding<AppOptions> { $draft.app.options }

    /// App IDs a free account will use for this install (the app, plus each extension and the Watch app kept).
    private var appIdCost: Int {
        1 + (draft.app.options.removeExtensions ? 0 : draft.info.extensions.count) + (draft.app.options.removeWatch || !draft.info.hasWatch ? 0 : 1)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 22) {
                preview
                VStack(alignment: .leading, spacing: 14) {
                    Picker("", selection: $section) {
                        Text("App").tag(0)
                        Text("Compatibility").tag(1)
                        Text("Tweaks & Files").tag(2)
                        Text("Signing").tag(3)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    ScrollView {
                        Group {
                            switch section {
                            case 0: appSection
                            case 1: compatibilitySection
                            case 2: tweaksSection
                            default: signingSection
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.trailing, 6)
                    }
                }
            }
            .padding(22)
            Divider()
            footer.padding(.horizontal, 22).padding(.vertical, 14)
        }
        .frame(width: 780, height: 560)
    }

    // MARK: Preview column

    private var preview: some View {
        VStack(spacing: 14) {
            // Home-screen style preview of the icon and name as they'll appear on the phone.
            ZStack {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(LinearGradient(colors: [Color(red: 0.25, green: 0.2, blue: 0.5), Color(red: 0.1, green: 0.35, blue: 0.55)], startPoint: .topLeading, endPoint: .bottomTrailing))
                VStack(spacing: 8) {
                    AppIcon(path: draft.app.shownIcon, size: 84, name: draft.app.displayName)
                        .overlay(iconDrop ? RoundedRectangle(cornerRadius: 19).strokeBorder(.white, lineWidth: 3) : nil)
                    Text(draft.app.displayName).font(.system(size: 12, weight: .medium)).foregroundStyle(.white).lineLimit(1)
                        .frame(maxWidth: 120)
                }
            }
            .frame(width: 200, height: 170)
            .onDrop(of: [.fileURL], isTargeted: $iconDrop) { providers in
                _ = providers.first?.loadObject(ofClass: URL.self) { url, _ in
                    guard let url, NSImage(contentsOf: url) != nil else { return }
                    Task { @MainActor in draft.app.options.iconPath = url.path }
                }
                return true
            }
            .help("Drop an image here to use it as the icon")

            VStack(alignment: .leading, spacing: 6) {
                info("Original", draft.info.name)
                info("Bundle ID", draft.info.bundleId)
                info("Version", draft.info.version.isEmpty ? "—" : "\(draft.info.version) (\(draft.info.build))")
                info("Size", byteSize(draft.info.size))
                info("Min iOS", draft.info.minOS.isEmpty ? "—" : draft.info.minOS)
                if !draft.info.extensions.isEmpty { info("Extensions", "\(draft.info.extensions.count)") }
            }
            .frame(width: 200)
            Spacer()
        }
    }

    private func info(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).font(.system(size: 11)).foregroundStyle(.secondary).frame(width: 66, alignment: .leading)
            Text(value).font(.system(size: 11, weight: .medium)).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
        }
    }

    // MARK: Sections

    private var appSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            field("Name on the home screen", text: o.name, placeholder: draft.info.name)
            VStack(alignment: .leading, spacing: 6) {
                SectionTitle(title: "Icon")
                HStack {
                    Button("Choose Image…") {
                        if let url = pickFiles(types: ["png", "jpg", "jpeg", "heic", "icns", "tiff"]).first { o.iconPath.wrappedValue = url.path }
                    }
                    if !draft.app.options.iconPath.isEmpty {
                        Button("Use Original") { o.iconPath.wrappedValue = "" }
                    }
                    Text("or drop an image on the preview").font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            field("Bundle ID", text: o.bundleId, placeholder: draft.app.installedBundleId ?? "\(draft.info.bundleId).<team>",
                  note: draft.app.installedBundleId != nil
                    ? "Leave empty to keep \(draft.app.installedBundleId!), so refreshing keeps the app's data."
                    : "Leave empty for the usual ID with your team added. Change it to install a second copy.")
            field("Version", text: o.version, placeholder: draft.info.version)
            Toggle(isOn: draft.info.fileSharing ? .constant(true) : o.fileSharing) {
                SectionTitle(title: "Show in the Files app", subtitle: draft.info.fileSharing ? "This app already shows its documents in Files." : "Lets you reach the app's documents (saves, mods) from Files.")
            }
            .disabled(draft.info.fileSharing)
            Toggle(isOn: app.autoRefresh) {
                SectionTitle(title: "Refresh automatically", subtitle: "When the phone's connected and it has under \(Int(store.refreshWhenDaysLeft)) days left.")
            }
        }
    }

    private var compatibilitySection: some View {
        VStack(alignment: .leading, spacing: 14) {
            toggle(o.removeDeviceLimits, "Remove device restrictions", "Lets apps limited to some devices (iPad only, newer iPhones) install anywhere.", highlight: draft.info.deviceLimited)
            toggle(o.lowerMinOS, "Allow older iOS versions", "Sets the minimum iOS to 7.0.")
            field("Minimum iOS", text: o.minOS, placeholder: draft.info.minOS, note: "Or set an exact minimum version.")
            toggle(o.proMotion, "120 Hz ProMotion", "Unlocks high refresh rates on ProMotion iPhones.")
            toggle(o.gameMode, "Game Mode", "Tells iOS to give the app Game Mode priority.")
            toggle(o.iPadFullscreen, "Full screen on iPad", "Turns off Split View and Slide Over for the app.")
            toggle(o.liquidGlass, "Liquid Glass (iOS 26)", "Marks the app as built for iOS 26's design.")
            toggle(o.removeURLSchemes, "Remove URL schemes", "Stops the app opening from links (avoids clashes with the App Store copy).")
            Divider()
            SectionTitle(title: "Trim the app", subtitle: "Free Apple IDs get 10 App IDs a week. This install uses \(appIdCost).")
            toggle(o.removeExtensions, "Remove app extensions", draft.info.extensions.isEmpty ? "This app has none." : "Removes \(draft.info.extensions.joined(separator: ", ")).")
                .disabled(draft.info.extensions.isEmpty)
            toggle(o.removeWatch, "Remove the Apple Watch app", draft.info.hasWatch ? "Saves an App ID." : "This app has none.")
                .disabled(!draft.info.hasWatch)
        }
    }

    private var tweaksSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionTitle(title: "Tweaks", subtitle: ".deb, .dylib or .framework files injected into the app.")
            ForEach(draft.app.options.tweaks, id: \.self) { t in
                HStack {
                    Image(systemName: "puzzlepiece.extension").foregroundStyle(Color.accentColor)
                    Text((t as NSString).lastPathComponent).font(.system(size: 12))
                    Spacer()
                    Button { o.tweaks.wrappedValue.removeAll { $0 == t } } label: { Image(systemName: "minus.circle.fill") }.buttonStyle(.plain)
                }
                .padding(8).card()
            }
            Button("Add Tweaks…") {
                o.tweaks.wrappedValue += pickFiles(types: ["deb", "dylib", "framework", "bundle"], multiple: true).map(\.path)
            }
            toggle(o.elleKit, "Inject ElleKit", "The tweak loader. Added automatically when there are tweaks.")
            Divider()
            SectionTitle(title: "Replace files inside the app", subtitle: "e.g. swap a config or asset. The path is inside the .app.")
            ForEach(Array(draft.app.options.replaceFiles.keys.sorted()), id: \.self) { key in
                HStack {
                    Text(key).font(.system(size: 12, design: .monospaced))
                    Image(systemName: "arrow.left")
                    Text((draft.app.options.replaceFiles[key]! as NSString).lastPathComponent).font(.system(size: 12))
                    Spacer()
                    Button { o.replaceFiles.wrappedValue.removeValue(forKey: key) } label: { Image(systemName: "minus.circle.fill") }.buttonStyle(.plain)
                }
                .padding(8).card()
            }
            ReplaceFileRow { path, file in o.replaceFiles.wrappedValue[path] = file }
        }
    }

    private var signingSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Picker("Sign with", selection: app.signing) {
                ForEach(Signing.allCases) { Text($0.label).tag($0) }
            }
            switch draft.app.signing {
            case .appleID:
                Picker("Apple ID", selection: Binding(get: { draft.app.account ?? store.currentAccount?.email ?? "" }, set: { draft.app.account = $0 })) {
                    ForEach(store.accounts) { Text($0.email).tag($0.email) }
                    if store.accounts.isEmpty { Text("Sign in under Account first").tag("") }
                }
                Text("Free Apple IDs sign for 7 days, paid developer accounts for a year.").font(.system(size: 11)).foregroundStyle(.secondary)
            case .certificate:
                HStack {
                    Button("Choose Certificate…") { app.certFiles.wrappedValue = pickFiles(types: ["p12", "pem"], multiple: true).map(\.path) }
                    Text(draft.app.certFiles.map { ($0 as NSString).lastPathComponent }.joined(separator: ", ")).font(.system(size: 11)).foregroundStyle(.secondary)
                }
                HStack {
                    Button("Choose Provisioning Profile…") { app.profilePath.wrappedValue = pickFiles(types: ["mobileprovision"]).first?.path }
                    Text((draft.app.profilePath as NSString?)?.lastPathComponent ?? "").font(.system(size: 11)).foregroundStyle(.secondary)
                }
            case .adhoc:
                Text("Signs without a certificate. Only works on jailbroken phones or with TrollStore.").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Divider()
            Picker("Install on", selection: Binding(get: { draft.app.deviceUDID ?? store.selectedDevice?.udid ?? "" }, set: { u in
                draft.app.deviceUDID = u
                draft.app.deviceName = store.devices.first { $0.udid == u }?.name
            })) {
                ForEach(store.devices) { Text("\($0.name) (\($0.wifi ? "Wi-Fi" : "USB"))").tag($0.udid) }
                if let u = draft.app.deviceUDID, !store.devices.contains(where: { $0.udid == u }) {
                    Text("\(draft.app.deviceName ?? "Saved device") (not connected)").tag(u)
                }
            }
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack {
            if !draft.isNew {
                Button("Save Without Installing") {
                    store.update(draft.app)
                    dismiss()
                }
            }
            Spacer()
            Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
            Button("Export Signed IPA…") {
                let panel = NSSavePanel()
                panel.allowedContentTypes = [UTType(filenameExtension: "ipa") ?? .data]
                panel.nameFieldStringValue = "\(draft.app.displayName) (signed).ipa"
                if panel.runModal() == .OK, let url = panel.url {
                    store.install(draft.app, exportTo: url, exportOnly: true)
                    dismiss()
                }
            }
            Button(draft.isNew ? "Install" : "Save & Install") {
                store.install(draft.app)
                dismiss()
            }
            .buttonStyle(PrimaryButtonStyle())
            .keyboardShortcut(.defaultAction)
            .disabled(store.devices.isEmpty || (draft.app.signing == .appleID && store.accounts.isEmpty))
        }
    }

    // MARK: Helpers

    private func field(_ title: String, text: Binding<String>, placeholder: String, note: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            SectionTitle(title: title)
            TextField(placeholder, text: text).textFieldStyle(.roundedBorder)
            if let note { Text(note).font(.system(size: 11)).foregroundStyle(.secondary) }
        }
    }

    private func toggle(_ value: Binding<Bool>, _ title: String, _ subtitle: String, highlight: Bool = false) -> some View {
        Toggle(isOn: value) {
            HStack(spacing: 6) {
                SectionTitle(title: title, subtitle: subtitle)
                if highlight { Pill(text: "Recommended", color: .orange) }
            }
        }
    }
}

struct ReplaceFileRow: View {
    var add: (String, String) -> Void
    @State private var path = ""

    var body: some View {
        HStack {
            TextField("Path inside the app, e.g. Data/config.json", text: $path).textFieldStyle(.roundedBorder)
            Button("Choose File…") {
                if let url = pickFiles(types: []).first, !path.isEmpty {
                    add(path, url.path)
                    path = ""
                }
            }
            .disabled(path.isEmpty)
        }
    }
}
