//
//  AppState.swift
//  Voz
//
//  Shared observable state that bridges the AppKit backend (recorder, whisper,
//  hotkey — all owned by AppDelegate) and the SwiftUI window UI. AppDelegate
//  wires the `onXxx` callbacks and pushes status/history updates here; the
//  SwiftUI views observe it and call back through it.
//

import SwiftUI
import Combine

/// One transcription result, persisted to disk so history survives relaunches.
/// A follow-up / action item that can be checked off, dated, or removed.
struct ActionItem: Identifiable, Codable, Equatable, Hashable {
    var id: UUID
    var text: String
    var done: Bool
    var dueDate: Date?

    init(text: String, done: Bool = false, dueDate: Date? = nil) {
        self.id = UUID(); self.text = text; self.done = done; self.dueDate = dueDate
    }

    enum CodingKeys: String, CodingKey { case id, text, done, dueDate }

    // Backward compatible: old meetings stored action items as plain strings.
    init(from decoder: Decoder) throws {
        if let single = try? decoder.singleValueContainer(), let s = try? single.decode(String.self) {
            self.id = UUID(); self.text = s; self.done = false; self.dueDate = nil
            return
        }
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = (try? c.decode(UUID.self, forKey: .id)) ?? UUID()
        self.text = try c.decode(String.self, forKey: .text)
        self.done = (try? c.decode(Bool.self, forKey: .done)) ?? false
        self.dueDate = try? c.decodeIfPresent(Date.self, forKey: .dueDate)
    }
}

struct HistoryEntry: Identifiable, Codable, Equatable {
    var id = UUID()
    var text: String
    var date: Date
    var source: String        // "Dictation", a file name, or "Meeting"
    var model: String         // friendly model name used
    var title: String? = nil       // user-editable name (meetings)
    var summary: String? = nil     // optional local-LLM summary
    var notes: String? = nil       // your own notes (meetings)
    var actionItems: [ActionItem]? = nil // auto-extracted follow-ups (meetings)
    var speakerNames: [String: String]? = nil // "Speaker 1" -> custom name (meetings)
    var separatedText: String? = nil    // on-demand speaker/turn-separated version

    var isFile: Bool { source != "Dictation" && source != "Meeting" }
    var isMeeting: Bool { source == "Meeting" }
    var displayTitle: String { (title?.isEmpty == false ? title! : "Meeting") }

    /// Type label used in the combined History list.
    var kind: String { isMeeting ? "Meeting" : (isFile ? "Transcription" : "Dictation") }

    /// Distinct "Speaker N" labels present in the transcript, in order.
    var detectedSpeakers: [String] {
        var seen: [String] = []
        for line in text.split(separator: "\n") {
            if let r = line.range(of: #"^Speaker \d+"#, options: .regularExpression) {
                let label = String(line[r])
                if !seen.contains(label) { seen.append(label) }
            }
        }
        return seen
    }

    /// What to show: the on-demand separated version if present, else the plain.
    var displayTranscript: String { separatedText ?? renderedTranscript }

    /// Transcript with each "Speaker N:" replaced by the user's custom name.
    var renderedTranscript: String {
        guard let names = speakerNames, !names.isEmpty else { return text }
        return text.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
            let l = String(line)
            for (label, name) in names where l.hasPrefix("\(label): ") {
                return name + ": " + l.dropFirst(label.count + 2)
            }
            return l
        }.joined(separator: "\n")
    }
}

final class AppState: ObservableObject {
    static let shared = AppState()

    enum Status: Equatable { case idle, recording, transcribing }
    @Published var status: Status = .idle
    @Published var history: [HistoryEntry] = []      // dictations + file transcriptions
    @Published var meetings: [HistoryEntry] = []      // kept separate from History

    /// Just the dictations (Dictate tab).
    var dictations: [HistoryEntry] { history.filter { $0.source == "Dictation" } }
    /// Just the file transcriptions (Transcribe tab).
    var fileTranscriptions: [HistoryEntry] { history.filter { $0.isFile } }
    /// Everything, newest first, labeled by kind (History tab).
    var allItems: [HistoryEntry] { (history + meetings).sorted { $0.date > $1.date } }
    @Published var banner: String?          // transient message shown in the UI
    @Published var currentModelName: String = WhisperModels.shortLabel(forPath: Settings.shared.modelPath)
    @Published var selectedTab: VozTab = .dictate   // drives sidebar navigation

    // Meeting capture state
    enum MeetingPhase: Equatable { case idle, recording, transcribing, done }
    @Published var meetingPhase: MeetingPhase = .idle
    @Published var meetingTranscript: String = ""
    @Published var meetingCapturingSystem = false   // was system audio captured?
    @Published var meetingExtractingActions = false
    @Published var meetingSummarizing = false

    // Wired by AppDelegate:
    var onToggleRecord: (() -> Void)?
    var onTranscribeFiles: (([URL]) -> Void)?
    var onOpenShortcutPrefs: (() -> Void)?
    var onReloadHotkey: (() -> Void)?       // re-register the global hotkey after a change
    var onStartMeeting: (() -> Void)?
    var onStopMeeting: ((String) -> Void)?  // passes the user's typed notes
    var onUpdateActivationPolicy: (() -> Void)?   // dock icon vs menu-bar-only

    private let historyURL: URL
    private let meetingsURL: URL

    private init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Voz", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        historyURL = base.appendingPathComponent("history.json")
        meetingsURL = base.appendingPathComponent("meetings.json")
        loadHistory()
        loadMeetings()
    }

    // MARK: - Actions the UI triggers

    func toggleRecord() { onToggleRecord?() }
    func transcribeFiles(_ urls: [URL]) { onTranscribeFiles?(urls) }
    func openShortcutPrefs() { onOpenShortcutPrefs?() }
    func reloadHotkey() { onReloadHotkey?() }
    func startMeeting() { onStartMeeting?() }
    func stopMeeting(notes: String) { onStopMeeting?(notes) }

    func refreshModelName() {
        currentModelName = WhisperModels.shortLabel(forPath: Settings.shared.modelPath)
    }

    func flash(_ message: String) {
        banner = message
    }

    // MARK: - History

    func addHistory(_ entry: HistoryEntry) {
        history.insert(entry, at: 0)
        saveHistory()
    }

    func deleteHistory(_ entry: HistoryEntry) {
        history.removeAll { $0.id == entry.id }
        saveHistory()
    }

    func setSummary(_ summary: String, for id: UUID) {
        if let i = history.firstIndex(where: { $0.id == id }) {
            history[i].summary = summary
            saveHistory()
        }
    }

    /// Save a user-edited transcript (dictation, file, or meeting).
    func updateTranscript(_ text: String, for entry: HistoryEntry) {
        if entry.isMeeting {
            guard let i = meetings.firstIndex(where: { $0.id == entry.id }) else { return }
            meetings[i].text = text
            meetings[i].separatedText = nil   // editing the base invalidates the separated version
            saveMeetings()
        } else {
            guard let i = history.firstIndex(where: { $0.id == entry.id }) else { return }
            history[i].text = text
            saveHistory()
        }
    }

    func clearHistory() {
        history.removeAll()
        saveHistory()
    }

    private func loadHistory() {
        guard let data = try? Data(contentsOf: historyURL),
              let items = try? JSONDecoder().decode([HistoryEntry].self, from: data) else { return }
        history = items
    }

    private func saveHistory() {
        if let data = try? JSONEncoder().encode(history) {
            try? data.write(to: historyURL)
        }
    }

    // MARK: - Meetings (kept in their own tab, not History)

    func addMeeting(_ entry: HistoryEntry) {
        meetings.insert(entry, at: 0)
        saveMeetings()
    }

    func deleteMeeting(_ id: UUID) {
        meetings.removeAll { $0.id == id }
        saveMeetings()
    }

    func renameMeeting(_ id: UUID, to title: String) {
        if let i = meetings.firstIndex(where: { $0.id == id }) {
            meetings[i].title = title.trimmingCharacters(in: .whitespacesAndNewlines)
            saveMeetings()
        }
    }

    func setMeetingActionItems(_ items: [ActionItem], for id: UUID) {
        if let i = meetings.firstIndex(where: { $0.id == id }) {
            meetings[i].actionItems = items
            saveMeetings()
        }
    }

    // Per-item edits (check off / date / remove) on a meeting's follow-ups.
    private func mutateItems(_ meetingID: UUID, _ change: (inout [ActionItem]) -> Void) {
        guard let mi = meetings.firstIndex(where: { $0.id == meetingID }) else { return }
        var items = meetings[mi].actionItems ?? []
        change(&items)
        meetings[mi].actionItems = items
        saveMeetings()
    }

    func toggleActionItem(_ meetingID: UUID, _ itemID: UUID) {
        mutateItems(meetingID) { items in
            if let i = items.firstIndex(where: { $0.id == itemID }) { items[i].done.toggle() }
        }
    }

    func removeActionItem(_ meetingID: UUID, _ itemID: UUID) {
        mutateItems(meetingID) { $0.removeAll { $0.id == itemID } }
    }

    func setActionItemDate(_ meetingID: UUID, _ itemID: UUID, _ date: Date?) {
        mutateItems(meetingID) { items in
            if let i = items.firstIndex(where: { $0.id == itemID }) { items[i].dueDate = date }
        }
    }

    func setMeetingSummary(_ summary: String, for id: UUID) {
        if let i = meetings.firstIndex(where: { $0.id == id }) {
            meetings[i].summary = summary
            saveMeetings()
        }
    }

    func setMeetingSeparated(_ text: String, for id: UUID) {
        if let i = meetings.firstIndex(where: { $0.id == id }) {
            meetings[i].separatedText = text
            saveMeetings()
        }
    }

    func renameSpeaker(_ meetingID: UUID, label: String, to name: String) {
        guard let i = meetings.firstIndex(where: { $0.id == meetingID }) else { return }
        var map = meetings[i].speakerNames ?? [:]
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { map[label] = nil } else { map[label] = trimmed }
        meetings[i].speakerNames = map.isEmpty ? nil : map
        saveMeetings()
    }

    private func loadMeetings() {
        guard let data = try? Data(contentsOf: meetingsURL),
              let items = try? JSONDecoder().decode([HistoryEntry].self, from: data) else { return }
        meetings = items
    }

    private func saveMeetings() {
        if let data = try? JSONEncoder().encode(meetings) {
            try? data.write(to: meetingsURL)
        }
    }
}

// MARK: - Languages

struct WhisperLanguage: Identifiable, Hashable {
    let code: String
    let name: String
    var id: String { code }
}

enum Languages {
    /// "auto" plus a broad set of common Whisper languages. Whisper supports ~99;
    /// this covers the ones most people need. Add more codes as desired.
    static let all: [WhisperLanguage] = [
        .init(code: "auto", name: "Auto-detect"),
        .init(code: "en", name: "English"),
        .init(code: "es", name: "Spanish"),
        .init(code: "fr", name: "French"),
        .init(code: "de", name: "German"),
        .init(code: "it", name: "Italian"),
        .init(code: "pt", name: "Portuguese"),
        .init(code: "nl", name: "Dutch"),
        .init(code: "ru", name: "Russian"),
        .init(code: "pl", name: "Polish"),
        .init(code: "uk", name: "Ukrainian"),
        .init(code: "sv", name: "Swedish"),
        .init(code: "no", name: "Norwegian"),
        .init(code: "da", name: "Danish"),
        .init(code: "fi", name: "Finnish"),
        .init(code: "tr", name: "Turkish"),
        .init(code: "ar", name: "Arabic"),
        .init(code: "he", name: "Hebrew"),
        .init(code: "hi", name: "Hindi"),
        .init(code: "zh", name: "Chinese"),
        .init(code: "ja", name: "Japanese"),
        .init(code: "ko", name: "Korean"),
        .init(code: "vi", name: "Vietnamese"),
        .init(code: "th", name: "Thai"),
        .init(code: "id", name: "Indonesian"),
        .init(code: "cs", name: "Czech"),
        .init(code: "el", name: "Greek"),
        .init(code: "ro", name: "Romanian"),
        .init(code: "hu", name: "Hungarian"),
        .init(code: "ca", name: "Catalan"),
    ]

    static func name(for code: String) -> String {
        all.first { $0.code == code }?.name ?? code.uppercased()
    }
}
