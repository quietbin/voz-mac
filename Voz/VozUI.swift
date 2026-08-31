//
//  VozUI.swift
//  Voz
//
//  The desktop window UI, built in SwiftUI and styled after the Voz website:
//  the five-bar gradient logo, the red→violet→blue accent, SF Pro type, pill /
//  stadium shapes, 20px panels. It observes AppState and drives the AppKit
//  backend (recorder / whisper / hotkey) through AppState's callbacks.
//

import SwiftUI
import UniformTypeIdentifiers
import Carbon.HIToolbox

// MARK: - Brand tokens

enum Theme {
    static let red    = Color(hex: 0xE82039)
    static let violet = Color(hex: 0x8D2CE0)
    static let blue   = Color(hex: 0x2B3CF2)

    /// The app-icon gradient: red lower-left → blue upper-right (matches favicon).
    static let iconGradient = LinearGradient(colors: [red, violet, blue],
                                             startPoint: .bottomLeading, endPoint: .topTrailing)
    /// The horizontal brand gradient used on text/marks/accents.
    static let gradient = LinearGradient(colors: [red, violet, blue],
                                         startPoint: .leading, endPoint: .trailing)

    static let panelRadius: CGFloat = 20
    static let sidebarWidth: CGFloat = 224
}

extension Color {
    init(hex: UInt) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xff) / 255,
                  green: Double((hex >> 8) & 0xff) / 255,
                  blue: Double(hex & 0xff) / 255,
                  opacity: 1)
    }
}

// MARK: - Logo mark

/// The five-bar Voz mark on its gradient tile — geometry taken from favicon.svg.
/// (Sidebar uses this vector drawing; the dock/app icon uses the Voz3 image.)
struct BrandLogo: View {
    var size: CGFloat = 30

    /// The app/dock icon image (Voz3). Not used for the sidebar mark.
    static let iconImage: NSImage? = NSImage(named: "VozLogo")
        ?? Bundle.main.url(forResource: "VozLogo", withExtension: "png").flatMap { NSImage(contentsOf: $0) }

    var body: some View {
        RoundedRectangle(cornerRadius: size * 28 / 128, style: .continuous)
            .fill(Theme.iconGradient)
            .frame(width: size, height: size)
            .overlay {
                Canvas { ctx, _ in
                    let k = size / 128
                    let bars: [(CGFloat, CGFloat, CGFloat, CGFloat)] = [
                        (36, 0, 40, 15), (13, 23, 86, 15), (0, 46, 112, 15),
                        (13, 69, 86, 15), (36, 92, 40, 15),
                    ]
                    for b in bars {
                        let rect = CGRect(x: (24 + b.0 * 0.714) * k,
                                          y: (25.8 + b.1 * 0.714) * k,
                                          width: b.2 * 0.714 * k,
                                          height: b.3 * 0.714 * k)
                        ctx.fill(Path(roundedRect: rect, cornerRadius: rect.height / 2),
                                 with: .color(.white))
                    }
                }
            }
            .accessibilityLabel("Voz")
    }
}

// MARK: - Root

enum VozTab: String, CaseIterable, Identifiable {
    case dictate = "Dictate"
    case meetings = "Meetings"
    case files = "Transcribe"
    case history = "History"
    case settings = "Settings"
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .dictate: return "mic"
        case .meetings: return "person.wave.2"
        case .files: return "square.and.arrow.down"
        case .history: return "clock"
        case .settings: return "gearshape"
        }
    }
}

struct RootView: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        HStack(spacing: 0) {
            Sidebar()
            Group {
                switch app.selectedTab {
                case .dictate:  DictateView()
                case .meetings: MeetingsView()
                case .files:    FilesView()
                case .history:  HistoryView()
                case .settings: SettingsView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(alignment: .top) {
                ZStack(alignment: .top) {
                    Color(nsColor: .windowBackgroundColor)
                    // Faint continuation of the header gradient across the content.
                    LinearGradient(colors: [Theme.red.opacity(0.05), .clear],
                                   startPoint: .top, endPoint: .bottom)
                        .frame(height: 150)
                }
            }
        }
        .frame(minWidth: 860, minHeight: 580)
        .ignoresSafeArea(.container, edges: .top)
        // No floating banner: the sidebar pill expands into the announcement
        // itself, so the news appears once, in the place that already reports
        // which version you are on.
    }
}


// MARK: - Sidebar

struct Sidebar: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                BrandLogo(size: 30)
                Text("Voz")
                    .font(.system(size: 24, weight: .semibold))
                    .tracking(-0.5)
            }
            .padding(.horizontal, 18)
            .padding(.top, 44)   // clear the traffic-light buttons above
            .padding(.bottom, 24)

            VStack(spacing: 5) {
                ForEach(VozTab.allCases) { t in
                    SidebarItem(tab: t, selected: app.selectedTab == t) {
                        withAnimation(.easeOut(duration: 0.15)) { app.selectedTab = t }
                    }
                }
            }
            .padding(.horizontal, 12)

            Spacer()

            StatusPill()
                .padding(.horizontal, 16)
                .padding(.bottom, 16)
        }
        .frame(width: Theme.sidebarWidth)
        .background(alignment: .top) {
            ZStack(alignment: .top) {
                // Bright, clean base instead of the dull system gray.
                Color(nsColor: .textBackgroundColor)
                // A soft brand wash at the top so the sidebar feels alive.
                LinearGradient(
                    colors: [Theme.red.opacity(0.10), Theme.red.opacity(0.06), .clear],
                    startPoint: .top, endPoint: .bottom)
                    .frame(height: 260)
            }
        }
        .overlay(alignment: .trailing) {
            Rectangle().fill(Color.primary.opacity(0.07)).frame(width: 1)
        }
    }
}

struct SidebarItem: View {
    let tab: VozTab
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 11) {
                Image(systemName: tab.icon)
                    .font(.system(size: 14, weight: .semibold))
                    .frame(width: 20)
                    .foregroundStyle(selected ? AnyShapeStyle(Theme.gradient)
                                     : AnyShapeStyle(Color.secondary))
                Text(tab.rawValue)
                    .font(.system(size: 14.5, weight: selected ? .semibold : .medium))
                    .foregroundStyle(selected ? AnyShapeStyle(Color.primary)
                                     : AnyShapeStyle(Color.primary.opacity(0.82)))
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(selected
                          ? AnyShapeStyle(LinearGradient(
                                colors: [Theme.red.opacity(0.16), Theme.red.opacity(0.14), Theme.blue.opacity(0.14)],
                                startPoint: .leading, endPoint: .trailing))
                          : AnyShapeStyle(hovering ? Color.primary.opacity(0.06) : Color.clear))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .stroke(Theme.red.opacity(selected ? 0.28 : 0), lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// Live status at the bottom of the sidebar: state + active model.
/// Bottom of the sidebar: which version you're running, and whether it's the
/// newest one. Recording state lives on the Dictate page and the menu-bar icon
/// already, so this corner is better spent on the thing you can't see anywhere
/// else.
struct StatusPill: View {
    @ObservedObject private var updater = Updater.shared
    @State private var hovering = false

    private var hasUpdate: Bool { updater.pendingBuildDisplay != nil }

    private var dotColor: Color {
        if hasUpdate { return Theme.red }
        return updater.lastChecked == nil ? .secondary : .green
    }

    private var statusText: String {
        if case .stagedForNextLaunch(let v) = updater.phase { return "\(v) installs on quit" }
        if updater.isChecking { return "Checking…" }
        if case .failed(let message) = updater.phase { return message }
        if let waiting = updater.pendingBuildDisplay { return "Version \(waiting) available" }
        if !updater.automaticallyChecksForUpdates { return "Click to check for updates" }
        return updater.lastChecked == nil ? "Checking…" : "Up to date"
    }

    var body: some View {
        Group {
            if let update = updater.availableUpdate {
                announcement(update)
            } else {
                compact
            }
        }
        .animation(.easeInOut(duration: 0.28), value: updater.availableUpdate)
    }

    // MARK: - The everyday state

    private var compact: some View {
        Button(action: act) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 7) {
                    Circle().fill(dotColor).frame(width: 8, height: 8)
                    Text("Voz \(updater.shortVersion)")
                        .font(.system(size: 12.5, weight: .medium))
                }
                HStack(spacing: 6) {
                    if updater.isChecking {
                        ProgressView().progressViewStyle(.circular).controlSize(.mini)
                    } else {
                        Image(systemName: hasUpdate ? "arrow.down.circle" : "checkmark.seal")
                            .font(.system(size: 10))
                            .foregroundStyle(hasUpdate ? Theme.red : .secondary)
                    }
                    Text(statusText)
                        .font(.system(size: 11.5))
                        .foregroundStyle(hasUpdate ? Theme.red : .secondary)
                        .lineLimit(1).truncationMode(.tail)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.primary.opacity(hovering ? 0.09 : 0.05)))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .disabled(updater.isChecking)
        .help(hasUpdate ? "Show the update again" : "Check for updates now")
    }

    // MARK: - The "there's a new version" state
    //
    // Wearing the app's own gradient rather than a warning colour: a new
    // release is good news, not an error. It collapses back to `compact` the
    // moment it is dismissed or installed.

    private func announcement(_ update: AvailableUpdate) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.system(size: 14, weight: .semibold))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Voz \(update.version) is here")
                        .font(.system(size: 12.5, weight: .semibold))
                    Text("You're on \(updater.shortVersion)")
                        .font(.system(size: 11)).opacity(0.85)
                }
                Spacer(minLength: 0)
                Button { updater.dismissAvailableUpdate() } label: {
                    Image(systemName: "xmark").font(.system(size: 10, weight: .bold))
                }
                .buttonStyle(.plain)
                .help("Not now")
            }

            action
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(Theme.iconGradient)
            .shadow(color: Theme.violet.opacity(0.35), radius: 10, y: 3))
        .transition(.scale(scale: 0.96).combined(with: .opacity))
    }

    /// One row that changes with the phase: Update → progress → Relaunch.
    /// The card never goes away and never hands off to another window, so the
    /// whole update happens in the place the user clicked.
    @ViewBuilder private var action: some View {
        switch updater.phase {
        case .downloading, .extracting:
            working("Updating…")
        case .stagedForNextLaunch:
            HStack(spacing: 7) {
                Image(systemName: "checkmark.circle.fill").font(.system(size: 11))
                Text("Installs when you quit Voz")
                    .font(.system(size: 11.5, weight: .medium)).opacity(0.95)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 3)
        case .readyToRelaunch:
            HStack(spacing: 8) {
                capsuleButton("Relaunch") { updater.relaunchNow() }
                Button("Later") { updater.installOnNextQuit() }
                    .buttonStyle(.plain)
                    .font(.system(size: 11)).opacity(0.85)
                    .help("Install the next time you quit Voz")
            }
        case .installing:
            working("Installing…")
        case .failed(let message):
            VStack(alignment: .leading, spacing: 6) {
                Text(message).font(.system(size: 10.5)).opacity(0.9).lineLimit(3)
                capsuleButton("Try again") { updater.installAvailableUpdate() }
            }
        case .idle:
            capsuleButton("Update") { updater.installAvailableUpdate() }
        }
    }

    private func capsuleButton(_ title: String, _ run: @escaping () -> Void) -> some View {
        Button(action: run) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                .background(Capsule().fill(.white.opacity(0.22)))
        }
        .buttonStyle(.plain)
    }

    /// No bar and no byte counts. How many megabytes are in flight is the app's
    /// problem, not the user's — they asked for a new version, not a transfer
    /// report. A spinner says "working" and nothing more.
    private func working(_ label: String) -> some View {
        HStack(spacing: 7) {
            ProgressView()
                .progressViewStyle(.circular)
                .controlSize(.small)
                .tint(.white)
            Text(label).font(.system(size: 11.5, weight: .medium)).opacity(0.95)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 3)
    }

    private func act() {
        if hasUpdate { updater.restoreAvailableUpdate() } else { updater.checkForUpdates(nil) }
    }
}

// MARK: - Shared bits

/// A titled content panel with the brand's 20px radius.
struct Panel<Content: View>: View {
    var title: String? = nil
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let title {
                Text(title).font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary).tracking(0.3).textCase(.uppercase)
            }
            content
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Theme.panelRadius, style: .continuous)
            .fill(Color.primary.opacity(0.035)))
        .overlay(RoundedRectangle(cornerRadius: Theme.panelRadius, style: .continuous)
            .stroke(Color.primary.opacity(0.06), lineWidth: 1))
    }
}

struct PageHeader: View {
    let title: String
    let subtitle: String
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 30, weight: .semibold)).tracking(-0.8)
            Text(subtitle).font(.system(size: 15)).foregroundStyle(.secondary)
        }
    }
}

// MARK: - Dictate (home)

struct DictateView: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 26) {
                PageHeader(title: "Dictate",
                           subtitle: "Press your shortcut anywhere, or use the button below. 100% on-device.")

                HStack {
                    Spacer()
                    RecordButton()
                    Spacer()
                }
                .padding(.vertical, 8)

                HStack(spacing: 12) {
                    // Model — click to change.
                    ChipMenu(icon: "cpu", label: "Model", value: app.currentModelName) {
                        ForEach(WhisperModels.available, id: \.path) { m in
                            Button {
                                Settings.shared.modelPath = m.path
                                app.refreshModelName()
                            } label: {
                                Label(WhisperModels.labelWithSize(forPath: m.path),
                                      systemImage: m.path == Settings.shared.modelPath ? "checkmark" : "")
                            }
                        }
                    }
                    // Language — click to change.
                    ChipMenu(icon: "globe", label: "Language",
                             value: Languages.name(for: Settings.shared.language)) {
                        ForEach(Languages.all) { l in
                            Button {
                                Settings.shared.language = l.code
                                app.objectWillChange.send()
                            } label: {
                                Label(l.name, systemImage: l.code == Settings.shared.language ? "checkmark" : "")
                            }
                        }
                    }
                    // Shortcut — click to re-record.
                    ShortcutChip()
                }

                if !app.dictations.isEmpty {
                    Text("Your dictations").font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.secondary).tracking(0.3).textCase(.uppercase)
                        .padding(.top, 4)
                    ForEach(app.dictations) { entry in
                        HistoryRow(entry: entry)
                    }
                }
            }
            .padding(EdgeInsets(top: 48, leading: 28, bottom: 28, trailing: 28))
        }
        .overlay(alignment: .bottom) { BannerView() }
    }
}

struct RecordButton: View {
    @EnvironmentObject var app: AppState
    @State private var pulse = false

    private var recording: Bool { app.status == .recording }
    private var busy: Bool { app.status == .transcribing }

    var body: some View {
        Button {
            app.toggleRecord()
        } label: {
            ZStack {
                Circle()
                    .fill(recording ? AnyShapeStyle(Theme.gradient)
                          : AnyShapeStyle(Color.primary.opacity(0.06)))
                    .frame(width: 132, height: 132)
                    .overlay(Circle().stroke(recording ? .clear : Color.primary.opacity(0.12), lineWidth: 1.5))
                    .overlay {
                        if recording {
                            Circle().stroke(Theme.red.opacity(0.4), lineWidth: 2)
                                .scaleEffect(pulse ? 1.25 : 1).opacity(pulse ? 0 : 0.7)
                        }
                    }
                if busy {
                    ProgressView().controlSize(.large)
                } else {
                    Image(systemName: recording ? "stop.fill" : "mic.fill")
                        .font(.system(size: 40, weight: .medium))
                        .foregroundStyle(recording ? AnyShapeStyle(.white) : AnyShapeStyle(Theme.gradient))
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(busy)
        .onChange(of: recording) { on in
            pulse = false
            if on { withAnimation(.easeOut(duration: 1).repeatForever(autoreverses: false)) { pulse = true } }
        }
        .overlay(alignment: .bottom) {
            Text(busy ? "Transcribing…" : (recording ? "Click to stop" : "Click to start"))
                .font(.system(size: 13.5, weight: .medium))
                .foregroundStyle(.secondary)
                .offset(y: 30)
        }
        .padding(.bottom, 30)
    }
}

/// Shared chip look for the Dictate quick-controls (Model / Language / Shortcut).
private struct DictateChip<Trailing: View>: View {
    let icon: String
    let label: String
    let value: String
    var active: Bool = false
    var hovering: Bool = false
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon).font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.red)
            VStack(alignment: .leading, spacing: 1) {
                Text(label).font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                Text(value).font(.system(size: 13, weight: .medium)).lineLimit(1)
                    .foregroundStyle(active ? Theme.red : .primary)
            }
            Spacer(minLength: 4)
            trailing
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: 46)
        .contentShape(Rectangle())
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(active ? Theme.red.opacity(0.08) : Color.primary.opacity(hovering ? 0.09 : 0.05)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .stroke(active ? Theme.red.opacity(0.5) : Color.primary.opacity(hovering ? 0.28 : 0.14), lineWidth: 1))
    }
}

/// A chip that opens a menu to change a setting in place (Model, Language). The
/// WHOLE box is clickable and shows a dropdown chevron.
struct ChipMenu<MenuContent: View>: View {
    let icon: String
    let label: String
    let value: String
    @ViewBuilder var menuContent: MenuContent
    @State private var hovering = false

    var body: some View {
        Menu {
            menuContent
        } label: {
            HStack(spacing: 8) {
                Image(systemName: icon).font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.red)
                VStack(alignment: .leading, spacing: 1) {
                    Text(label).font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                    Text(value).font(.system(size: 13, weight: .medium)).lineLimit(1)
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.down").font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Theme.red)
                    .frame(width: 22, height: 22)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Theme.red.opacity(0.14)))
            }
        }
        .menuStyle(.button)
        .buttonStyle(ChipButtonStyle(hovering: hovering))
        .menuIndicator(.hidden)
        .frame(maxWidth: .infinity)
        .onHover { hovering = $0 }
    }
}

/// Draws the chip box and makes the entire area clickable (used by ChipMenu).
struct ChipButtonStyle: ButtonStyle {
    var hovering: Bool
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 12).padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: 46)
            .contentShape(Rectangle())
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.primary.opacity(hovering ? 0.09 : 0.05)))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.primary.opacity(hovering ? 0.3 : 0.16), lineWidth: 1))
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

/// A chip you click to re-record the global dictation shortcut, right in place.
struct ShortcutChip: View {
    @EnvironmentObject var app: AppState
    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        Button { toggle() } label: {
            DictateChip(icon: "command", label: "Shortcut",
                        value: recording ? "Press keys…" : Settings.shared.hotKey.displayString,
                        active: recording) {
                EmptyView()
            }
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
        .help("Click, then press the keys you want to use to start/stop dictation.")
        .onDisappear { stop() }
    }

    private func toggle() { recording ? stop() : start() }

    private func start() {
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { event in
            if event.keyCode == UInt16(kVK_Escape) { self.stop(); return nil }
            let mods = HotKey.carbonModifiers(from: event.modifierFlags)
            let isFunctionKey = (kVK_F1...kVK_F20).contains(Int(event.keyCode))
            guard mods != 0 || isFunctionKey else { NSSound.beep(); return nil }
            Settings.shared.hotKey = HotKey(keyCode: UInt32(event.keyCode), carbonModifiers: mods)
            Settings.shared.triggerMode = .hotKey
            self.app.reloadHotkey()
            self.stop()
            return nil   // consume the keystroke
        }
    }

    private func stop() {
        recording = false
        if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
    }
}

// MARK: - Meetings

struct MeetingsView: View {
    @EnvironmentObject var app: AppState
    @State private var startDate = Date()
    @State private var expandedID: UUID?
    @State private var search = ""
    @State private var dateFilter: MeetingDateFilter = .all

    enum MeetingDateFilter: String, CaseIterable, Identifiable {
        case all = "All time", today = "Today", week = "Last 7 days", month = "Last 30 days"
        var id: String { rawValue }
    }


    /// Meetings filtered by the search box (title + full content) and date range.
    private var filteredMeetings: [HistoryEntry] {
        let q = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let now = Date()
        return app.meetings.filter { m in
            switch dateFilter {
            case .all:   break
            case .today: if !Calendar.current.isDateInToday(m.date) { return false }
            case .week:  if m.date < now.addingTimeInterval(-7 * 86_400) { return false }
            case .month: if m.date < now.addingTimeInterval(-30 * 86_400) { return false }
            }
            guard !q.isEmpty else { return true }
            if m.displayTitle.lowercased().contains(q) { return true }
            if m.text.lowercased().contains(q) { return true }           // full transcript
            if (m.summary ?? "").lowercased().contains(q) { return true }
            if let items = m.actionItems, items.contains(where: { $0.text.lowercased().contains(q) }) { return true }
            return false
        }
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 22) {
                PageHeader(title: "Meeting notes",
                           subtitle: "Captures the call audio + your mic, transcribes locally, and saves it here. Nothing leaves your Mac — no bot joins the call.")

                controlCard

                if !app.meetings.isEmpty {
                    HStack(spacing: 10) {
                        Text("Your meetings").font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.secondary).tracking(0.3).textCase(.uppercase)
                        Spacer()
                        // Date-range filter
                        Menu {
                            ForEach(MeetingDateFilter.allCases) { f in
                                Button {
                                    dateFilter = f
                                } label: {
                                    Label(f.rawValue, systemImage: dateFilter == f ? "checkmark" : "")
                                }
                            }
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: "calendar").font(.system(size: 11))
                                Text(dateFilter.rawValue).font(.system(size: 12.5))
                                Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold))
                            }
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .background(Capsule().fill(Color.primary.opacity(0.06)))
                        }
                        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                        // Search
                        HStack(spacing: 6) {
                            Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(.secondary)
                            TextField("Search content", text: $search).textFieldStyle(.plain)
                                .font(.system(size: 12.5)).frame(width: 150)
                            if !search.isEmpty {
                                Button { search = "" } label: { Image(systemName: "xmark.circle.fill") }
                                    .buttonStyle(.plain).foregroundStyle(.secondary)
                            }
                        }
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(Capsule().fill(Color.primary.opacity(0.06)))
                    }
                    .padding(.top, 4)

                    if filteredMeetings.isEmpty {
                        Text("No meetings match your search/filter.")
                            .font(.system(size: 13)).foregroundStyle(.secondary).padding(.top, 8)
                    }
                    ForEach(filteredMeetings) { meeting in
                        MeetingListRow(
                            meeting: meeting,
                            expanded: expandedID == meeting.id,
                            summarizing: app.meetingSummarizing && meeting.id == app.meetings.first?.id,
                            onToggle: { expandedID = (expandedID == meeting.id) ? nil : meeting.id })
                    }
                }
            }
            .padding(EdgeInsets(top: 48, leading: 28, bottom: 28, trailing: 28))
        }
        .overlay(alignment: .bottom) { BannerView() }
        .onChange(of: app.meetingPhase) { phase in
            if phase == .done { expandedID = app.meetings.first?.id }   // reveal the fresh one
        }
    }

    @ViewBuilder private var controlCard: some View {
        VStack(spacing: 14) {
            switch app.meetingPhase {
            case .idle, .done:
                Image(systemName: "person.wave.2").font(.system(size: 36, weight: .light))
                    .foregroundStyle(Theme.gradient)
                Text(app.meetingPhase == .done ? "Saved below" : "Ready to capture your meeting")
                    .font(.system(size: 16, weight: .medium))
                Button { startDate = Date(); app.meetingPhase = .idle; app.startMeeting() } label: {
                    Label("Start meeting", systemImage: "record.circle")
                }.buttonStyle(GradientButtonStyle())

                // Meeting transcription model — same dropdown style as Dictate.
                ChipMenu(icon: "cpu", label: "Model",
                         value: WhisperModels.shortLabel(forPath: Settings.shared.meetingModelPath)) {
                    ForEach(WhisperModels.available, id: \.path) { m in
                        Button {
                            Settings.shared.meetingModelPath = m.path
                            app.objectWillChange.send()
                        } label: {
                            Label(WhisperModels.labelWithSize(forPath: m.path),
                                  systemImage: m.path == Settings.shared.meetingModelPath ? "checkmark" : "")
                        }
                    }
                }
                .frame(maxWidth: 260)
            case .recording:
                HStack(spacing: 10) {
                    Circle().fill(Theme.red).frame(width: 12, height: 12)
                    TimelineView(.periodic(from: startDate, by: 1)) { ctx in
                        Text(elapsed(startDate, ctx.date))
                            .font(.system(size: 30, weight: .semibold, design: .monospaced))
                    }
                }
                Text(app.meetingCapturingSystem ? "Capturing call + your mic" : "Capturing your mic only")
                    .font(.system(size: 12.5)).foregroundStyle(.secondary)
                Button { app.stopMeeting(notes: "") } label: {
                    Label("Stop & transcribe", systemImage: "stop.circle")
                }.buttonStyle(GradientButtonStyle())
            case .transcribing:
                ProgressView().controlSize(.large)
                Text("Transcribing your meeting locally…").font(.system(size: 15, weight: .medium))
            }
        }
        .frame(maxWidth: .infinity).padding(28)
        .background(RoundedRectangle(cornerRadius: Theme.panelRadius, style: .continuous)
            .fill(Color.primary.opacity(0.035)))
        .overlay(RoundedRectangle(cornerRadius: Theme.panelRadius, style: .continuous)
            .stroke(Color.primary.opacity(0.06), lineWidth: 1))
    }

    private func elapsed(_ start: Date, _ now: Date) -> String {
        let s = max(0, Int(now.timeIntervalSince(start)))
        return String(format: "%02d:%02d", s / 60, s % 60)
    }
}

/// One saved meeting: a renamable title + date, expandable to transcript,
/// notes, and auto-extracted follow-ups.
struct MeetingListRow: View {
    @EnvironmentObject var app: AppState
    let meeting: HistoryEntry
    let expanded: Bool
    let summarizing: Bool
    let onToggle: () -> Void

    @State private var editing = false
    @State private var draft = ""
    @State private var separating = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "person.wave.2").font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.red)

                if editing {
                    TextField("Meeting name", text: $draft, onCommit: commit)
                        .textFieldStyle(.roundedBorder).font(.system(size: 14, weight: .medium))
                        .frame(maxWidth: 240)
                    Button("Save", action: commit).buttonStyle(.borderless)
                } else {
                    // Click the name to rename it.
                    Button { draft = meeting.displayTitle; editing = true } label: {
                        Text(meeting.displayTitle).font(.system(size: 14, weight: .medium))
                    }.buttonStyle(.plain)
                    Text(meeting.date, format: .dateTime.month().day().year().hour().minute())
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }

                Spacer()

                Button(role: .destructive) { app.deleteMeeting(meeting.id) } label: {
                    Image(systemName: "trash")
                }.buttonStyle(.borderless).foregroundStyle(.secondary)
                Image(systemName: expanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            }
            .padding(16)
            .contentShape(Rectangle())
            .onTapGesture { if !editing { onToggle() } }

            if expanded {
                VStack(alignment: .leading, spacing: 14) {
                    Divider()

                    // Structured summary (overview / decisions / discussion).
                    if summarizing || meeting.summary != nil {
                        VStack(alignment: .leading, spacing: 6) {
                            Label("Summary", systemImage: "doc.text").font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(Theme.red)
                            if summarizing && meeting.summary == nil {
                                HStack(spacing: 8) {
                                    ProgressView().controlSize(.small)
                                    Text("Summarizing…").font(.system(size: 12.5)).foregroundStyle(.secondary)
                                }
                            } else if let s = meeting.summary {
                                Text(s).font(.system(size: 13.5)).textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.045)))
                    }

                    if let notes = meeting.notes, !notes.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Label("My notes", systemImage: "pencil").font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.secondary)
                            Text(notes).font(.system(size: 13.5)).textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Transcript").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                        Text(meeting.displayTranscript).font(.system(size: 13.5)).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    HStack(spacing: 14) {
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(meeting.displayTranscript, forType: .string)
                            app.flash("Copied")
                        } label: { Label("Copy", systemImage: "doc.on.doc").font(.system(size: 12.5)) }
                            .buttonStyle(.borderless)

                        // On-demand speaker/turn separation (best-effort, from the text).
                        if meeting.separatedText == nil && LocalLLM.shared.isReady {
                            Button(action: separate) {
                                if separating {
                                    HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Separating…") }
                                        .font(.system(size: 12.5))
                                } else {
                                    Label("Separate speakers", systemImage: "person.2.wave.2").font(.system(size: 12.5))
                                }
                            }.buttonStyle(.borderless).disabled(separating)
                        }
                    }
                }
                .padding([.horizontal, .bottom], 16)
            }
        }
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.primary.opacity(0.035)))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Color.primary.opacity(0.06), lineWidth: 1))
    }

    private func separate() {
        separating = true
        app.flash("Separating speakers locally…")
        let text = meeting.text
        let id = meeting.id
        DispatchQueue.global(qos: .userInitiated).async {
            let result = LocalLLM.shared.separateTranscript(text)
            DispatchQueue.main.async {
                separating = false
                app.setMeetingSeparated(result, for: id)
            }
        }
    }

    private func commit() {
        app.renameMeeting(meeting.id, to: draft)
        editing = false
    }
}

/// Rename a detected meeting speaker (e.g. "Speaker 1" → "Alex").
struct SpeakerRenameRow: View {
    @EnvironmentObject var app: AppState
    let meetingID: UUID
    let label: String
    let currentName: String?
    @State private var draft = ""

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "person.crop.circle.fill").font(.system(size: 14)).foregroundStyle(Theme.red)
            Text(label).font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(.secondary).frame(width: 74, alignment: .leading)
            TextField("Add a name", text: $draft, onCommit: commit)
                .textFieldStyle(.roundedBorder).font(.system(size: 12.5)).frame(width: 170)
            if !draft.isEmpty {
                Button("Save", action: commit).buttonStyle(.borderless).font(.system(size: 12))
            }
        }
        .onAppear { draft = currentName ?? "" }
    }

    private func commit() { app.renameSpeaker(meetingID, label: label, to: draft) }
}

/// One follow-up: check it off, give it a due date, or remove it.
struct ActionItemRow: View {
    @EnvironmentObject var app: AppState
    let meetingID: UUID
    let item: ActionItem
    @State private var showPicker = false
    @State private var tempDate = Date()

    var body: some View {
        HStack(alignment: .center, spacing: 9) {
            Button { app.toggleActionItem(meetingID, item.id) } label: {
                Image(systemName: item.done ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 15))
                    .foregroundStyle(item.done ? Theme.red : Color.secondary)
            }.buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.text).font(.system(size: 13.5))
                    .strikethrough(item.done, color: .secondary)
                    .foregroundStyle(item.done ? .secondary : .primary)
                if let due = item.dueDate {
                    HStack(spacing: 4) {
                        Image(systemName: "calendar").font(.system(size: 9))
                        Text(due, format: .dateTime.month().day().hour().minute())
                            .font(.system(size: 11, weight: .medium))
                    }.foregroundStyle(Theme.red)
                }
            }
            Spacer()

            Button { tempDate = item.dueDate ?? Date(); showPicker = true } label: {
                Image(systemName: item.dueDate == nil ? "calendar.badge.plus" : "calendar")
                    .font(.system(size: 12))
            }
            .buttonStyle(.borderless).foregroundStyle(.secondary)
            .popover(isPresented: $showPicker, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 10) {
                    DatePicker("Due", selection: $tempDate, displayedComponents: [.date, .hourAndMinute])
                        .datePickerStyle(.graphical).labelsHidden()
                    HStack {
                        if item.dueDate != nil {
                            Button("Clear") { app.setActionItemDate(meetingID, item.id, nil); showPicker = false }
                        }
                        Spacer()
                        Button("Set") { app.setActionItemDate(meetingID, item.id, tempDate); showPicker = false }
                            .buttonStyle(.borderedProminent)
                    }
                }.padding().frame(width: 300)
            }

            Button { app.removeActionItem(meetingID, item.id) } label: {
                Image(systemName: "xmark").font(.system(size: 11, weight: .semibold))
            }.buttonStyle(.borderless).foregroundStyle(.secondary)
        }
    }
}

// MARK: - Files

struct FilesView: View {
    @EnvironmentObject var app: AppState
    @State private var targeted = false

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 24) {
                PageHeader(title: "Transcribe a file",
                           subtitle: "Drop an audio or video file — it's converted and transcribed locally.")

                ZStack {
                    RoundedRectangle(cornerRadius: Theme.panelRadius, style: .continuous)
                        .fill(targeted ? Theme.red.opacity(0.08) : Color.primary.opacity(0.03))
                        .overlay(
                            RoundedRectangle(cornerRadius: Theme.panelRadius, style: .continuous)
                                .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [7, 6]))
                                .foregroundStyle(targeted ? AnyShapeStyle(Theme.red)
                                                 : AnyShapeStyle(Color.primary.opacity(0.18)))
                        )
                    VStack(spacing: 12) {
                        Image(systemName: app.status == .transcribing ? "waveform" : "arrow.down.doc")
                            .font(.system(size: 34, weight: .light))
                            .foregroundStyle(Theme.gradient)
                        Text(app.status == .transcribing ? "Transcribing…" : "Drop audio or video here")
                            .font(.system(size: 17, weight: .medium))
                        Text("mp3 · m4a · wav · mov · mp4 · and more")
                            .font(.system(size: 12.5)).foregroundStyle(.secondary)
                        Button("Choose file…") { chooseFile() }
                            .buttonStyle(GradientButtonStyle())
                            .padding(.top, 4)
                            .disabled(app.status == .transcribing)
                    }
                    .padding(40)
                }
                .frame(height: 300)
                .onDrop(of: [.fileURL], isTargeted: $targeted) { providers in
                    handleDrop(providers)
                }

                HStack(spacing: 12) {
                    ChipMenu(icon: "cpu", label: "Model", value: app.currentModelName) {
                        ForEach(WhisperModels.available, id: \.path) { m in
                            Button {
                                Settings.shared.modelPath = m.path
                                app.refreshModelName()
                            } label: {
                                Label(WhisperModels.labelWithSize(forPath: m.path),
                                      systemImage: m.path == Settings.shared.modelPath ? "checkmark" : "")
                            }
                        }
                    }
                    ChipMenu(icon: "globe", label: "Language",
                             value: Languages.name(for: Settings.shared.language)) {
                        ForEach(Languages.all) { l in
                            Button {
                                Settings.shared.language = l.code
                                app.objectWillChange.send()
                            } label: {
                                Label(l.name, systemImage: l.code == Settings.shared.language ? "checkmark" : "")
                            }
                        }
                    }
                    Spacer()
                }

                if !app.fileTranscriptions.isEmpty {
                    Text("Your transcriptions").font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.secondary).tracking(0.3).textCase(.uppercase)
                        .padding(.top, 4)
                    ForEach(app.fileTranscriptions) { entry in
                        HistoryRow(entry: entry)
                    }
                }
            }
            .padding(EdgeInsets(top: 48, leading: 28, bottom: 28, trailing: 28))
        }
        .overlay(alignment: .bottom) { BannerView() }
    }

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.audio, .movie, .mpeg4Movie, .quickTimeMovie, .mp3, .wav]
        if panel.runModal() == .OK {
            app.transcribeFiles(panel.urls)
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        let group = DispatchGroup()
        var urls: [URL] = []
        let lock = NSLock()   // loadObject completions fire on concurrent queues
        for p in providers {
            group.enter()
            _ = p.loadObject(ofClass: URL.self) { url, _ in
                if let url { lock.lock(); urls.append(url); lock.unlock() }
                group.leave()
            }
        }
        group.notify(queue: .main) {
            let supported = urls.filter { AudioConverter.isSupported($0) }
            if supported.isEmpty {
                app.flash("Unsupported file type")
            } else {
                app.transcribeFiles(supported)
            }
        }
        return true
    }
}

// MARK: - History

struct HistoryView: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 20) {
                PageHeader(title: "History",
                           subtitle: "Everything you've done in Voz — dictations, transcriptions, and meetings — stored locally.")

                if app.allItems.isEmpty {
                    EmptyState(icon: "clock",
                               title: "Nothing yet",
                               subtitle: "Dictations, file transcriptions, and meetings will all appear here.")
                        .padding(.top, 40)
                } else {
                    ForEach(app.allItems) { entry in
                        HistoryRow(entry: entry, showKind: true)
                    }
                }
            }
            .padding(EdgeInsets(top: 48, leading: 28, bottom: 28, trailing: 28))
        }
        .overlay(alignment: .bottom) { BannerView() }
    }
}

struct HistoryRow: View {
    @EnvironmentObject var app: AppState
    let entry: HistoryEntry
    var showKind: Bool = false   // show a Dictation/Transcription/Meeting badge (History tab)
    @State private var hovering = false
    @State private var summarizing = false
    @State private var editing = false
    @State private var draft = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: entry.isMeeting ? "person.wave.2" : (entry.isFile ? "doc" : "mic"))
                    .font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.red)
                if showKind {
                    Text(entry.kind.uppercased()).font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(Theme.red))
                }
                Text(entry.isMeeting ? entry.displayTitle : entry.source)
                    .font(.system(size: 12.5, weight: .medium))
                Text("·").foregroundStyle(.secondary)
                Text(entry.date, format: .dateTime.month().day().hour().minute())
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                Spacer()
                Text(entry.model).font(.system(size: 11)).foregroundStyle(.secondary)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Capsule().fill(Color.primary.opacity(0.06)))
            }
            if editing {
                TextEditor(text: $draft)
                    .font(.system(size: 14.5))
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 90, maxHeight: 320)
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.05)))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.red.opacity(0.45), lineWidth: 1))
            } else {
                Text(entry.text).font(.system(size: 14.5)).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            // Your own notes (meetings).
            if let notes = entry.notes, !notes.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Label("My notes", systemImage: "pencil").font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Text(notes).font(.system(size: 13.5)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.05)))
            }

            // Local AI summary (if generated).
            if let summary = entry.summary {
                VStack(alignment: .leading, spacing: 5) {
                    Label("Summary", systemImage: "sparkles")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.red)
                    Text(summary).font(.system(size: 13.5)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 10).fill(Theme.red.opacity(0.06)))
            }

            HStack(spacing: 14) {
                if editing {
                    Button {
                        app.updateTranscript(draft, for: entry)
                        editing = false
                    } label: { Label("Save", systemImage: "checkmark").font(.system(size: 12.5)) }
                        .buttonStyle(.borderless).foregroundStyle(Theme.red)
                    Button { editing = false } label: {
                        Label("Cancel", systemImage: "xmark").font(.system(size: 12.5))
                    }.buttonStyle(.borderless).foregroundStyle(.secondary)
                    Spacer()
                } else {
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(entry.text, forType: .string)
                        app.flash("Copied")
                    } label: { Label("Copy", systemImage: "doc.on.doc").font(.system(size: 12.5)) }
                        .buttonStyle(.borderless)

                    Button { draft = entry.text; editing = true } label: {
                        Label("Edit", systemImage: "pencil").font(.system(size: 12.5))
                    }.buttonStyle(.borderless)

                // Summarize appears only when a local model is ready (meetings
                // are summarized in the Meetings tab).
                if LocalLLM.shared.isReady && entry.summary == nil && !entry.isMeeting {
                    Button(action: summarize) {
                        if summarizing {
                            HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Summarizing…") }
                                .font(.system(size: 12.5))
                        } else {
                            Label("Summarize", systemImage: "sparkles").font(.system(size: 12.5))
                        }
                    }
                    .buttonStyle(.borderless).disabled(summarizing)
                }

                    Button(role: .destructive) {
                        if entry.isMeeting { app.deleteMeeting(entry.id) } else { app.deleteHistory(entry) }
                    } label: {
                        Label("Delete", systemImage: "trash").font(.system(size: 12.5))
                    }.buttonStyle(.borderless).foregroundStyle(.secondary)
                }
            }
        }
        .padding(18)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(Color.primary.opacity(hovering ? 0.05 : 0.035)))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
            .stroke(Color.primary.opacity(0.06), lineWidth: 1))
        .onHover { hovering = $0 }
    }

    private func summarize() {
        summarizing = true
        app.flash("Summarizing locally…")
        LocalLLM.shared.summarize(entry.text) { result in
            summarizing = false
            switch result {
            case .success(let summary): app.setSummary(summary, for: entry.id)
            case .failure(let error): app.flash(error.localizedDescription)
            }
        }
    }
}

struct EmptyState: View {
    let icon: String; let title: String; let subtitle: String
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: icon).font(.system(size: 36, weight: .light)).foregroundStyle(.secondary)
            Text(title).font(.system(size: 17, weight: .medium))
            Text(subtitle).font(.system(size: 13.5)).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Settings

struct SettingsView: View {
    @EnvironmentObject var app: AppState
    @ObservedObject private var modelStore = ModelStore.shared
    @ObservedObject private var updater = Updater.shared

    // Bind directly to the Settings singleton.
    private var modelPath: Binding<String> {
        Binding(get: { Settings.shared.modelPath },
                set: { Settings.shared.modelPath = $0; app.refreshModelName() })
    }
    private var language: Binding<String> {
        Binding(get: { Settings.shared.language }, set: { Settings.shared.language = $0 })
    }
    private var vocabulary: Binding<String> {
        Binding(get: { Settings.shared.customVocabulary }, set: { Settings.shared.customVocabulary = $0 })
    }
    private var playSounds: Binding<Bool> {
        Binding(get: { Settings.shared.playSounds }, set: { Settings.shared.playSounds = $0 })
    }
    private var showVoiceBar: Binding<Bool> {
        Binding(get: { Settings.shared.showVoiceBar }, set: { Settings.shared.showVoiceBar = $0 })
    }
    private var voiceBarAnchor: Binding<Int> {
        Binding(get: { Settings.shared.voiceBarAnchor },
                set: { Settings.shared.voiceBarAnchor = $0; VoiceBarController.shared.previewPosition() })
    }
    private var dockIconVisible: Binding<Bool> {
        Binding(get: { Settings.shared.dockIconVisible },
                set: { Settings.shared.dockIconVisible = $0; app.onUpdateActivationPolicy?() })
    }

    // Trigger mode (Hotkey vs Fn double-tap)
    private var triggerModeIsHotkey: Binding<Bool> {
        Binding(get: { Settings.shared.triggerMode == .hotKey },
                set: { Settings.shared.triggerMode = $0 ? .hotKey : .fnDoubleTap; app.reloadHotkey() })
    }
    private var startSound: Binding<String> {
        Binding(get: { Settings.shared.startSound },
                set: { Settings.shared.startSound = $0; Sound.preview($0) })
    }
    private var stopSound: Binding<String> {
        Binding(get: { Settings.shared.stopSound },
                set: { Settings.shared.stopSound = $0; Sound.preview($0) })
    }

    @State private var showAdvanced = false
    // Bumped when the app regains focus (e.g. returning from System Settings) so
    // the permission statuses below re-read themselves.
    @State private var permissionsRefresh = 0

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                PageHeader(title: "Settings", subtitle: "Everything runs locally. Nothing leaves your Mac.")

                Panel(title: "Permissions") {
                    Text("macOS asks you to approve these once. If dictation or meetings aren't working, check here.")
                        .font(.system(size: 12.5)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    PermissionRow(name: "Accessibility",
                                  detail: "Lets Voz paste text and cancel with Esc.",
                                  granted: SystemPermissions.accessibilityGranted,
                                  open: SystemPermissions.openAccessibility)
                    Divider()
                    PermissionRow(name: "Microphone",
                                  detail: "Needed for dictation and meetings.",
                                  granted: SystemPermissions.microphoneGranted,
                                  open: SystemPermissions.openMicrophone)
                    Divider()
                    PermissionRow(name: "Screen Recording",
                                  detail: "Meetings only — captures the other side of a call. "
                                        + "Audio only; Voz never records your screen. "
                                        + "Needs a relaunch after you allow it.",
                                  granted: SystemPermissions.screenRecordingGranted,
                                  open: SystemPermissions.openScreenRecording)
                }
                .id(permissionsRefresh)

                Panel(title: "Transcription") {
                    SettingRow(label: "Model",
                               help: WhisperModels.tier(forPath: Settings.shared.modelPath).recommendation) {
                        Picker("", selection: modelPath) {
                            ForEach(WhisperModels.available, id: \.path) { m in
                                Text(WhisperModels.labelWithSize(forPath: m.path)).tag(m.path)
                            }
                        }.labelsHidden().frame(width: 240)
                    }
                    Divider()
                    SettingRow(label: "Language", help: "Auto-detect needs a multilingual model.") {
                        Picker("", selection: language) {
                            ForEach(Languages.all) { l in Text(l.name).tag(l.code) }
                        }.labelsHidden().frame(width: 220)
                    }
                }

                Panel(title: "Custom vocabulary") {
                    Text("Add names, brands, or technical terms Voz might not know. Each one you add makes Voz more likely to spell it right.")
                        .font(.system(size: 12.5)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    VocabularyInput(text: vocabulary)
                }

                Panel(title: "Dictation shortcut") {
                    SettingRow(label: "Start & stop dictation with",
                               help: "How you turn dictation on and off from anywhere.") {
                        Picker("", selection: triggerModeIsHotkey) {
                            Text("A key combo").tag(true)
                            Text("Double-tap Fn").tag(false)
                        }.labelsHidden().pickerStyle(.segmented).frame(width: 240)
                    }
                    if Settings.shared.triggerMode == .hotKey {
                        Divider()
                        SettingRow(label: "Key combo",
                                   help: "Click the box, then press the keys you want (e.g. ⌥Space).") {
                            ShortcutRecorder { app.reloadHotkey() }.frame(width: 220, height: 28)
                        }
                    } else {
                        Text("Quickly press the Fn (globe) key twice to start or stop. Needs Input Monitoring permission the first time.")
                            .font(.system(size: 11.5)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Panel(title: "Menu bar") {
                    SettingRow(label: "Show Dock icon",
                               help: "Turn off to run Voz from the menu bar only. The menu-bar icon and your dictation hotkey keep working either way.") {
                        Toggle("", isOn: dockIconVisible).labelsHidden().toggleStyle(.switch)
                    }
                }

                Panel(title: "Voice bar") {
                    SettingRow(label: "Show live waveform while dictating",
                               help: "A small floating bar that ripples with your voice while you dictate.") {
                        Toggle("", isOn: showVoiceBar).labelsHidden().toggleStyle(.switch)
                    }
                    Divider()
                    SettingRow(label: "Position",
                               help: "Where it appears by default. You can also drag it anywhere while dictating.") {
                        Picker("", selection: voiceBarAnchor) {
                            Text("Bottom center").tag(0)
                            Text("Bottom left").tag(1)
                            Text("Bottom right").tag(2)
                            Text("Top center").tag(3)
                            Text("Top left").tag(4)
                            Text("Top right").tag(5)
                            Text("Custom (dragged)").tag(6)
                        }.labelsHidden().frame(width: 180)
                    }
                }

                Panel(title: "Sounds") {
                    SettingRow(label: "Play start/stop sounds", help: nil) {
                        Toggle("", isOn: playSounds).labelsHidden().toggleStyle(.switch)
                    }
                    Divider()
                    SettingRow(label: "Start sound", help: nil) {
                        SoundPicker(selection: startSound)
                    }
                    Divider()
                    SettingRow(label: "Stop sound", help: nil) {
                        SoundPicker(selection: stopSound)
                    }
                }

                // The open-source build has no updater at all -- see Updater.swift.
                // The paid build checks a signed feed once a day; this one checks
                // nothing, ever, which makes it the only version of Voz that can
                // truthfully claim zero network requests.
                Panel(title: "Updates") {
                    Text("This is a source build, so it does not update itself. Pull the latest code and build again:")
                        .font(.system(size: 12.5)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("git pull && open Voz.xcodeproj")
                        .font(.system(size: 12, design: .monospaced))
                        .textSelection(.enabled)
                    Divider()
                    SettingRow(label: "Current version",
                               help: "Built from source on this Mac. The signed, self-updating build is the one sold at vozwhisper.com.") {
                        HStack(spacing: 10) {
                            Text(updater.currentVersion)
                                .font(.system(size: 12.5, design: .monospaced))
                                .foregroundStyle(.secondary)
                            Button("View on GitHub") { updater.checkForUpdates(nil) }
                                .disabled(!updater.canCheckForUpdates)
                        }
                    }
                }

                Panel(title: "Meeting summaries & follow-ups") {
                    Text("Pick a model to auto-generate meeting follow-ups and summaries on your Mac. Optional — nothing here ships with the app, and nothing ever leaves your device. Download the size that fits your Mac.")
                        .font(.system(size: 12.5)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    if !LocalLLM.shared.binaryAvailable {
                        Label("llama.cpp not found — build it at ~/llama.cpp to enable this (see README).",
                              systemImage: "exclamationmark.triangle")
                            .font(.system(size: 11.5)).foregroundStyle(.orange)
                    }

                    ForEach(LLMCatalog.models) { model in
                        Divider()
                        ModelRow(model: model)
                    }
                }

                DisclosureGroup(isExpanded: $showAdvanced) {
                    VStack(alignment: .leading, spacing: 14) {
                        PathField(label: "whisper.cpp binary", path: binaryPath,
                                  placeholder: "Bundled — override only if needed")
                        PathField(label: "llama.cpp binary (for AI summaries)", path: llamaPath,
                                  placeholder: "~/llama.cpp/build/bin/llama-cli")
                        Text("Only change these if your tools live somewhere non-standard.")
                            .font(.system(size: 11.5)).foregroundStyle(.secondary)
                    }
                    .padding(.top, 10)
                } label: {
                    Text("Advanced").font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.secondary).tracking(0.3).textCase(.uppercase)
                }
                .padding(20)
                .background(RoundedRectangle(cornerRadius: Theme.panelRadius, style: .continuous)
                    .fill(Color.primary.opacity(0.035)))
                .overlay(RoundedRectangle(cornerRadius: Theme.panelRadius, style: .continuous)
                    .stroke(Color.primary.opacity(0.06), lineWidth: 1))
            }
            .padding(EdgeInsets(top: 48, leading: 28, bottom: 28, trailing: 28))
        }
        .overlay(alignment: .bottom) { BannerView() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            permissionsRefresh += 1
        }
    }

    private var binaryPath: Binding<String> {
        Binding(get: { Settings.shared.binaryPath }, set: { Settings.shared.binaryPath = $0 })
    }
    private var llamaPath: Binding<String> {
        Binding(get: { Settings.shared.llamaBinaryPath }, set: { Settings.shared.llamaBinaryPath = $0 })
    }
}

/// One privacy-permission row: name, why it's needed, a green/orange status, and
/// a button that jumps to the exact System Settings pane.
struct PermissionRow: View {
    let name: String
    let detail: String
    let granted: Bool
    let open: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(.system(size: 13, weight: .medium))
                Text(detail).font(.system(size: 11.5)).foregroundStyle(.secondary)
            }
            Spacer()
            HStack(spacing: 6) {
                Circle().fill(granted ? Color.green : Color.orange).frame(width: 8, height: 8)
                Text(granted ? "Granted" : "Not granted")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(granted ? Color.green : Color.orange)
            }
            Button(granted ? "Review" : "Open Settings", action: open)
                .buttonStyle(.borderless)
                .font(.system(size: 12))
                .foregroundStyle(Theme.red)
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Local model row

struct ModelRow: View {
    @ObservedObject private var store = ModelStore.shared
    let model: LLMModel

    private var state: ModelStore.DownloadState { store.states[model.id] ?? .notDownloaded }
    private var isActive: Bool { store.activeModel()?.id == model.id }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 7) {
                    Text(model.name).font(.system(size: 14, weight: .medium))
                    if isActive {
                        Text("ACTIVE").font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Capsule().fill(Theme.gradient))
                    }
                }
                Text("\(model.params) · \(model.sizeText) · \(model.ramHint)")
                    .font(.system(size: 11.5)).foregroundStyle(.secondary)
                if case .failed(let msg) = state {
                    Text(msg).font(.system(size: 11)).foregroundStyle(.red).lineLimit(2)
                }
            }
            Spacer()
            control
        }
    }

    @ViewBuilder private var control: some View {
        switch state {
        case .notDownloaded, .failed:
            Button("Download") { store.download(model) }.buttonStyle(.bordered)
        case .downloading(let p):
            HStack(spacing: 8) {
                ProgressView(value: p).frame(width: 90)
                Text("\(Int(p * 100))%").font(.system(size: 11)).monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        case .downloaded:
            HStack(spacing: 10) {
                if !isActive {
                    Button("Use") { store.setActive(model) }.buttonStyle(.borderless)
                }
                Button(role: .destructive) { store.delete(model) } label: {
                    Image(systemName: "trash")
                }.buttonStyle(.borderless).foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Settings components

/// Chip-based vocabulary input: type a word, press return, it becomes a
/// removable pill. Much friendlier than a comma-separated blob. Persists to
/// Settings.customVocabulary as a comma-separated string (what whisper wants).
struct VocabularyInput: View {
    @Binding var text: String
    @State private var draft: String = ""

    private var words: [String] {
        text.split(whereSeparator: { $0 == "," || $0 == "\n" })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    private func commit() {
        let w = draft.trimmingCharacters(in: .whitespaces)
        guard !w.isEmpty else { return }
        var list = words
        if !list.contains(where: { $0.caseInsensitiveCompare(w) == .orderedSame }) {
            list.append(w)
            text = list.joined(separator: ", ")
        }
        draft = ""
    }

    private func remove(_ word: String) {
        text = words.filter { $0 != word }.joined(separator: ", ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                TextField("Type a word or name, then press Return", text: $draft)
                    .textFieldStyle(.plain)
                    .onSubmit(commit)
                    .padding(.horizontal, 12).padding(.vertical, 9)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.05)))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.1)))
                Button(action: commit) {
                    Image(systemName: "plus").font(.system(size: 13, weight: .bold))
                }
                .buttonStyle(GradientButtonStyle())
                .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
            }

            if words.isEmpty {
                Text("No custom words yet.").font(.system(size: 12)).foregroundStyle(.secondary)
            } else {
                FlowLayout(spacing: 8) {
                    ForEach(words, id: \.self) { word in
                        HStack(spacing: 6) {
                            Text(word).font(.system(size: 12.5, weight: .medium))
                            Button { remove(word) } label: {
                                Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
                            }.buttonStyle(.plain).foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 11).padding(.vertical, 6)
                        .background(Capsule().fill(LinearGradient(
                            colors: [Theme.red.opacity(0.14), Theme.red.opacity(0.13), Theme.blue.opacity(0.13)],
                            startPoint: .leading, endPoint: .trailing)))
                        .overlay(Capsule().stroke(Theme.red.opacity(0.22), lineWidth: 1))
                    }
                }
            }
        }
    }
}

struct SoundPicker: View {
    @Binding var selection: String
    var body: some View {
        HStack(spacing: 8) {
            Picker("", selection: $selection) {
                ForEach(Sound.available, id: \.self) { Text($0).tag($0) }
            }.labelsHidden().frame(width: 150)
            Button {
                Sound.preview(selection)
            } label: { Image(systemName: "play.circle") }
                .buttonStyle(.borderless)
        }
    }
}

/// A read/edit text field for a tool path with a Browse… button.
struct PathField: View {
    let label: String
    @Binding var path: String
    let placeholder: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.system(size: 13, weight: .medium))
            HStack(spacing: 8) {
                TextField(placeholder, text: $path)
                    .textFieldStyle(.plain).font(.system(size: 12, design: .monospaced))
                    .padding(.horizontal, 10).padding(.vertical, 7)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.primary.opacity(0.1)))
                Button("Browse…") {
                    let panel = NSOpenPanel()
                    panel.canChooseFiles = true
                    panel.showsHiddenFiles = true
                    if panel.runModal() == .OK, let url = panel.url { path = url.path }
                }.buttonStyle(.bordered)
            }
        }
    }
}

/// NSViewRepresentable wrapper around the AppKit KeyRecorderControl so the
/// shortcut recorder lives inline in the SwiftUI settings.
struct ShortcutRecorder: NSViewRepresentable {
    var onChange: () -> Void

    func makeNSView(context: Context) -> KeyRecorderControl {
        let c = KeyRecorderControl()
        c.hotKey = Settings.shared.hotKey
        c.onCapture = { hk in
            Settings.shared.hotKey = hk
            onChange()
        }
        return c
    }
    func updateNSView(_ nsView: KeyRecorderControl, context: Context) {
        nsView.hotKey = Settings.shared.hotKey
    }
}

/// A minimal flow layout so vocabulary chips wrap to multiple lines.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for sub in subviews {
            let s = sub.sizeThatFits(.unspecified)
            if x + s.width > maxWidth, x > 0 {
                x = 0; y += rowHeight + spacing; rowHeight = 0
            }
            x += s.width + spacing
            rowHeight = max(rowHeight, s.height)
        }
        return CGSize(width: maxWidth == .infinity ? x : maxWidth, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for sub in subviews {
            let s = sub.sizeThatFits(.unspecified)
            if x + s.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX; y += rowHeight + spacing; rowHeight = 0
            }
            sub.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(s))
            x += s.width + spacing
            rowHeight = max(rowHeight, s.height)
        }
    }
}

struct SettingRow<Trailing: View>: View {
    let label: String
    var help: String?
    @ViewBuilder var trailing: Trailing
    var body: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text(label).font(.system(size: 14, weight: .medium))
                if let help { Text(help).font(.system(size: 11.5)).foregroundStyle(.secondary) }
            }
            Spacer()
            trailing
        }
    }
}

// MARK: - Gradient button + banner

struct GradientButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13.5, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 18).padding(.vertical, 9)
            .background(Capsule().fill(Theme.gradient))
            .opacity(configuration.isPressed ? 0.8 : 1)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
    }
}

/// A small transient toast, driven by AppState.banner.
struct BannerView: View {
    @EnvironmentObject var app: AppState
    var body: some View {
        Group {
            if let msg = app.banner {
                Text(msg)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .background(Capsule().fill(Color.black.opacity(0.82)))
                    .padding(.bottom, 20)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .onAppear {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
                            withAnimation { app.banner = nil }
                        }
                    }
            }
        }
        .animation(.easeInOut(duration: 0.25), value: app.banner)
    }
}
