//
//  AudioRecorder.swift
//  Voz
//
//  Captures microphone audio to a temporary .wav file in the exact format
//  whisper.cpp expects: 16 kHz, mono, 16-bit PCM. AVAudioRecorder writes the
//  WAV container for us, so no manual buffer wrangling is needed.
//

import AVFoundation

final class AudioRecorder: NSObject, AVAudioRecorderDelegate {
    private var recorder: AVAudioRecorder?
    private(set) var currentFileURL: URL?

    /// Why a permission check failed, so callers can react proportionately.
    enum MicAccess {
        /// Granted — go ahead.
        case granted
        /// The user was just shown the system prompt and chose Deny. They know
        /// exactly what they did a second ago; don't drag them into Settings.
        case justDenied
        /// Already denied or restricted from an earlier launch. macOS will never
        /// prompt again, so the *only* way forward is the Settings pane — which
        /// means telling the user to go there is useless. Take them there.
        case previouslyDenied
    }

    /// Requests mic permission if needed, then reports the outcome on the main thread.
    func ensurePermission(_ done: @escaping (MicAccess) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            done(.granted)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { ok in
                DispatchQueue.main.async { done(ok ? .granted : .justDenied) }
            }
        default:
            done(.previouslyDenied)
        }
    }

    /// Starts recording to a fresh temp file. Returns false if it couldn't start.
    @discardableResult
    func start() -> Bool {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("voz-\(UUID().uuidString).wav")
        currentFileURL = url

        // whisper.cpp wants 16 kHz mono 16-bit PCM WAV.
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatLinearPCM),
            AVSampleRateKey: 16_000.0,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]

        do {
            let rec = try AVAudioRecorder(url: url, settings: settings)
            rec.delegate = self
            rec.isMeteringEnabled = true   // for the live voice-bar HUD
            guard rec.record() else { return false }
            recorder = rec
            return true
        } catch {
            NSLog("Voz: failed to start recording: \(error)")
            return false
        }
    }

    /// Stops recording and returns the finished file URL (nil if nothing recorded).
    func stop() -> URL? {
        recorder?.stop()
        let url = currentFileURL
        recorder = nil
        if let url = url {
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? nil
            VozLog.log("recorded file \(url.path) size=\(size ?? -1) bytes")
        }
        return url
    }

    var isRecording: Bool { recorder?.isRecording ?? false }

    /// Current mic loudness as 0…1, for driving the live voice-bar HUD.
    /// Maps AVAudioRecorder's dB average power (~-50…0) onto a linear 0…1.
    func currentLevel() -> Float {
        guard let r = recorder, r.isRecording else { return 0 }
        r.updateMeters()
        let db = r.averagePower(forChannel: 0)      // −160…0 dBFS
        let floorDb: Float = -45
        guard db > floorDb else { return 0 }
        return min(1, (db - floorDb) / -floorDb)
    }
}
