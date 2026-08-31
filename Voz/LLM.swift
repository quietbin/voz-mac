//
//  LLM.swift
//  Voz
//
//  Optional, fully-local language models for on-device processing (summaries,
//  meeting notes). Nothing here ships in the base app — models are downloaded
//  on demand and run locally via a llama.cpp binary (mirrors how transcription
//  shells out to whisper.cpp). No cloud, no API.
//
//  Set up (like whisper.cpp):
//      git clone https://github.com/ggml-org/llama.cpp ~/llama.cpp
//      cd ~/llama.cpp && cmake -B build -DGGML_METAL=ON && cmake --build build -j
//  → produces ~/llama.cpp/build/bin/llama-cli (auto-detected below).
//

import Foundation
import Combine

// MARK: - Catalog

/// A downloadable local model. Quantized GGUF files from public repos.
struct LLMModel: Identifiable, Hashable {
    let id: String            // stable id + filename base
    let name: String
    let params: String        // "3B", "8B"
    let approxBytes: Int64
    let ramHint: String       // guidance shown in UI
    let url: URL

    var filename: String { "\(id).gguf" }
    var sizeText: String { ByteCountFormatter.string(fromByteCount: approxBytes, countStyle: .file) }
}

enum LLMCatalog {
    /// A deliberately short list: a fast 3B default and a sharper 8B option.
    static let models: [LLMModel] = [
        LLMModel(
            id: "qwen2.5-3b-instruct-q4",
            name: "Small (Good)",
            params: "3B", approxBytes: 1_930_000_000,
            ramHint: "Fast. Works on any Mac, including 8 GB.",
            url: URL(string: "https://huggingface.co/bartowski/Qwen2.5-3B-Instruct-GGUF/resolve/main/Qwen2.5-3B-Instruct-Q4_K_M.gguf")!),
        LLMModel(
            id: "qwen2.5-7b-instruct-q4",
            name: "Medium (Better)",
            params: "7B", approxBytes: 4_680_000_000,
            ramHint: "Sharper summaries & follow-ups. Best on 16 GB+ Macs.",
            url: URL(string: "https://huggingface.co/bartowski/Qwen2.5-7B-Instruct-GGUF/resolve/main/Qwen2.5-7B-Instruct-Q4_K_M.gguf")!),
        LLMModel(
            id: "qwen2.5-14b-instruct-q4",
            name: "Large (Best)",
            params: "14B", approxBytes: 8_990_000_000,
            ramHint: "Most accurate. Needs ~24 GB+ of RAM.",
            url: URL(string: "https://huggingface.co/bartowski/Qwen2.5-14B-Instruct-GGUF/resolve/main/Qwen2.5-14B-Instruct-Q4_K_M.gguf")!),
    ]

    static func model(id: String) -> LLMModel? { models.first { $0.id == id } }
}

// MARK: - Download / storage

/// Manages on-demand downloads of local models to Application Support/Voz/models.
final class ModelStore: NSObject, ObservableObject, URLSessionDownloadDelegate {
    static let shared = ModelStore()

    enum DownloadState: Equatable {
        case notDownloaded
        case downloading(Double)   // 0...1
        case downloaded
        case failed(String)
    }

    @Published var states: [String: DownloadState] = [:]

    let dir: URL
    // Accessed from both the main thread (download) and the URLSession delegate
    // queue (callbacks), so every access goes through `taskMapLock`.
    private var idForTask: [Int: String] = [:]
    private let taskMapLock = NSLock()
    private func taskID(_ tid: Int) -> String? {
        taskMapLock.lock(); defer { taskMapLock.unlock() }; return idForTask[tid]
    }
    private func setTaskID(_ tid: Int, _ id: String?) {
        taskMapLock.lock(); defer { taskMapLock.unlock() }; idForTask[tid] = id
    }
    private lazy var session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)

    private override init() {
        dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Voz/models", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        super.init()
        refresh()
    }

    func localURL(_ m: LLMModel) -> URL { dir.appendingPathComponent(m.filename) }
    func isDownloaded(_ m: LLMModel) -> Bool { FileManager.default.fileExists(atPath: localURL(m).path) }

    func refresh() {
        for m in LLMCatalog.models where !(states[m.id]?.isInFlight ?? false) {
            states[m.id] = isDownloaded(m) ? .downloaded : .notDownloaded
        }
    }

    /// The first downloaded model, preferring the user's selected one.
    func activeModel() -> LLMModel? {
        if let sel = Settings.shared.selectedLLMModel,
           let m = LLMCatalog.model(id: sel), isDownloaded(m) { return m }
        return LLMCatalog.models.first { isDownloaded($0) }
    }

    var hasAnyModel: Bool { LLMCatalog.models.contains { isDownloaded($0) } }

    func download(_ m: LLMModel) {
        guard !(states[m.id]?.isInFlight ?? false) else { return }
        DispatchQueue.main.async { self.states[m.id] = .downloading(0) }
        let task = session.downloadTask(with: m.url)
        setTaskID(task.taskIdentifier, m.id)
        task.resume()
    }

    func delete(_ m: LLMModel) {
        try? FileManager.default.removeItem(at: localURL(m))
        if Settings.shared.selectedLLMModel == m.id { Settings.shared.selectedLLMModel = nil }
        DispatchQueue.main.async { self.states[m.id] = .notDownloaded }
    }

    /// Choose which downloaded model is used for processing.
    func setActive(_ m: LLMModel) {
        Settings.shared.selectedLLMModel = m.id
        objectWillChange.send()
    }

    // URLSessionDownloadDelegate

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        guard let id = taskID(downloadTask.taskIdentifier), totalBytesExpectedToWrite > 0 else { return }
        let p = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        DispatchQueue.main.async { self.states[id] = .downloading(p) }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        guard let id = taskID(downloadTask.taskIdentifier), let m = LLMCatalog.model(id: id) else { return }
        // Reject HTML error pages / tiny files (e.g. auth or 404 responses).
        let size = (try? FileManager.default.attributesOfItem(atPath: location.path)[.size] as? Int64) ?? 0
        let dest = localURL(m)
        do {
            if size < 10_000_000 { throw NSError(domain: "Voz", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Download failed (unexpected file). Check your connection."]) }
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.moveItem(at: location, to: dest)
            DispatchQueue.main.async { self.states[id] = .downloaded }
        } catch {
            DispatchQueue.main.async { self.states[id] = .failed(error.localizedDescription) }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let id = taskID(task.taskIdentifier) else { return }
        setTaskID(task.taskIdentifier, nil)
        if let error = error {
            DispatchQueue.main.async { self.states[id] = .failed(error.localizedDescription) }
        }
    }
}

extension ModelStore.DownloadState {
    var isInFlight: Bool { if case .downloading = self { return true }; return false }
}

// MARK: - Inference

enum LocalLLMError: LocalizedError {
    case binaryMissing(String)
    case noModel
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .binaryMissing(let p): return "llama.cpp binary not found at:\n\(p)\n\nBuild it (see LLM.swift header) or set the path in Settings."
        case .noModel: return "No local model downloaded yet. Download one in Settings → AI."
        case .failed(let m): return "Local model failed:\n\(m)"
        }
    }
}

final class LocalLLM {
    static let shared = LocalLLM()

    var binaryAvailable: Bool { FileManager.default.isExecutableFile(atPath: Settings.shared.llamaBinaryPath) }
    var isReady: Bool { binaryAvailable && ModelStore.shared.hasAnyModel }

    /// llama-cli in single-turn mode prints a banner, the echoed prompt, the
    /// reply, then a "[ Prompt: … ]" timing line. Slice out just the reply:
    /// everything after the echoed user prompt and before the timing line.
    static func extractReply(from raw: String, userPrompt: String) -> String {
        var s = raw
        if let r = s.range(of: "[ Prompt:") { s = String(s[..<r.lowerBound]) }
        // llama-cli truncates long echoed prompts and appends "(truncated)". When
        // present, the reply is whatever follows it. Otherwise (short prompts) the
        // full prompt is echoed, so we slice past that.
        if let r = s.range(of: "truncated)", options: .backwards) {
            s = String(s[r.upperBound...])
        } else if let r = s.range(of: userPrompt) {
            s = String(s[r.upperBound...])
        } else if let r = s.range(of: "\n> ", options: .backwards) {
            s = String(s[r.upperBound...])
        }
        return s
            .replacingOccurrences(of: "[end of text]", with: "")
            .trimmingCharacters(in: CharacterSet(charactersIn: "> \n\t"))
    }

    /// Summarizes a transcript into concise notes. Off the main thread.
    func summarize(_ transcript: String, completion: @escaping (Result<String, Error>) -> Void) {
        let system = "You are a concise meeting-notes assistant. Given a transcript, produce a short summary followed by a bulleted list of key points and any action items. Use plain text."
        let user = "Summarize this transcript:\n\n\(transcript)"
        run(system: system, user: user, maxTokens: 600, completion: completion)
    }

    /// A short, abstractive meeting summary — a few sentences, in the model's own
    /// words (NOT copied from the transcript).
    func summarizeMeeting(_ transcript: String, completion: @escaping (Result<String, Error>) -> Void) {
        let system = """
        You summarize a meeting as a short bullet list. Output 3 to 6 dashes, each a \
        brief phrase (max ~8 words) naming a topic discussed or a decision made — in \
        your OWN words. Do NOT copy sentences from the transcript, do not quote \
        anyone, and never include raw transcript text.

        Example output:
        - Set launch date (August 27)
        - Debated $39 pricing and margins
        - Agreed on an intro launch discount
        - Finance to model numbers by Friday

        Now summarize the transcript below the same way. Output only the dashes. If \
        there's too little to summarize, output exactly: (Not enough was said to summarize.)
        """
        let user = "Transcript:\n\n\(transcript)\n\nSummary bullets:"
        run(system: system, user: user, maxTokens: 200, temperature: 0.3, completion: completion)
    }

    /// Extracts action items / follow-ups from a meeting transcript as a list.
    func extractActions(_ transcript: String, completion: @escaping (Result<[String], Error>) -> Void) {
        let system = """
        List only the clearest action items from a meeting transcript — a specific \
        thing a specific person explicitly agreed to do or was directly asked to do \
        (e.g. "I'll send the deck", "can you follow up with finance"). \
        Be extremely selective: at most 3 items, and only ones you are confident \
        about. Most meetings have 0–2. IGNORE small talk, opinions, general \
        discussion, and anything vague. Each line: a short imperative task starting \
        with "- " (max 8 words). No summary or restatement. \
        If there are no clear action items, output exactly: NONE
        """
        let user = "Transcript:\n\n\(transcript)\n\nAction items (max 3):"
        run(system: system, user: user, maxTokens: 160, temperature: 0.1) { result in
            completion(result.map { Array(Self.parseActionItems($0).prefix(3)) })
        }
    }

    static func parseActionItems(_ text: String) -> [String] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.uppercased().hasPrefix("NONE") { return [] }
        return text.split(separator: "\n").compactMap { line in
            let stripped = String(line)
                .replacingOccurrences(of: #"^\s*[-*•\d\.\)\]]+\s*"#, with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespaces)
            return stripped.isEmpty ? nil : stripped
        }
    }

    private func run(system: String, user: String, maxTokens: Int, temperature: Double = 0.3,
                     completion: @escaping (Result<String, Error>) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let result = self.runSync(system: system, user: user, maxTokens: maxTokens, temperature: temperature)
            DispatchQueue.main.async { completion(result) }
        }
    }

    /// Synchronous inference. Blocking — call off the main thread.
    func runSync(system: String, user: String, maxTokens: Int, temperature: Double = 0.3) -> Result<String, Error> {
        let binary = Settings.shared.llamaBinaryPath
        guard FileManager.default.isExecutableFile(atPath: binary) else {
            return .failure(LocalLLMError.binaryMissing(binary))
        }
        guard let model = ModelStore.shared.activeModel() else {
            return .failure(LocalLLMError.noModel)
        }
        let modelPath = ModelStore.shared.localURL(model).path

        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = [
            "-m", modelPath, "-sys", system, "-p", user, "-st", "--log-disable",
            "-n", "\(maxTokens)", "--temp", "\(temperature)", "-ngl", "99", "-c", "8192", "--no-warmup",
        ]
        let out = Pipe(); let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        do { try process.run() } catch { return .failure(LocalLLMError.failed(error.localizedDescription)) }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        let text = Self.extractReply(from: String(data: data, encoding: .utf8) ?? "", userPrompt: user)
        if text.isEmpty {
            return .failure(LocalLLMError.failed(String(data: errData, encoding: .utf8)?.suffix(300).description ?? "no output"))
        }
        return .success(text)
    }

    /// Separates a whole meeting transcript into readable, turn-by-turn responses
    /// (best-effort, from the text). Chunks long transcripts. Synchronous — call
    /// off the main thread.
    func separateTranscript(_ text: String) -> String {
        var lines: [String] = []
        for chunk in Self.chunk(text, maxChars: 900) {
            lines.append(contentsOf: cleanAndSplit(chunk))
        }
        return lines.joined(separator: "\n\n")
    }

    /// Splits text into ~maxChars pieces at sentence boundaries.
    static func chunk(_ text: String, maxChars: Int) -> [String] {
        let sentences = text.replacingOccurrences(of: #"([.!?])\s+"#, with: "$1\n", options: .regularExpression)
            .split(separator: "\n").map(String.init)
        var chunks: [String] = []
        var cur = ""
        for s in sentences {
            if cur.count + s.count > maxChars, !cur.isEmpty { chunks.append(cur); cur = "" }
            cur += (cur.isEmpty ? "" : " ") + s
        }
        if !cur.isEmpty { chunks.append(cur) }
        return chunks.isEmpty ? [text] : chunks
    }

    /// Cleans a stretch of meeting speech (punctuation + capitalization) and
    /// splits it into separate speaker turns, one per line, preserving wording.
    /// Synchronous. Returns the input unchanged if the model isn't ready/fails.
    func cleanAndSplit(_ text: String) -> [String] {
        let system = """
        You clean up meeting speech and split it into turns. Rules: (1) add proper \
        capitalization and punctuation; (2) put each separate speaker turn on its \
        OWN line; (3) keep the wording and meaning — do not add facts or summarize. \
        A new turn starts when a different person speaks (a new answer, addressing \
        someone by name, a question then its answer).

        Example input:
        yeah i think fridays fine what do you think nico i disagree lets do monday okay monday works
        Example output:
        Yeah, I think Friday's fine. What do you think, Nico?
        I disagree, let's do Monday.
        Okay, Monday works.

        Now do the same for the input. Output only the cleaned, split lines.
        """
        guard case .success(let reply) = runSync(system: system, user: text, maxTokens: 500, temperature: 0.15)
        else { return [text] }
        let lines = reply.split(separator: "\n").map {
            $0.trimmingCharacters(in: .whitespaces)
                .replacingOccurrences(of: #"^[-*•\d\.\)\]]+\s*"#, with: "", options: .regularExpression)
        }.filter { !$0.isEmpty }
        return lines.isEmpty ? [text] : lines
    }
}
