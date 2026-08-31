//
//  MeetingRecorder.swift
//  Voz
//
//  Captures a meeting entirely on-device: the other participants' audio (system
//  audio, via ScreenCaptureKit — no bot joins the call) plus your microphone.
//  Each source is written to its own file; they're mixed afterwards with ffmpeg
//  and transcribed locally by whisper. Requires Screen Recording permission
//  (macOS gates system-audio capture behind it) + Microphone permission.
//

import AVFoundation
import ScreenCaptureKit

final class MeetingRecorder: NSObject, SCStreamOutput, SCStreamDelegate {

    private var stream: SCStream?
    private var systemFile: AVAudioFile?
    private(set) var systemURL: URL?
    private let mic = AudioRecorder()
    private(set) var micURL: URL?
    private let audioQueue = DispatchQueue(label: "voz.meeting.systemaudio")

    /// True if system-audio capture is running (mic may run regardless).
    private(set) var capturingSystem = false

    // MARK: - Start / stop

    /// Starts mic + (best-effort) system-audio capture. Returns whether system
    /// audio was captured; mic capture is attempted either way.
    @discardableResult
    func start() async -> Bool {
        // Mic first — reuses the same recorder as dictation (16 kHz mono WAV).
        if mic.start() { micURL = mic.currentFileURL }

        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            guard let display = content.displays.first else { return false }

            let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
            let config = SCStreamConfiguration()
            config.capturesAudio = true
            config.excludesCurrentProcessAudio = true      // don't capture Voz's own sounds
            config.sampleRate = 48_000
            config.channelCount = 2
            // We only want audio — keep the video path tiny.
            config.width = 2
            config.height = 2
            config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
            config.queueDepth = 5

            let s = SCStream(filter: filter, configuration: config, delegate: self)
            try s.addStreamOutput(self, type: .audio, sampleHandlerQueue: audioQueue)
            try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: audioQueue) // required; frames ignored
            try await s.startCapture()
            stream = s
            capturingSystem = true
            return true
        } catch {
            NSLog("Voz: system-audio capture unavailable: \(error.localizedDescription)")
            capturingSystem = false
            return false
        }
    }

    /// Stops capture and returns the recorded source files (system may be nil).
    func stop() async -> (system: URL?, mic: URL?) {
        if let s = stream { try? await s.stopCapture() }
        stream = nil
        audioQueue.sync { systemFile = nil }   // flush/close the file
        let m = mic.stop()
        capturingSystem = false
        return (systemURL, m)
    }

    // MARK: - SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, sampleBuffer.isValid else { return }   // ignore the tiny video frames
        writeSystemAudio(sampleBuffer)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        NSLog("Voz: meeting stream stopped: \(error.localizedDescription)")
    }

    // MARK: - Writing system audio to a WAV

    private func writeSystemAudio(_ sampleBuffer: CMSampleBuffer) {
        guard let fmtDesc = sampleBuffer.formatDescription,
              let asbdPtr = CMAudioFormatDescriptionGetStreamBasicDescription(fmtDesc) else { return }
        var asbd = asbdPtr.pointee
        guard let format = AVAudioFormat(streamDescription: &asbd) else { return }

        if systemFile == nil {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("voz-meeting-sys-\(UUID().uuidString).wav")
            systemURL = url
            systemFile = try? AVAudioFile(forWriting: url, settings: format.settings,
                                          commonFormat: format.commonFormat, interleaved: format.isInterleaved)
        }
        guard let file = systemFile else { return }

        let frames = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
        guard frames > 0, let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return }
        pcm.frameLength = frames
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer, at: 0, frameCount: Int32(frames), into: pcm.mutableAudioBufferList)
        guard status == noErr else { return }
        try? file.write(from: pcm)
    }
}
