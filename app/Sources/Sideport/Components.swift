import AppKit
import SwiftUI

extension LibraryApp.Health {
    var color: Color {
        switch self {
        case .fresh: return .green
        case .soon: return .yellow
        case .urgent: return .orange
        case .expired: return .red
        case .unknown: return .secondary
        }
    }
}

/// An app icon with iOS's rounded-square shape.
struct AppIcon: View {
    var path: String?
    var size: CGFloat = 56
    /// Shown as a letter on a coloured tile when the app has no icon.
    var name: String = ""

    var body: some View {
        Group {
            if let path, let image = NSImage(contentsOfFile: path) {
                Image(nsImage: image).resizable().interpolation(.high)
            } else {
                let hue = Double(name.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) % 360 }) / 360
                ZStack {
                    LinearGradient(colors: [Color(hue: hue, saturation: 0.55, brightness: 0.85), Color(hue: hue, saturation: 0.7, brightness: 0.55)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                    Text(name.first.map { String($0).uppercased() } ?? "?")
                        .font(.system(size: size * 0.46, weight: .bold, design: .rounded)).foregroundStyle(.white)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.225, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: size * 0.225, style: .continuous).strokeBorder(.primary.opacity(0.08)))
        .shadow(color: .black.opacity(0.18), radius: size * 0.06, y: size * 0.03)
    }
}

/// Ring showing how much of the 7-day signature is left, with the days in the middle.
struct ExpiryRing: View {
    var app: LibraryApp
    var size: CGFloat = 44

    var body: some View {
        let days = app.daysLeft ?? 0
        let fraction = app.expires == nil ? 0 : max(0, min(1, days / 7))
        ZStack {
            Circle().stroke(.primary.opacity(0.08), lineWidth: 4)
            Circle()
                .trim(from: 0, to: fraction)
                .stroke(app.health.color, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                .rotationEffect(.degrees(-90))
            VStack(spacing: -2) {
                Text(app.expires == nil ? "?" : days <= 0 ? "!" : days < 1 ? "<1" : "\(Int(days))")
                    .font(.system(size: size * 0.32, weight: .bold, design: .rounded))
                    .foregroundStyle(app.health == .unknown ? .secondary : app.health.color)
                if app.expires != nil && days > 0 {
                    Text(days < 2 ? "day" : "days").font(.system(size: size * 0.17, weight: .medium)).foregroundStyle(.secondary)
                }
            }
        }
        .frame(width: size, height: size)
        .help(expiryText(app))
    }
}

func expiryText(_ app: LibraryApp) -> String {
    guard let e = app.expires else { return "Not installed by Sideport yet" }
    let days = e.timeIntervalSinceNow / 86_400
    if days <= 0 { return "Expired \(relative(e))" }
    let f = DateFormatter()
    f.dateFormat = "EEEE, MMM d 'at' h:mm a"
    return "Expires \(f.string(from: e))"
}

func relative(_ d: Date) -> String {
    let f = RelativeDateTimeFormatter()
    f.unitsStyle = .full
    return f.localizedString(for: d, relativeTo: Date())
}

func byteSize(_ n: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: n, countStyle: .file)
}

/// Small rounded label, e.g. "New build" or "Wi-Fi".
struct Pill: View {
    var text: String
    var symbol: String? = nil
    var color: Color = .accentColor

    var body: some View {
        HStack(spacing: 4) {
            if let symbol { Image(systemName: symbol).font(.system(size: 9, weight: .bold)) }
            Text(text).font(.system(size: 10.5, weight: .semibold))
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(color.opacity(0.15), in: Capsule())
        .foregroundStyle(color)
    }
}

/// Card background used throughout.
struct CardBackground: ViewModifier {
    var highlighted = false
    func body(content: Content) -> some View {
        content
            .background(.background.opacity(0.6), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(highlighted ? Color.accentColor.opacity(0.6) : Color.primary.opacity(0.07), lineWidth: highlighted ? 1.5 : 1)
            )
    }
}

extension View {
    func card(highlighted: Bool = false) -> some View { modifier(CardBackground(highlighted: highlighted)) }
}

/// Big prominent button with a gradient, for the main action on a screen.
struct PrimaryButtonStyle: ButtonStyle {
    var color: Color = .accentColor
    func makeBody(configuration: Configuration) -> some View {
        StyledLabel(configuration: configuration, color: color)
    }

    private struct StyledLabel: View {
        let configuration: Configuration
        let color: Color
        @Environment(\.isEnabled) private var enabled

        var body: some View {
            configuration.label
            .font(.system(size: 13, weight: .semibold))
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(
                LinearGradient(colors: [color, color.opacity(0.8)], startPoint: .top, endPoint: .bottom),
                in: RoundedRectangle(cornerRadius: 9, style: .continuous)
            )
            .foregroundStyle(.white)
            .saturation(enabled ? 1 : 0)
            .opacity(enabled ? (configuration.isPressed ? 0.8 : 1) : 0.45)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
        }
    }
}

struct SectionTitle: View {
    var title: String
    var subtitle: String? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.system(size: 13, weight: .semibold))
            if let subtitle { Text(subtitle).font(.system(size: 11.5)).foregroundStyle(.secondary) }
        }
    }
}

/// Picks files with the standard open panel.
@MainActor
func pickFiles(types: [String], multiple: Bool = false, directories: Bool = false, message: String? = nil) -> [URL] {
    let panel = NSOpenPanel()
    panel.allowsMultipleSelection = multiple
    panel.canChooseDirectories = directories
    panel.canChooseFiles = !directories
    if !types.isEmpty { panel.allowedFileTypes = types }
    panel.message = message
    return panel.runModal() == .OK ? panel.urls : []
}
