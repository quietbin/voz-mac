//
//  VoiceBar.swift
//  Voz
//
//  A small floating "voice memo" waveform HUD that appears near the bottom of
//  the screen while you're dictating and ripples with your voice. It never
//  steals focus. Drag it anywhere to move it (that spot is remembered); tap the
//  × or press Esc to cancel dictation. Toggle it and set its default position in
//  Settings → Voice bar. Driven by AudioRecorder's live mic level.
//

import AppKit
import SwiftUI

/// Where the voice bar sits. Presets are relative to the active screen; `.custom`
/// is a remembered spot the user dragged it to.
enum VoiceBarAnchor: Int, CaseIterable {
    case bottomCenter = 0, bottomLeft, bottomRight, topCenter, topLeft, topRight, custom
}

// MARK: - Level model

/// Holds a scrolling ring of recent mic levels (newest on the right), plus a
/// little smoothing so the bars rise/fall naturally instead of flickering.
final class VoiceBarModel: ObservableObject {
    static let barCount = 16
    @Published var levels: [CGFloat] = Array(repeating: 0, count: VoiceBarModel.barCount)
    private var smoothed: CGFloat = 0

    func reset() {
        smoothed = 0
        levels = Array(repeating: 0, count: Self.barCount)
    }

    /// Feed a fresh 0…1 level; scroll it in from the right.
    func push(_ raw: CGFloat) {
        // Attack fast, release a touch slower — reads like a real level meter.
        let target = max(0, min(1, raw))
        smoothed += (target - smoothed) * (target > smoothed ? 0.7 : 0.3)
        var next = levels
        next.removeFirst()
        next.append(smoothed)
        levels = next
    }
}

// MARK: - Waveform view

/// A transparent AppKit layer that drags the whole panel natively (smooth, no
/// SwiftUI feedback loop). Sits behind the non-interactive waveform.
struct WindowDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ nsView: NSView, context: Context) {}
    final class DragView: NSView {
        override var mouseDownCanMoveWindow: Bool { true }
        override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
    }
}

struct VoiceBarView: View {
    @ObservedObject var model: VoiceBarModel
    var onClose: () -> Void = {}

    var body: some View {
        ZStack {
            WindowDragArea()                     // drag anywhere on the pill
            HStack(spacing: 7) {
                bars
                    .frame(maxWidth: .infinity)
                    .allowsHitTesting(false)     // let drags fall through to the layer
                closeButton
            }
            .padding(.leading, 12)
            .padding(.trailing, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(pill)
        .animation(.linear(duration: 0.06), value: model.levels)
    }

    private var bars: some View {
        HStack(spacing: 2.5) {
            ForEach(Array(model.levels.enumerated()), id: \.offset) { _, level in
                Capsule(style: .continuous)
                    .fill(Theme.gradient)
                    .frame(width: 2.5, height: barHeight(level))
                    .opacity(0.5 + 0.5 * level)
            }
        }
    }

    private var closeButton: some View {
        Button(action: onClose) {
            Image(systemName: "xmark")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(.white.opacity(0.7))
                .frame(width: 15, height: 15)
                .background(Circle().fill(.white.opacity(0.14)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help("Cancel dictation")
    }

    private var pill: some View {
        RoundedRectangle(cornerRadius: 15, style: .continuous)
            .fill(.black.opacity(0.82))
            .overlay(
                RoundedRectangle(cornerRadius: 15, style: .continuous)
                    .stroke(.white.opacity(0.10), lineWidth: 1)
            )
    }

    /// Bars grow symmetrically from the centre. A gamma curve (<1) lifts quieter
    /// speech so the movement reads clearly; small idle dot when silent.
    private func barHeight(_ level: CGFloat) -> CGFloat {
        let minH: CGFloat = 2.5, maxH: CGFloat = 18
        let shaped = pow(min(1, level * 1.15), 0.6)
        return minH + (maxH - minH) * shaped
    }
}

// MARK: - Floating panel controller

/// Owns the borderless HUD panel and a ~30 fps timer that samples the mic level.
/// All entry points are called on the main thread (recording start/stop).
final class VoiceBarController: NSObject, NSWindowDelegate {
    static let shared = VoiceBarController()

    private var panel: NSPanel?
    private let model = VoiceBarModel()
    private var timer: Timer?
    private var level: (() -> Float)?
    private var onClose: (() -> Void)?
    private let panelSize = NSSize(width: 128, height: 30)
    private var isPositioning = false   // ignore windowDidMove during programmatic moves
    private var previewTimer: Timer?
    private var previewHide: DispatchWorkItem?

    private override init() { super.init() }

    /// Show the HUD, start reading `level` (0…1) every frame, and call `onClose`
    /// if the user taps the ×. No-op if the voice bar is turned off in Settings.
    func show(level: @escaping () -> Float, onClose: @escaping () -> Void) {
        guard Settings.shared.showVoiceBar else { return }
        previewTimer?.invalidate(); previewTimer = nil   // cancel any settings preview
        previewHide?.cancel()
        self.level = level
        self.onClose = onClose
        if panel == nil { buildPanel() }
        model.reset()
        position()
        guard let panel else { return }
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            panel.animator().alphaValue = 1
        }
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.model.push(CGFloat(self.level?() ?? 0))
        }
    }

    /// Fade out and hide.
    func hide() {
        timer?.invalidate(); timer = nil
        guard let panel else { return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.18
            panel.animator().alphaValue = 0
        }, completionHandler: {
            panel.orderOut(nil)
        })
    }

    private func buildPanel() {
        let p = NSPanel(contentRect: NSRect(origin: .zero, size: panelSize),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.isFloatingPanel = true
        p.becomesKeyOnlyIfNeeded = true
        p.level = .statusBar
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = true
        p.ignoresMouseEvents = false   // so the × is clickable and it can be dragged
        p.hidesOnDeactivate = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        p.delegate = self
        let host = NSHostingView(rootView: VoiceBarView(
            model: model,
            onClose: { [weak self] in self?.onClose?() }))
        host.frame = NSRect(origin: .zero, size: panelSize)
        host.autoresizingMask = [.width, .height]
        p.contentView = host
        panel = p
    }

    /// The user dragged it — remember the new spot as the custom position.
    func windowDidMove(_ notification: Notification) {
        guard !isPositioning, let panel else { return }
        let o = panel.frame.origin
        Settings.shared.voiceBarCustomX = Double(o.x)
        Settings.shared.voiceBarCustomY = Double(o.y)
        Settings.shared.voiceBarAnchor = VoiceBarAnchor.custom.rawValue
    }

    /// Called when the user changes the Position in Settings. If a dictation bar
    /// is live, just move it; otherwise flash a brief preview at the new spot so
    /// the change is visible immediately.
    func previewPosition() {
        guard Settings.shared.showVoiceBar else { return }
        if timer != nil { position(); return }   // a real dictation is showing
        if panel == nil { buildPanel() }
        position()
        guard let panel else { return }
        model.reset()
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { c in c.duration = 0.15; panel.animator().alphaValue = 1 }
        // Gentle demo motion so it reads as the voice bar, not a static blob.
        previewTimer?.invalidate()
        var t: Double = 0
        previewTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            t += 1.0 / 30.0
            self?.model.push(CGFloat(0.35 + 0.35 * sin(t * 7)))
        }
        previewHide?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.endPreview() }
        previewHide = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6, execute: work)
    }

    private func endPreview() {
        previewTimer?.invalidate(); previewTimer = nil
        if timer == nil { hide() }   // don't hide if a real dictation started meanwhile
    }

    /// Places the panel per the saved anchor (or custom spot), clamped on-screen.
    private func position() {
        guard let panel else { return }
        let screen = NSScreen.main ?? NSScreen.screens.first
        guard let vf = screen?.visibleFrame else { return }
        let s = panelSize
        let m: CGFloat = 22          // edge margin
        let bottom = vf.minY + 84    // clears the Dock
        let top = vf.maxY - s.height - 12
        let anchor = VoiceBarAnchor(rawValue: Settings.shared.voiceBarAnchor) ?? .bottomCenter

        var origin: NSPoint
        switch anchor {
        case .custom:
            origin = NSPoint(x: CGFloat(Settings.shared.voiceBarCustomX),
                             y: CGFloat(Settings.shared.voiceBarCustomY))
        case .bottomCenter: origin = NSPoint(x: vf.midX - s.width / 2, y: bottom)
        case .bottomLeft:   origin = NSPoint(x: vf.minX + m, y: bottom)
        case .bottomRight:  origin = NSPoint(x: vf.maxX - s.width - m, y: bottom)
        case .topCenter:    origin = NSPoint(x: vf.midX - s.width / 2, y: top)
        case .topLeft:      origin = NSPoint(x: vf.minX + m, y: top)
        case .topRight:     origin = NSPoint(x: vf.maxX - s.width - m, y: top)
        }
        // Keep it fully on the active screen even if it was saved on another one.
        origin.x = min(max(vf.minX, origin.x), vf.maxX - s.width)
        origin.y = min(max(vf.minY, origin.y), vf.maxY - s.height)
        isPositioning = true
        panel.setFrameOrigin(origin)
        DispatchQueue.main.async { self.isPositioning = false }
    }
}
