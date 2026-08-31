//
//  Transcriber.swift
//  Voz
//
//  Runs whisper.cpp locally via Process() and returns the transcribed text.
//  Nothing leaves the machine — no API, no network.
//
//  We invoke the binary with `-otxt`-free, stdout-only flags and parse stdout.
//  whisper.cpp prints each segment prefixed with a timestamp like
//  "[00:00:00.000 --> 00:00:02.000]  Hello there"; we strip the timestamps
//  and join the remaining text.
//

import Foundation

/// Reads a process's stdout+stderr pipes to EOF *concurrently*, returning both.
/// Must be called before `waitUntilExit()`: a child that writes more than the
/// ~64 KB pipe buffer blocks until we read, so draining after the wait deadlocks.
/// Both handles are drained on background queues so neither can starve the other.
func drainPipes(_ out: Pipe, _ err: Pipe) -> (out: Data, err: Data) {
    let outHandle = out.fileHandleForReading
    let errHandle = err.fileHandleForReading
    var outData = Data(); var errData = Data()
    let group = DispatchGroup()
    group.enter(); DispatchQueue.global(qos: .userInitiated).async {
        outData = outHandle.readDataToEndOfFile(); group.leave()
    }
    group.enter(); DispatchQueue.global(qos: .userInitiated).async {
        errData = errHandle.readDataToEndOfFile(); group.leave()
    }
    group.wait()
    return (outData, errData)
}

enum TranscriberError: LocalizedError {
    case binaryMissing(String)
    case modelMissing(String)
    case processFailed(String)

    var errorDescription: String? {
        switch self {
        case .binaryMissing(let p):
            return "whisper.cpp binary not found at:\n\(p)\n\nBuild it (see README) or set the correct path in Preferences."
        case .modelMissing(let p):
            return "Model file not found at:\n\(p)\n\nDownload it (see README) or pick another in Preferences."
        case .processFailed(let m):
            return "Transcription failed:\n\(m)"
        }
    }
}

final class Transcriber {

    /// Transcribes `audioURL` off the main thread and calls `completion` on main.
    /// `modelPath` overrides the default model (used to give meetings a bigger model).
    func transcribe(audioURL: URL, modelPath: String? = nil,
                    completion: @escaping (Result<String, Error>) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let result = self.runWhisper(audioURL: audioURL, modelPath: modelPath)
            DispatchQueue.main.async { completion(result) }
        }
    }

    /// Transcribes any audio/video file: converts it to 16 kHz mono WAV with
    /// ffmpeg first, then runs whisper. Off the main thread; completes on main.
    func transcribeFile(_ fileURL: URL, completion: @escaping (Result<String, Error>) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let wav = try AudioConverter.convertToWav(fileURL)
                let segs = try self.runWhisperSegments(wavURL: wav)   // timed → readable formatting
                try? FileManager.default.removeItem(at: wav)
                DispatchQueue.main.async { completion(.success(Self.formatSegments(segs))) }
            } catch {
                DispatchQueue.main.async { completion(.failure(error)) }
            }
        }
    }

    // MARK: - Timestamped segments (for meeting You/Them labeling)

    struct Segment { let start: Double; let end: Double; let text: String }

    /// Turns timed segments into a readable transcript instead of one blob: each
    /// segment on its own line, with a blank line (paragraph/stanza break) wherever
    /// there's a real pause in the audio. Works for songs (lyric lines) and speech.
    static func formatSegments(_ segs: [Segment]) -> String {
        var lines: [String] = []
        for (i, seg) in segs.enumerated() {
            let t = seg.text.trimmingCharacters(in: .whitespaces)
            if t.isEmpty { continue }
            lines.append(t)
            if i + 1 < segs.count, segs[i + 1].start - seg.end > 1.4 { lines.append("") }
        }
        return lines.joined(separator: "\n")
    }

    /// Transcribes a media file into timestamped segments (converts via ffmpeg
    /// first). Used to interleave two streams by time.
    func transcribeSegments(mediaURL: URL, modelPath: String? = nil,
                            completion: @escaping (Result<[Segment], Error>) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let wav = try AudioConverter.convertToWav(mediaURL)
                let segs = try self.runWhisperSegments(wavURL: wav, modelPath: modelPath)
                try? FileManager.default.removeItem(at: wav)
                DispatchQueue.main.async { completion(.success(segs)) }
            } catch {
                DispatchQueue.main.async { completion(.failure(error)) }
            }
        }
    }

    /// Synchronous segment transcription of an already-16 kHz-mono WAV. Blocking —
    /// call off the main thread. Used by the channel-based meeting pipeline.
    func segments(wavURL: URL, modelPath: String?) throws -> [Segment] {
        try runWhisperSegments(wavURL: wavURL, modelPath: modelPath)
    }

    private func runWhisperSegments(wavURL: URL, modelPath: String? = nil) throws -> [Segment] {
        let binary = Settings.shared.binaryPath
        let model = modelPath ?? Settings.shared.modelPath
        let fm = FileManager.default
        guard fm.isExecutableFile(atPath: binary) else { throw TranscriberError.binaryMissing(binary) }
        guard fm.fileExists(atPath: model) else { throw TranscriberError.modelMissing(model) }

        let outBase = fm.temporaryDirectory.appendingPathComponent("voz-seg-\(UUID().uuidString)")
        let jsonURL = URL(fileURLWithPath: outBase.path + ".json")
        defer { try? fm.removeItem(at: jsonURL) }

        let lang = resolveLanguage(Settings.shared.language, binary: binary, model: model, wavPath: wavURL.path)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        var args = ["-m", model, "-f", wavURL.path, "-l", lang, "-np",
                    "-oj", "-of", outBase.path,
                    "-t", "\(max(4, ProcessInfo.processInfo.activeProcessorCount - 2))"]
        let vocab = Settings.shared.customVocabulary.trimmingCharacters(in: .whitespacesAndNewlines)
        if !vocab.isEmpty { args += ["--prompt", vocab] }
        process.arguments = args
        // whisper still writes the transcript to stdout even with -np, so we must
        // drain it (concurrently, before waiting) or a long meeting deadlocks.
        let out = Pipe(); let err = Pipe()
        process.standardOutput = out; process.standardError = err
        try process.run()
        let (_, errData) = drainPipes(out, err)
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let msg = String(data: errData, encoding: .utf8) ?? "exit \(process.terminationStatus)"
            throw TranscriberError.processFailed(msg)
        }

        let data = try Data(contentsOf: jsonURL)
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let arr = obj["transcription"] as? [[String: Any]] else { return [] }
        var segs: [Segment] = []
        for item in arr {
            let offsets = item["offsets"] as? [String: Any]
            let fromMs = (offsets?["from"] as? NSNumber)?.doubleValue ?? 0
            let toMs = (offsets?["to"] as? NSNumber)?.doubleValue ?? fromMs
            let text = Self.stripNonSpeech(item["text"] as? String ?? "").trimmingCharacters(in: .whitespaces)
            if !text.isEmpty { segs.append(Segment(start: fromMs / 1000.0, end: toMs / 1000.0, text: text)) }
        }
        return segs
    }

    /// Interleaves two speakers' segments by start time into a labeled transcript.
    static func labeledTranscript(you: [Segment], them: [Segment]) -> String {
        let tagged: [(String, Segment)] = you.map { ("You", $0) } + them.map { ("Them", $0) }
        let sorted = tagged.sorted { $0.1.start < $1.1.start }
        var lines: [String] = []
        var current: String?
        var buf: [String] = []
        func flush() {
            if let c = current, !buf.isEmpty { lines.append("\(c): \(buf.joined(separator: " "))") }
            buf = []
        }
        for (spk, seg) in sorted {
            if spk != current { flush(); current = spk }
            buf.append(seg.text)
        }
        flush()
        return lines.joined(separator: "\n\n")
    }

    // MARK: - Language resolution

    /// Whisper's auto-detect is unreliable on music/noise — it will confidently
    /// pick an exotic language and then hallucinate a repeated script (the classic
    /// "garbage" transcript). When the user leaves language on "auto", detect it
    /// first and only trust a result that's one of our supported languages;
    /// anything else falls back to English so we never emit a bogus script.
    private func resolveLanguage(_ configured: String, binary: String, model: String, wavPath: String) -> String {
        guard configured == "auto" else { return configured }
        guard let detected = detectLanguage(binary: binary, model: model, wavPath: wavPath) else { return "en" }
        return Languages.all.contains { $0.code == detected } ? detected : "en"
    }

    /// Runs whisper's fast language-detect pass (processes ~30s, then exits).
    private func detectLanguage(binary: String, model: String, wavPath: String) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: binary)
        p.arguments = ["-m", model, "-f", wavPath, "-dl",
                       "-t", "\(max(4, ProcessInfo.processInfo.activeProcessorCount - 2))"]
        let out = Pipe(); let err = Pipe()
        p.standardOutput = out; p.standardError = err
        do { try p.run() } catch { return nil }
        let (o, e) = drainPipes(out, err)
        p.waitUntilExit()
        let text = (String(data: o, encoding: .utf8) ?? "") + (String(data: e, encoding: .utf8) ?? "")
        // e.g. "auto-detected language: en (p = 0.98)"
        guard let r = text.range(of: #"auto-detected language:\s*([a-z]{2,3})"#, options: .regularExpression)
        else { return nil }
        return String(text[r]).split(separator: ":").last?
            .trimmingCharacters(in: .whitespaces).split(separator: " ").first.map(String.init)
    }

    private func runWhisper(audioURL: URL, modelPath: String? = nil, smartLang: Bool = false) -> Result<String, Error> {
        let binary = Settings.shared.binaryPath
        let model = modelPath ?? Settings.shared.modelPath
        let fm = FileManager.default

        VozLog.log("runWhisper binary=\(binary) model=\(model)")
        guard fm.isExecutableFile(atPath: binary) else {
            VozLog.log("binary NOT executable at \(binary)")
            return .failure(TranscriberError.binaryMissing(binary))
        }
        guard fm.fileExists(atPath: model) else {
            VozLog.log("model NOT found at \(model)")
            return .failure(TranscriberError.modelMissing(model))
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        // Files can be music/varied, where auto-detect misfires — resolve smartly.
        // Live dictation stays on the plain setting for speed.
        let lang = smartLang
            ? resolveLanguage(Settings.shared.language, binary: binary, model: model, wavPath: audioURL.path)
            : Settings.shared.language
        var args = [
            "-m", model,                       // model file
            "-f", audioURL.path,               // input audio
            "-l", lang,                        // language code, or "auto" to detect
            "-nt",                             // no timestamps in output
            "-np",                             // no progress / system prints
            "-t", "\(max(4, ProcessInfo.processInfo.activeProcessorCount - 2))", // threads
        ]
        // Custom vocabulary → Whisper's "initial prompt" biases recognition
        // toward these words (names, jargon, acronyms). Fully local.
        let vocab = Settings.shared.customVocabulary.trimmingCharacters(in: .whitespacesAndNewlines)
        if !vocab.isEmpty {
            args += ["--prompt", vocab]
        }
        process.arguments = args

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        do {
            try process.run()
        } catch {
            return .failure(TranscriberError.processFailed(error.localizedDescription))
        }
        // Drain stdout/stderr CONCURRENTLY, before waiting. whisper prints the
        // whole transcript to stdout; on a long file that exceeds the ~64 KB pipe
        // buffer, so reading only after waitUntilExit() would deadlock (the child
        // blocks writing, we block waiting). Read on background queues instead.
        let (outData, errData) = drainPipes(stdout, stderr)
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let msg = String(data: errData, encoding: .utf8) ?? "exit \(process.terminationStatus)"
            VozLog.log("whisper exit=\(process.terminationStatus) stderr=\"\(msg.suffix(300))\"")
            return .failure(TranscriberError.processFailed(msg))
        }

        let raw = String(data: outData, encoding: .utf8) ?? ""
        let cleaned = Self.clean(raw)
        VozLog.log("whisper exit=0 rawLen=\(raw.count) cleaned=\"\(cleaned.prefix(120))\"")
        return .success(cleaned)
    }

    /// Tidies whisper output: strips any stray "[..]" timestamps, collapses
    /// whitespace, and trims. With `-nt` there usually aren't timestamps, but we
    /// stay defensive across whisper.cpp versions.
    static func clean(_ raw: String) -> String {
        let lines = raw.split(separator: "\n").map { line -> String in
            var s = String(line)
            if let range = s.range(of: #"^\s*\[[^\]]*\]\s*"#, options: .regularExpression) {
                s.removeSubrange(range)
            }
            return s.trimmingCharacters(in: .whitespaces)
        }
        let joined = lines.joined(separator: " ")
        return stripNonSpeech(joined)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Removes whisper.cpp's non-speech annotations that sometimes appear on
    /// silent stretches or noise — e.g. [BLANK_AUDIO], [MUSIC], (silence),
    /// [INAUDIBLE]. These are bracketed/parenthesised all-caps-ish tags, never
    /// something the user actually dictated, so they're safe to drop.
    static func stripNonSpeech(_ s: String) -> String {
        var out = s
        // Bracketed all-caps / underscore tokens: [BLANK_AUDIO], [ MUSIC ], [NOISE]
        out = out.replacingOccurrences(
            of: #"\[[ \t]*[A-Z][A-Z0-9_ ]*[ \t]*\]"#, with: "", options: .regularExpression)
        // Common parenthesised markers, any case: (silence), (blank_audio), (inaudible)
        out = out.replacingOccurrences(
            of: #"(?i)\([ \t]*(silence|blank[_ ]?audio|inaudible|music|noise|applause|laughter)[ \t]*\)"#,
            with: "", options: .regularExpression)
        return out
    }
}
