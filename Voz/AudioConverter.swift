//
//  AudioConverter.swift
//  Voz
//
//  Converts any dropped audio/video file into the 16 kHz mono WAV that
//  whisper.cpp needs — using Apple's own AVFoundation, so there is NO external
//  ffmpeg dependency to install or bundle. Everything is local; nothing uploads.
//
//  AVFoundation decodes the formats macOS supports natively (mp3, m4a/aac,
//  wav, aiff, caf, flac, and the audio track of mov/mp4/m4v). Exotic containers
//  (ogg/opus/mkv/webm) aren't covered — those are rare for dictation/meetings.
//

import Foundation
import AVFoundation

enum AudioConverterError: LocalizedError {
    case noAudioTrack
    case conversionFailed(String)

    var errorDescription: String? {
        switch self {
        case .noAudioTrack:
            return "That file doesn't contain an audio track Voz can read."
        case .conversionFailed(let m):
            return "Couldn't read that file:\n\(m)"
        }
    }
}

enum AudioConverter {

    /// Target format whisper.cpp expects.
    static let targetSampleRate = 16_000

    /// Audio/video containers we accept for file import (what AVFoundation can
    /// decode natively on macOS).
    static let supportedExtensions: Set<String> = [
        "wav", "mp3", "m4a", "aac", "aiff", "aif", "caf", "flac", "alac",
        "mov", "mp4", "m4v", "3gp", "m4b",
    ]

    static func isSupported(_ url: URL) -> Bool {
        supportedExtensions.contains(url.pathExtension.lowercased())
    }

    /// Converts `input` to a temp 16 kHz mono 16-bit WAV and returns its URL.
    /// The caller is responsible for deleting the returned file when done.
    static func convertToWav(_ input: URL) throws -> URL {
        let samples = try decodePCM16k(input)
        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("voz-conv-\(UUID().uuidString).wav")
        try writeWav(samples, sampleRate: targetSampleRate, to: out)
        return out
    }

    /// Mixes one or more audio files into a single 16 kHz mono WAV (for meeting
    /// capture: system audio + mic). With one input this is just a conversion.
    static func mixToWav(_ inputs: [URL]) throws -> URL {
        let existing = inputs.filter { FileManager.default.fileExists(atPath: $0.path) }
        guard !existing.isEmpty else { throw AudioConverterError.conversionFailed("no audio recorded") }
        if existing.count == 1 { return try convertToWav(existing[0]) }

        let decoded = try existing.map { try decodePCM16k($0) }
        let mixed = mixSamples(decoded)
        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("voz-meeting-mix-\(UUID().uuidString).wav")
        try writeWav(mixed, sampleRate: targetSampleRate, to: out)
        return out
    }

    // MARK: - Decoding

    /// Decodes any supported file to 16 kHz mono 16-bit PCM samples. AVAssetReader
    /// resamples/downmixes for us via the output settings. Blocking — call off the
    /// main thread.
    static func decodePCM16k(_ input: URL) throws -> [Int16] {
        let asset = AVURLAsset(url: input)
        guard let track = asset.tracks(withMediaType: .audio).first else {
            throw AudioConverterError.noAudioTrack
        }
        let reader: AVAssetReader
        do { reader = try AVAssetReader(asset: asset) }
        catch { throw AudioConverterError.conversionFailed(error.localizedDescription) }

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: Double(targetSampleRate),
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else {
            throw AudioConverterError.conversionFailed("unsupported audio encoding")
        }
        reader.add(output)
        guard reader.startReading() else {
            throw AudioConverterError.conversionFailed(reader.error?.localizedDescription ?? "couldn't start reading")
        }

        var samples: [Int16] = []
        while let buf = output.copyNextSampleBuffer() {
            if let block = CMSampleBufferGetDataBuffer(buf) {
                let len = CMBlockBufferGetDataLength(block)
                if len > 0 {
                    var bytes = [UInt8](repeating: 0, count: len)
                    CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: len, destination: &bytes)
                    bytes.withUnsafeBytes { raw in
                        samples.append(contentsOf: raw.bindMemory(to: Int16.self))
                    }
                }
            }
            CMSampleBufferInvalidate(buf)
        }
        if reader.status == .failed {
            throw AudioConverterError.conversionFailed(reader.error?.localizedDescription ?? "decode failed")
        }
        return samples
    }

    /// Sums multiple mono streams into one, padding shorter ones with silence and
    /// clamping to avoid overflow/clipping artifacts.
    private static func mixSamples(_ streams: [[Int16]]) -> [Int16] {
        let n = streams.map(\.count).max() ?? 0
        guard n > 0 else { return [] }
        var out = [Int16](repeating: 0, count: n)
        for i in 0..<n {
            var acc = 0
            for s in streams where i < s.count { acc += Int(s[i]) }
            out[i] = Int16(max(-32_768, min(32_767, acc)))
        }
        return out
    }

    // MARK: - WAV output

    /// Writes 16-bit mono PCM samples as a canonical 44-byte-header WAV file.
    private static func writeWav(_ samples: [Int16], sampleRate: Int, to url: URL) throws {
        let channels = 1, bitsPerSample = 16
        let byteRate = sampleRate * channels * bitsPerSample / 8
        let blockAlign = channels * bitsPerSample / 8
        let dataBytes = samples.count * MemoryLayout<Int16>.size

        func u32(_ v: UInt32) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
        func u16(_ v: UInt16) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }

        var d = Data(capacity: 44 + dataBytes)
        d.append(Data("RIFF".utf8)); d.append(u32(UInt32(36 + dataBytes))); d.append(Data("WAVE".utf8))
        d.append(Data("fmt ".utf8)); d.append(u32(16)); d.append(u16(1))   // PCM
        d.append(u16(UInt16(channels)))
        d.append(u32(UInt32(sampleRate))); d.append(u32(UInt32(byteRate)))
        d.append(u16(UInt16(blockAlign))); d.append(u16(UInt16(bitsPerSample)))
        d.append(Data("data".utf8)); d.append(u32(UInt32(dataBytes)))
        samples.withUnsafeBytes { d.append(contentsOf: $0) }
        try d.write(to: url)
    }
}
