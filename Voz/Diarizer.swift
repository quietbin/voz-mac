//
//  Diarizer.swift
//  Voz
//
//  Speaker diarization ("who said what") for meetings, fully local via
//  sherpa-onnx. The two ONNX models are BUNDLED with the app (no download), so
//  it just works. We shell out to the sherpa-onnx diarization binary, get back
//  speaker time-segments, and merge them with the whisper transcript by time.
//
//  The engine binary is auto-detected at ~/sherpa-onnx (built from source like
//  whisper.cpp). For a shipping build it would be bundled alongside the models.
//

import Foundation
import AVFoundation

struct SpeakerSegment {
    let start: Double
    let end: Double
    let speaker: String   // raw id, e.g. "speaker_00"
}

enum Diarizer {

    // Candidate locations for the sherpa-onnx diarization binary.
    static var binaryCandidates: [String] {
        let home = NSHomeDirectory()
        return [
            "\(home)/sherpa-onnx/build/bin/sherpa-onnx-offline-speaker-diarization",
            "/opt/homebrew/bin/sherpa-onnx-offline-speaker-diarization",
            "/usr/local/bin/sherpa-onnx-offline-speaker-diarization",
        ]
    }

    static var binaryPath: String? {
        binaryCandidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    // Bundled models.
    static var segmentationModel: String? { Bundle.main.path(forResource: "diarize-seg", ofType: "onnx") }
    static var embeddingModel: String? { Bundle.main.path(forResource: "diarize-embed", ofType: "onnx") }

    /// True when speaker labeling can run (engine present + models bundled).
    static var isAvailable: Bool {
        binaryPath != nil && segmentationModel != nil && embeddingModel != nil
    }

    /// Auto-mode clustering distance (only used when the speaker count is not
    /// set). Threshold clustering can't reliably guess the count, so setting the
    /// exact number of people is strongly preferred.
    static let clusterThreshold = 0.7

    /// Runs diarization on a 16 kHz mono WAV. If `numSpeakers` > 0, the engine is
    /// forced to exactly that many speakers (far more reliable than auto). Blocking.
    /// Lower distance → breaks on smaller voice changes. Used for turn detection
    /// ("just separate the responses") when we're not identifying individuals.
    static let changeThreshold = 0.5

    static func diarize(wavURL: URL, numSpeakers: Int = 0, threshold: Double? = nil) throws -> [SpeakerSegment] {
        guard let binary = binaryPath, let seg = segmentationModel, let emb = embeddingModel else {
            throw NSError(domain: "Voz.Diarizer", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Diarization engine or models not found."])
        }
        let clusterArg = numSpeakers > 0
            ? "--clustering.num-clusters=\(numSpeakers)"
            : "--clustering.cluster-threshold=\(threshold ?? clusterThreshold)"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = [
            "--segmentation.pyannote-model=\(seg)",
            "--embedding.model=\(emb)",
            clusterArg,
            "--segmentation.num-threads=\(max(2, ProcessInfo.processInfo.activeProcessorCount - 2))",
            "--embedding.num-threads=\(max(2, ProcessInfo.processInfo.activeProcessorCount - 2))",
            wavURL.path,
        ]
        let out = Pipe(); let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        _ = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        let text = String(data: data, encoding: .utf8) ?? ""
        return parse(text)
    }

    /// Parses lines like "3.963 -- 6.865 speaker_00".
    static func parse(_ text: String) -> [SpeakerSegment] {
        var segs: [SpeakerSegment] = []
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: " ").map(String.init)
            // <start> -- <end> speaker_xx
            guard parts.count >= 4, parts[1] == "--",
                  let s = Double(parts[0]), let e = Double(parts[2]) else { continue }
            let speaker = parts[3]
            guard speaker.hasPrefix("speaker") else { continue }
            segs.append(SpeakerSegment(start: s, end: e, speaker: speaker))
        }
        return segs
    }

    /// Merges whisper text segments with speaker segments into a labeled
    /// transcript: "Speaker 1: …\n\nSpeaker 2: …". Raw speaker ids are renumbered
    /// to Speaker 1, 2, 3… in order of first appearance.
    static func labeledTranscript(text textSegs: [Transcriber.Segment],
                                  speakers speakerSegs: [SpeakerSegment]) -> String {
        guard !speakerSegs.isEmpty else {
            return textSegs.map { $0.text }.joined(separator: " ")
        }
        var displayOrder: [String: Int] = [:]
        func displayName(_ raw: String) -> String {
            if displayOrder[raw] == nil { displayOrder[raw] = displayOrder.count + 1 }
            return "Speaker \(displayOrder[raw]!)"
        }

        var lines: [String] = []
        var current: String?
        var buf: [String] = []
        func flush() {
            if let c = current, !buf.isEmpty { lines.append("\(c): \(buf.joined(separator: " "))") }
            buf = []
        }
        for seg in textSegs {
            let raw = speaker(at: seg.start, in: speakerSegs)
            let name = raw.map(displayName) ?? (current ?? "Speaker 1")
            if name != current { flush(); current = name }
            buf.append(seg.text)
        }
        flush()
        return lines.joined(separator: "\n\n")
    }

    /// The speaker active at `time` (segment containing it, else nearest).
    private static func speaker(at time: Double, in segs: [SpeakerSegment]) -> String? {
        if let hit = segs.first(where: { time >= $0.start && time <= $0.end }) { return hit.speaker }
        return segs.min(by: { abs(midpoint($0) - time) < abs(midpoint($1) - time) })?.speaker
    }
    private static func midpoint(_ s: SpeakerSegment) -> Double { (s.start + s.end) / 2 }

    // MARK: - Channel-based labeling (mic = You, call = the others)

    /// RMS-energy envelope of a 16 kHz mono WAV, for bleed detection.
    struct EnergyEnvelope {
        let samples: [Float]
        let sampleRate: Double
        func rms(_ from: Double, _ to: Double) -> Float {
            let a = max(0, Int(from * sampleRate))
            let b = min(samples.count, Int(to * sampleRate))
            guard b > a else { return 0 }
            var sum: Float = 0
            for i in a..<b { sum += samples[i] * samples[i] }
            return (sum / Float(b - a)).squareRoot()
        }
    }

    static func loadEnvelope(_ url: URL) -> EnergyEnvelope? {
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        let fmt = file.processingFormat
        guard file.length > 0,
              let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(file.length)),
              (try? file.read(into: buf)) != nil,
              let ch = buf.floatChannelData else { return nil }
        let n = Int(buf.frameLength)
        return EnergyEnvelope(samples: Array(UnsafeBufferPointer(start: ch[0], count: n)),
                              sampleRate: fmt.sampleRate)
    }

    /// Builds a labeled transcript from the two channels.
    /// - mic segments → "You" (dropping bits where the call is clearly louder = bleed)
    /// - call segments → the others.
    ///
    /// When `labelIndividuals` is false (default, most reliable) the others are all
    /// "Them", but a NEW block starts whenever the responding voice changes — i.e.
    /// responses are separated without claiming to know who's who. When true, remote
    /// voices get "Speaker 1/2/3…" labels (needs the speaker count set to be useful).
    static func channelTranscript(youSegs: [Transcriber.Segment], youEnv: EnergyEnvelope?,
                                  themSegs: [Transcriber.Segment], themEnv: EnergyEnvelope?,
                                  themSpeakers: [SpeakerSegment],
                                  labelIndividuals: Bool) -> String {
        // (displayLabel, groupKey, start, text). groupKey breaks blocks even when
        // two remote turns share the "Them" label.
        var tagged: [(label: String, key: String, start: Double, text: String)] = []

        // You — gate out bleed (call louder than your mic in that window).
        for (i, seg) in youSegs.enumerated() {
            let end = (i + 1 < youSegs.count) ? youSegs[i + 1].start : seg.start + 3
            if let ye = youEnv, let te = themEnv {
                if te.rms(seg.start, end) > ye.rms(seg.start, end) * 1.2 { continue }   // bleed
            }
            tagged.append(("You", "You", seg.start, seg.text))
        }

        // Them — group breaks at each voice change (raw cluster id), even in "Them" mode.
        var order: [String: Int] = [:]
        for seg in themSegs {
            let raw = speaker(at: seg.start, in: themSpeakers) ?? "spk0"
            let label: String
            if labelIndividuals {
                if order[raw] == nil { order[raw] = order.count + 1 }
                label = "Speaker \(order[raw]!)"
            } else {
                label = "Them"
            }
            // In "Them" mode, keep a constant key so remote speech isn't broken
            // acoustically mid-sentence — the language model splits turns instead.
            let key = labelIndividuals ? "them:\(raw)" : "them"
            tagged.append((label, key, seg.start, seg.text))
        }

        // Merge by time, starting a new block whenever the group key changes.
        let sorted = tagged.sorted { $0.start < $1.start }
        var lines: [String] = []
        var currentKey: String?
        var currentLabel = ""
        var buf: [String] = []
        func flush() {
            if !buf.isEmpty { lines.append("\(currentLabel): \(buf.joined(separator: " "))") }
            buf = []
        }
        for t in sorted {
            if t.key != currentKey { flush(); currentKey = t.key; currentLabel = t.label }
            buf.append(t.text)
        }
        flush()
        return lines.joined(separator: "\n\n")
    }
}
