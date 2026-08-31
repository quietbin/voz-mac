//
//  Sound.swift
//  Voz
//
//  Subtle start/stop cues using built-in macOS system sounds. The specific
//  sounds are chosen in Preferences (Start sound / Stop sound). The master
//  "Play sounds" toggle turns them off entirely.
//

import AppKit

enum Sound {
    enum Cue { case start, stop }

    /// All built-in macOS sound names (from /System/Library/Sounds), sorted.
    static var available: [String] {
        let dir = "/System/Library/Sounds"
        let files = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
        return files
            .filter { $0.hasSuffix(".aiff") }
            .map { ($0 as NSString).deletingPathExtension }
            .sorted()
    }

    /// Plays the configured sound for a start/stop cue (respects the master toggle).
    static func play(_ cue: Cue) {
        guard Settings.shared.playSounds else { return }
        let name = (cue == .start) ? Settings.shared.startSound : Settings.shared.stopSound
        preview(name)
    }

    /// Keeps the currently-playing sound alive; a released NSSound can cut out.
    private static var current: NSSound?

    /// Plays a named sound immediately, ignoring the master toggle (for previews).
    static func preview(_ name: String) {
        let sound = NSSound(named: NSSound.Name(name))
        current = sound
        sound?.play()
    }
}
