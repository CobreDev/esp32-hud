import ServiceManagement
import SwiftUI

/// Menu bar popover, laid out like System Settings: grouped cards of rows, each with a
/// coloured icon tile, a title with detail text, and a control on the trailing edge.
struct PopoverView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        VStack(spacing: 14) {
            PreviewCircle(model: state.framePreview, enabled: state.hudEnabled)
                .padding(.top, 2)

            Card {
                hudRow
                CardDivider()
                screenRow
                CardDivider()
                displayRow
            }

            Card {
                musicRow
                CardDivider()
                weatherRow
                CardDivider()
                notificationsRow
                CardDivider()
                wallpaperRow
            }

            Card {
                loginRow
            }

            Button("Quit MacHUD") { NSApp.terminate(nil) }
                .buttonStyle(.plain)
                .font(.callout)
                .foregroundStyle(.secondary)
                .keyboardShortcut("q")
        }
        .padding(16)
        .frame(width: 300)
        .onAppear { state.refreshLaunchAtLogin() }
    }

    // MARK: - Rows

    private var hudRow: some View {
        Row(icon: "display", tint: .blue, title: "HUD",
            detail: state.hudEnabled ? "On" : "Off") {
            Toggle("HUD", isOn: $state.hudEnabled)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
        }
    }

    private var screenRow: some View {
        Row(icon: "square.grid.2x2.fill", tint: .indigo, title: "Screen",
            detail: state.screenChoice == .auto ? "Automatic · \(state.activeScreen.title)"
                                                : "Pinned · \(state.screenChoice.title)") {
            Picker("Screen", selection: $state.screenChoice) {
                ForEach(ScreenChoice.allCases) { Text($0.title).tag($0) }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .fixedSize()
        }
    }

    private var displayRow: some View {
        let info: (tint: Color, detail: String) = {
            switch state.linkStatus {
            case let .connected(port, fw): return (.green, "\(port) · firmware \(fw)")
            case let .searching(port): return (.orange, port.map { "Searching… \($0)" } ?? "Searching…")
            case .notFound: return (.red, "Not found. Plug in the display.")
            case .released: return (.gray, "Port released")
            }
        }()
        return Row(icon: "cable.connector", tint: info.tint, title: "Connection", detail: info.detail) {
            if state.linkStatus == .released {
                Button("Reconnect") { state.reconnect() }
            } else {
                Button("Release") { state.releasePort() }
                    .help("Close the serial port so Arduino IDE / esptool can upload firmware")
            }
        }
    }

    @ViewBuilder
    private var musicRow: some View {
        let (detail, color): (String, Color) = {
            switch state.sourceAvailability {
            case .active: return ("Playing on the HUD", .secondary)
            case .idle: return ("Nothing playing", .secondary)
            case .notRunning: return ("Not running", .secondary)
            case .error(let message): return (message, .secondary)
            case .permissionDenied: return ("Access denied", .red)
            }
        }()
        Row(icon: "music.note", tint: .red, title: "Apple Music", detail: detail, detailColor: color) {
            if state.sourceAvailability == .permissionDenied {
                Button("Retry") { state.retryMusicAccess() }
            }
        }
        if state.sourceAvailability == .permissionDenied {
            Note("Allow MacHUD to control Music in System Settings → Privacy & Security → Automation.") {
                Button("Open Settings") { SystemSettings.openPrivacy("Automation") }
            }
        }
    }

    @ViewBuilder
    private var wallpaperRow: some View {
        let (detail, color): (String, Color) = {
            switch state.wallpaperStatus {
            case .ok: return ("Blurred on the dashboard", .secondary)
            case .loading: return ("Loading…", .secondary)
            case .needsPermission: return ("Photos access needed", .orange)
            case .denied: return ("Photos access denied", .red)
            case .unavailable: return ("Wallpaper can't be read. Using black.", .secondary)
            }
        }()
        Row(icon: "photo.fill", tint: .teal, title: "Wallpaper", detail: detail, detailColor: color) {
            if state.wallpaperStatus == .needsPermission {
                Button("Allow") { state.requestWallpaperAccess() }
            }
        }
        if state.wallpaperStatus == .denied {
            Note("Turn on MacHUD in System Settings → Privacy & Security → Photos.") {
                Button("Open Settings") { SystemSettings.openPrivacy("Photos") }
            }
        }
    }

    @ViewBuilder
    private var notificationsRow: some View {
        let (detail, color): (String, Color) = {
            switch state.notificationStatus {
            case .watching: return ("Shown on the HUD for a few seconds", .secondary)
            case .needsPermission: return ("Accessibility access needed", .orange)
            case .unavailable: return ("Notification Center not found", .secondary)
            }
        }()
        Row(icon: "bell.badge.fill", tint: .red, title: "Notifications", detail: detail, detailColor: color) {
            if state.notificationStatus == .needsPermission {
                Button("Allow") { state.requestNotificationAccess() }
            }
        }
        if state.notificationStatus == .needsPermission {
            Note("MacHUD reads notification banners using Accessibility. Turn on MacHUD in System Settings → Privacy & Security → Accessibility.") {
                Button("Open Settings") { SystemSettings.openPrivacy("Accessibility") }
            }
        }
    }

    @ViewBuilder
    private var weatherRow: some View {
        let (detail, color): (String, Color) = {
            switch state.weatherStatus {
            case .ok(let place, let temp): return (place.isEmpty ? "\(temp)°" : "\(place) · \(temp)°", .secondary)
            case .locating: return ("Finding location…", .secondary)
            case .needsPermission: return ("Location access needed", .orange)
            case .denied: return ("Location access denied", .red)
            case .error(let message): return (message, .secondary)
            }
        }()
        Row(icon: "cloud.sun.fill", tint: Color(red: 0.04, green: 0.52, blue: 1), title: "Weather",
            detail: detail, detailColor: color) {
            if state.weatherStatus == .needsPermission {
                Button("Allow") { state.requestLocationAccess() }
            }
        }
        if state.weatherStatus == .denied {
            Note("Turn on MacHUD in System Settings → Privacy & Security → Location Services.") {
                Button("Open Settings") { SystemSettings.openPrivacy("LocationServices") }
            }
        }
    }

    @ViewBuilder
    private var loginRow: some View {
        Row(icon: "power", tint: Color(white: 0.5), title: "Launch at Login",
            detail: state.launchAtLoginNeedsApproval ? "Approval needed" : nil,
            detailColor: .orange) {
            Toggle("Launch at Login", isOn: Binding(
                get: { state.launchAtLogin },
                set: { state.setLaunchAtLogin($0) }))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
        }
        if state.launchAtLoginNeedsApproval {
            Note("Approve MacHUD in System Settings → General → Login Items.") {
                Button("Open Login Items") { SMAppService.openSystemSettingsLoginItems() }
            }
        }
    }
}

// MARK: - Building blocks

/// A rounded group, like a section in System Settings.
private struct Card<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(spacing: 0) { content }
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
    }
}

/// Hairline between rows, inset to line up with the text rather than the icon.
private struct CardDivider: View {
    var body: some View {
        Divider().padding(.leading, 48).opacity(0.6)
    }
}

/// One settings row: icon tile, title + detail, trailing control.
private struct Row<Trailing: View>: View {
    let icon: String
    let tint: Color
    let title: String
    var detail: String?
    var detailColor: Color = .secondary
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(tint.gradient, in: RoundedRectangle(cornerRadius: 6.5, style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 13, weight: .medium))
                if let detail {
                    Text(detail)
                        .font(.system(size: 11))
                        .foregroundStyle(detailColor)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer(minLength: 8)
            trailing
                .controlSize(.small)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(minHeight: 44)
    }
}

/// Explanatory text with an action, shown under a row when something needs the user.
private struct Note<Action: View>: View {
    let text: String
    @ViewBuilder var action: Action

    init(_ text: String, @ViewBuilder action: () -> Action) {
        self.text = text
        self.action = action()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(text)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            action.controlSize(.small)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.leading, 48)
        .padding(.trailing, 10)
        .padding(.bottom, 10)
    }
}

/// Live preview of the frame being sent. Observes only `FramePreview`, so it is the only
/// view that re-renders on every animation frame.
private struct PreviewCircle: View {
    @ObservedObject var model: FramePreview
    let enabled: Bool

    var body: some View {
        ZStack {
            Circle().fill(Color.black)
            if let img = model.image {
                Image(nsImage: img)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 220, height: 220)
                    .clipShape(Circle())
                    .opacity(enabled ? 1 : 0.35)
            }
            Circle().strokeBorder(
                LinearGradient(colors: [.white.opacity(0.28), .white.opacity(0.04)],
                               startPoint: .top, endPoint: .bottom),
                lineWidth: 1.5)
        }
        .frame(width: 220, height: 220)
        .shadow(color: .black.opacity(0.35), radius: 12, y: 5)
        .help(model.bytes > 0 ? "Last frame: \(model.bytes / 1024) KB JPEG" : "")
    }
}
