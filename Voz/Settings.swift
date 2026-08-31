//
//  Settings.swift
//  Voz
//
//  All user-configurable options, persisted in UserDefaults.
//
//  ───────────────────────────────────────────────────────────────────────────
//  QUICK CUSTOMISATION GUIDE
//  ───────────────────────────────────────────────────────────────────────────
//  • Change the whisper.cpp binary path:  edit `defaultBinaryCandidates` below,
//    or set it at runtime from Preferences → "whisper.cpp binary".
//  • Change the model (base.en → small.en, etc.): edit `defaultModelCandidates`,
//    or set it from Preferences → "Model (.bin)". Bigger models = more accurate
//    but slower. Download them with:
//        cd ~/whisper.cpp && sh ./models/download-ggml-model.sh small.en
//  • Change the default hotkey: edit `HotKey.defaultHotKey` in HotKeyManager.swift
//    (or just record a new one in Preferences).
//  ───────────────────────────────────────────────────────────────────────────
//

import Foundation

enum TriggerMode: Int {
    case hotKey = 0        // Carbon global hotkey, e.g. Option+Space (no special permission)
    case fnDoubleTap = 1   // Double-tap the Fn key (needs Input Monitoring permission)
}

final class Settings {
    static let shared = Settings()
    private let d = UserDefaults.standard

    private enum Keys {
        static let keyCode = "voz.hotkey.keyCode"
        static let modifiers = "voz.hotkey.modifiers"
        static let triggerMode = "voz.triggerMode"
        static let binaryPath = "voz.whisper.binaryPath"
        static let modelPath = "voz.whisper.modelPath"
        static let playSounds = "voz.playSounds"
        static let showVoiceBar = "voz.showVoiceBar"
        static let dockIconVisible = "voz.dockIconVisible"
        static let voiceBarAnchor = "voz.voiceBar.anchor"
        static let voiceBarCustomX = "voz.voiceBar.customX"
        static let voiceBarCustomY = "voz.voiceBar.customY"
        static let startSound = "voz.sound.start"
        static let stopSound = "voz.sound.stop"
        static let language = "voz.whisper.language"
        static let customVocabulary = "voz.whisper.vocabulary"
        static let llamaBinaryPath = "voz.llama.binaryPath"
        static let selectedLLMModel = "voz.llama.selectedModel"
        static let meetingModelPath = "voz.whisper.meetingModel"
        static let meetingSpeakerCount = "voz.meeting.speakerCount"
    }

    private init() {
        // Register sensible defaults (only used until the user overrides them).
        d.register(defaults: [
            Keys.keyCode: Int(HotKey.defaultHotKey.keyCode),
            Keys.modifiers: Int(HotKey.defaultHotKey.carbonModifiers),
            Keys.triggerMode: TriggerMode.hotKey.rawValue,
            Keys.playSounds: true,
            Keys.showVoiceBar: true,
            Keys.dockIconVisible: true,
            Keys.startSound: "Tink",
            Keys.stopSound: "Tink",
            // "auto" = let Whisper detect the spoken language (needs a
            // multilingual model like small/large — the default). Still 100% local.
            Keys.language: "auto",
        ])
    }

    // MARK: - Hotkey

    var hotKey: HotKey {
        get {
            HotKey(keyCode: UInt32(d.integer(forKey: Keys.keyCode)),
                   carbonModifiers: UInt32(d.integer(forKey: Keys.modifiers)))
        }
        set {
            d.set(Int(newValue.keyCode), forKey: Keys.keyCode)
            d.set(Int(newValue.carbonModifiers), forKey: Keys.modifiers)
        }
    }

    var triggerMode: TriggerMode {
        get { TriggerMode(rawValue: d.integer(forKey: Keys.triggerMode)) ?? .hotKey }
        set { d.set(newValue.rawValue, forKey: Keys.triggerMode) }
    }

    // MARK: - whisper.cpp

    /// Candidate binary locations, tried in order. whisper.cpp historically
    /// shipped `main`; newer builds ship `build/bin/whisper-cli`. We check both.
    /// Edit / reorder these if your install lives elsewhere.
    static var defaultBinaryCandidates: [String] {
        let home = NSHomeDirectory()
        return [
            "\(home)/whisper.cpp/build/bin/whisper-cli",
            "\(home)/whisper.cpp/main",
            "\(home)/whisper.cpp/build/bin/main",
            "/opt/homebrew/bin/whisper-cli",
            "/usr/local/bin/whisper-cli",
        ]
    }

    static var defaultModelCandidates: [String] {
        let home = NSHomeDirectory()
        // small (multilingual) is the default: fast + accurate + handles any
        // language. Falls back to base/large if small isn't downloaded.
        return [
            "\(home)/whisper.cpp/models/ggml-small.bin",
            "\(home)/whisper.cpp/models/ggml-base.en.bin",
            "\(home)/whisper.cpp/models/ggml-large-v3-turbo.bin",
        ]
    }

    // MARK: - Bundled engine (shipped inside the app so it works out of the box)

    /// whisper-cli bundled in the app at Resources/engine-whisper/whisper-cli.
    static var bundledWhisperBinary: String? {
        Bundle.main.resourcePath.map { $0 + "/engine-whisper/whisper-cli" }
    }
    /// llama-cli bundled in the app at Resources/engine-llama/llama-cli.
    static var bundledLlamaBinary: String? {
        Bundle.main.resourcePath.map { $0 + "/engine-llama/llama-cli" }
    }
    /// Default multilingual Whisper model shipped inside the app.
    static var bundledModel: String? {
        Bundle.main.path(forResource: "ggml-base", ofType: "bin")
    }

    /// Resolved binary path — user override, else the bundled engine, else a
    /// locally-built whisper.cpp (dev machines), else the first candidate.
    var binaryPath: String {
        get {
            let fm = FileManager.default
            if let override = d.string(forKey: Keys.binaryPath), !override.isEmpty { return override }
            if let bundled = Self.bundledWhisperBinary, fm.isExecutableFile(atPath: bundled) { return bundled }
            return Self.defaultBinaryCandidates.first { fm.isExecutableFile(atPath: $0) }
                ?? Self.bundledWhisperBinary ?? Self.defaultBinaryCandidates[0]
        }
        set { d.set(newValue, forKey: Keys.binaryPath) }
    }

    var modelPath: String {
        get {
            let fm = FileManager.default
            if let override = d.string(forKey: Keys.modelPath), !override.isEmpty,
               fm.fileExists(atPath: override) { return override }
            if let existing = Self.defaultModelCandidates.first(where: { fm.fileExists(atPath: $0) }) { return existing }
            if let bundled = Self.bundledModel, fm.fileExists(atPath: bundled) { return bundled }
            return Self.bundledModel ?? Self.defaultModelCandidates[0]
        }
        set { d.set(newValue, forKey: Keys.modelPath) }
    }

    /// Whisper language code, or "auto" to auto-detect. Auto-detect needs a
    /// multilingual model (small / large-v3-turbo), not the English-only base.en.
    var language: String {
        get { d.string(forKey: Keys.language) ?? "auto" }
        set { d.set(newValue, forKey: Keys.language) }
    }

    /// Words/names/jargon to bias Whisper toward (its "initial prompt").
    /// Improves accuracy on proper nouns and acronyms. Local, no cost.
    var customVocabulary: String {
        get { d.string(forKey: Keys.customVocabulary) ?? "" }
        set { d.set(newValue, forKey: Keys.customVocabulary) }
    }

    /// llama.cpp binary for optional local-model processing. Auto-detected, or
    /// override in Settings. Edit here if your build lives elsewhere.
    static var defaultLlamaCandidates: [String] {
        let home = NSHomeDirectory()
        return [
            "\(home)/llama.cpp/build/bin/llama-cli",
            "/opt/homebrew/bin/llama-cli",
            "/usr/local/bin/llama-cli",
        ]
    }

    var llamaBinaryPath: String {
        get {
            let fm = FileManager.default
            if let override = d.string(forKey: Keys.llamaBinaryPath), !override.isEmpty { return override }
            if let bundled = Self.bundledLlamaBinary, fm.isExecutableFile(atPath: bundled) { return bundled }
            return Self.defaultLlamaCandidates.first { fm.isExecutableFile(atPath: $0) }
                ?? Self.bundledLlamaBinary ?? Self.defaultLlamaCandidates[0]
        }
        set { d.set(newValue, forKey: Keys.llamaBinaryPath) }
    }

    /// The downloaded model chosen for processing (nil → first available).
    var selectedLLMModel: String? {
        get { d.string(forKey: Keys.selectedLLMModel) }
        set { d.set(newValue, forKey: Keys.selectedLLMModel) }
    }

    /// How many people are on a meeting call. 0 = auto-detect. Forcing the exact
    /// count makes speaker labeling far more reliable.
    var meetingSpeakerCount: Int {
        get { d.integer(forKey: Keys.meetingSpeakerCount) }
        set { d.set(newValue, forKey: Keys.meetingSpeakerCount) }
    }

    /// Whisper model used for meetings. Meetings favor accuracy over speed, so
    /// this defaults to the biggest downloaded model (large > small > current),
    /// independent of the fast model used for quick dictation.
    var meetingModelPath: String {
        get {
            let fm = FileManager.default
            if let o = d.string(forKey: Keys.meetingModelPath), !o.isEmpty, fm.fileExists(atPath: o) {
                return o
            }
            let home = NSHomeDirectory()
            for name in ["ggml-large-v3-turbo.bin", "ggml-large-v3.bin", "ggml-medium.bin", "ggml-small.bin"] {
                let p = "\(home)/whisper.cpp/models/\(name)"
                if fm.fileExists(atPath: p) { return p }
            }
            return modelPath   // fall back to the general model
        }
        set { d.set(newValue, forKey: Keys.meetingModelPath) }
    }

    var playSounds: Bool {
        get { d.bool(forKey: Keys.playSounds) }
        set { d.set(newValue, forKey: Keys.playSounds) }
    }

    /// Show the floating live-waveform HUD while dictating.
    var showVoiceBar: Bool {
        get { d.bool(forKey: Keys.showVoiceBar) }
        set { d.set(newValue, forKey: Keys.showVoiceBar) }
    }

    /// Show the Dock icon (.regular). When off, Voz runs menu-bar-only (.accessory)
    /// but the status item and hotkey keep working.
    var dockIconVisible: Bool {
        get { d.bool(forKey: Keys.dockIconVisible) }
        set { d.set(newValue, forKey: Keys.dockIconVisible) }
    }

    /// Where the voice bar appears: a preset anchor (0…5) or 6 = custom (dragged).
    var voiceBarAnchor: Int {
        get { d.integer(forKey: Keys.voiceBarAnchor) }
        set { d.set(newValue, forKey: Keys.voiceBarAnchor) }
    }
    /// Custom on-screen origin used when voiceBarAnchor == 6, saved on drag.
    var voiceBarCustomX: Double {
        get { d.double(forKey: Keys.voiceBarCustomX) }
        set { d.set(newValue, forKey: Keys.voiceBarCustomX) }
    }
    var voiceBarCustomY: Double {
        get { d.double(forKey: Keys.voiceBarCustomY) }
        set { d.set(newValue, forKey: Keys.voiceBarCustomY) }
    }

    var startSound: String {
        get { d.string(forKey: Keys.startSound) ?? "Tink" }
        set { d.set(newValue, forKey: Keys.startSound) }
    }

    var stopSound: String {
        get { d.string(forKey: Keys.stopSound) ?? "Tink" }
        set { d.set(newValue, forKey: Keys.stopSound) }
    }
}

// MARK: - Debug logging

/// Lightweight file logger used while bringing up the record → transcribe → paste
/// flow. DISABLED for release: it wrote to /tmp/voz-debug.log — a world-readable
/// file — including snippets of transcribed text, which violates Voz's "audio
/// never leaves your Mac / stays private" promise. Flip `enabled` to true only
/// for local debugging; it should ship as false.
enum VozLog {
    static let enabled = false
    static let path = "/tmp/voz-debug.log"
    static func log(_ msg: String) {
        guard enabled else { return }
        let line = "\(Date()) | \(msg)\n"
        guard let data = line.data(using: .utf8) else { return }
        if let fh = FileHandle(forWritingAtPath: path) {
            fh.seekToEndOfFile(); fh.write(data); fh.closeFile()
        } else {
            try? data.write(to: URL(fileURLWithPath: path))
        }
    }
}

// MARK: - Model discovery

/// Finds the Whisper `.bin` models already downloaded on disk so the
/// Preferences model picker can list them. Everything here is local — it just
/// scans the whisper.cpp models folder. All models run 100% offline.
enum WhisperModels {

    /// Folders we look in: the folder of the current model, plus the default
    /// ~/whisper.cpp/models. Add more here if you keep models elsewhere.
    static var searchDirectories: [String] {
        var dirs: [String] = []
        let currentDir = (Settings.shared.modelPath as NSString).deletingLastPathComponent
        if !currentDir.isEmpty { dirs.append(currentDir) }
        dirs.append("\(NSHomeDirectory())/whisper.cpp/models")
        // De-duplicate while preserving order.
        var seen = Set<String>()
        return dirs.filter { seen.insert($0).inserted }
    }

    /// (friendlyName, fullPath) for every real ggml model found.
    /// The repo's `for-tests-*` fixtures are skipped (they don't start "ggml-").
    static var available: [(name: String, path: String)] {
        let fm = FileManager.default
        var results: [(name: String, path: String)] = []
        var seenPaths = Set<String>()
        for dir in searchDirectories {
            let files = (try? fm.contentsOfDirectory(atPath: dir)) ?? []
            for f in files where f.hasPrefix("ggml-") && f.hasSuffix(".bin") {
                let full = (dir as NSString).appendingPathComponent(f)
                if seenPaths.insert(full).inserted {
                    results.append((friendlyName(f), full))
                }
            }
        }
        // Collapse to one entry per capability tier so we never show two
        // identical labels (e.g. base, base.en, and the bundled base all read as
        // "Small (Good)"). Keep the currently-selected model within each tier.
        let current = Settings.shared.modelPath
        var byLabel: [String: (name: String, path: String)] = [:]
        for item in results.sorted(by: { tierRank(forPath: $0.path) < tierRank(forPath: $1.path) }) {
            let label = shortLabel(forPath: item.path)
            if byLabel[label] == nil || item.path == current { byLabel[label] = item }
        }
        // Order by capability: Good → Better → Best.
        return byLabel.values.sorted { tierRank(forPath: $0.path) < tierRank(forPath: $1.path) }
    }

    /// "ggml-large-v3-turbo.bin" -> "large-v3-turbo"
    static func friendlyName(_ filename: String) -> String {
        var n = (filename as NSString).lastPathComponent
        if n.hasPrefix("ggml-") { n.removeFirst("ggml-".count) }
        if n.hasSuffix(".bin") { n.removeLast(".bin".count) }
        return n
    }

    /// A plain-English tier label + recommendation for a model, so the UI can
    /// avoid raw names like "large-v3-turbo".
    static func tier(forPath path: String) -> (label: String, recommendation: String) {
        let n = friendlyName(path).lowercased()
        if n.contains("large") {
            return ("Large (Best)", "Most accurate — best for meetings and tough audio")
        }
        if n.contains("medium") {
            return ("Medium (Better)", "High accuracy, a little slower")
        }
        if n.contains("small") {
            return ("Medium (Better)", "Balanced speed and accuracy — good all-rounder")
        }
        if n.contains("base") {
            return ("Small (Good)", "Fast — great for quick dictation")
        }
        if n.contains("tiny") {
            return ("Small (Fastest)", "Fastest, roughest accuracy")
        }
        return (friendlyName(path), "")
    }

    static func shortLabel(forPath path: String) -> String { tier(forPath: path).label }

    /// Capability rank used to order pickers Good → Better → Best.
    static func tierRank(forPath path: String) -> Int {
        let n = friendlyName(path).lowercased()
        if n.contains("tiny") { return 0 }
        if n.contains("base") { return 1 }
        if n.contains("small") { return 2 }
        if n.contains("medium") { return 3 }
        if n.contains("large") { return 4 }
        return 5
    }

    /// On-disk size of a model, formatted (e.g. "142 MB").
    static func sizeText(forPath path: String) -> String {
        guard let n = (try? FileManager.default.attributesOfItem(atPath: path)[.size]) as? NSNumber
        else { return "" }
        return ByteCountFormatter.string(fromByteCount: n.int64Value, countStyle: .file)
    }

    /// Tier label with size, e.g. "Small (Good) · 142 MB".
    static func labelWithSize(forPath path: String) -> String {
        let size = sizeText(forPath: path)
        return size.isEmpty ? shortLabel(forPath: path) : "\(shortLabel(forPath: path)) · \(size)"
    }
}
