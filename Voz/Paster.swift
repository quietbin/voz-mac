//
//  Paster.swift
//  Voz
//
//  Inserts text at the current cursor location by copying it to the pasteboard
//  and synthesising a ⌘V keystroke with CGEvent.
//
//  NOTE: Posting keystrokes into *other* apps requires Accessibility permission
//  (System Settings → Privacy & Security → Accessibility). Voz prompts for this
//  on first use. Without it, the copy still happens but ⌘V won't be delivered.
//

import AppKit
import ApplicationServices
import AVFoundation
import CoreGraphics

/// Reads the macOS privacy permissions Voz depends on, and deep-links to the
/// right System Settings pane so the user can grant them. All local, read-only.
enum SystemPermissions {

    /// Accessibility — needed to paste (⌘V) into other apps and for Esc-to-cancel.
    static var accessibilityGranted: Bool { AXIsProcessTrusted() }

    /// Microphone — needed for dictation and meetings.
    static var microphoneGranted: Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    /// Screen Recording — needed to capture call/system audio in meetings.
    ///
    /// The name is macOS's, not ours. Voz never records the screen: the meeting
    /// capture asks ScreenCaptureKit for a 2×2-pixel video stream purely because
    /// SCStream requires one, throws every frame away, and keeps only the audio.
    /// But macOS files system-audio capture under Screen Recording, so this is
    /// the switch the user has to find.
    static var screenRecordingGranted: Bool { CGPreflightScreenCaptureAccess() }

    /// Shows the system Screen Recording prompt if it has never been answered.
    ///
    /// Returns true only when access is *already* granted. On a first ask macOS
    /// displays the prompt and returns false immediately -- and even after the
    /// user approves, the capture APIs keep failing until the app is relaunched.
    /// Callers must treat false as "tell them to approve and restart", not as a
    /// refusal.
    @discardableResult
    static func requestScreenRecording() -> Bool { CGRequestScreenCaptureAccess() }

    static func openAccessibility() { open("Privacy_Accessibility") }
    static func openMicrophone() { open("Privacy_Microphone") }
    static func openScreenRecording() { open("Privacy_ScreenCapture") }

    private static func open(_ anchor: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
            NSWorkspace.shared.open(url)
        }
    }
}

enum Paster {

    /// True if Voz currently has Accessibility (AXIsProcessTrusted) permission.
    static var hasAccessibilityPermission: Bool { AXIsProcessTrusted() }

    /// Prompts the user (system dialog) to grant Accessibility permission.
    static func promptForAccessibilityPermission() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
    }

    /// Copies `text` to the clipboard (no keystroke).
    static func copyToClipboard(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }

    /// Copies `text` to the clipboard, then simulates ⌘V.
    static func paste(_ text: String) {
        VozLog.log("paste called len=\(text.count) accessibilityTrusted=\(hasAccessibilityPermission)")
        copyToClipboard(text)
        // Small delay lets the pasteboard settle and the target app regain focus.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            simulateCmdV()
        }
    }

    private static func simulateCmdV() {
        let src = CGEventSource(stateID: .combinedSessionState)
        let vKey: CGKeyCode = 0x09 // 'v'

        let keyDown = CGEvent(keyboardEventSource: src, virtualKey: vKey, keyDown: true)
        keyDown?.flags = .maskCommand
        let keyUp = CGEvent(keyboardEventSource: src, virtualKey: vKey, keyDown: false)
        keyUp?.flags = .maskCommand

        let loc = CGEventTapLocation.cghidEventTap
        keyDown?.post(tap: loc)
        keyUp?.post(tap: loc)
    }
}
