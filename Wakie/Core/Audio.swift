//
//  Audio.swift
//  Wakie
//
//  Audio playback for previews and dance music, plus importing songs from Files.
//

import AVFoundation
import Foundation
import Observation

/// Configures and (de)activates the shared audio session away from the main thread,
/// so audio setup can never freeze the UI.
nonisolated enum AudioSessionControl {
    @concurrent
    static func activate(_ category: AVAudioSession.Category,
                         mode: AVAudioSession.Mode = .default,
                         options: AVAudioSession.CategoryOptions = []) async throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(category, mode: mode, options: options)
        _ = try await session.activate()
    }

    /// Activates the session, then creates and starts the player, all off the main thread.
    @concurrent
    static func startPlayer(url: URL, loops: Bool, delegate: AVAudioPlayerDelegate & Sendable) async throws -> sending AVAudioPlayer {
        try await activate(.playback)
        let player = try AVAudioPlayer(contentsOf: url)
        player.delegate = delegate
        player.numberOfLoops = loops ? -1 : 0
        player.prepareToPlay()
        player.play()
        return player
    }

    /// Activates a record session, then creates the recorder and starts recording,
    /// all off the main thread (starting a recording can activate the session itself).
    @concurrent
    static func startRecorder(url: URL) async throws -> sending AVAudioRecorder {
        try await activate(.playAndRecord, options: [.defaultToSpeaker])
        let recorder = try AVAudioRecorder(url: url, settings: [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 44_100,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
        ])
        recorder.isMeteringEnabled = true
        guard recorder.prepareToRecord(), recorder.record() else {
            throw CocoaError(.fileWriteUnknown)
        }
        return recorder
    }

    @concurrent
    static func deactivate() async {
        _ = try? await AVAudioSession.sharedInstance().deactivate()
    }
}

/// Plays one audio file at a time. Activates the audio session asynchronously so
/// the main thread never blocks.
@Observable
final class AudioPreviewPlayer: NSObject, AVAudioPlayerDelegate {
    private(set) var playingURL: URL?
    @ObservationIgnored private var player: AVAudioPlayer?

    /// Plays `url`, or stops it if it's already playing.
    func toggle(_ url: URL, loops: Bool = false) {
        if playingURL == url {
            stop()
        } else {
            play(url, loops: loops)
        }
    }

    func play(_ url: URL, loops: Bool = false) {
        // Switch tracks without deactivating the session in between; a late deactivation
        // would make AVAudioPlayer re-activate it synchronously on the main thread.
        stopPlayer()
        playingURL = url
        Task {
            do {
                let player = try await AudioSessionControl.startPlayer(url: url, loops: loops, delegate: self)
                // Something else was requested while starting up: discard this one.
                guard playingURL == url else {
                    player.stop()
                    return
                }
                self.player = player
            } catch {
                print("Playback failed: \(error)")
                if playingURL == url { playingURL = nil }
            }
        }
    }

    func stop() {
        guard playingURL != nil || player != nil else { return }
        stopPlayer()
        Task {
            // Only deactivate if nothing started playing again in the meantime.
            guard playingURL == nil else { return }
            await AudioSessionControl.deactivate()
        }
    }

    private func stopPlayer() {
        player?.stop()
        player = nil
        playingURL = nil
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in self.stop() }
    }
}

/// Copies and converts audio the person picks in the Files app.
nonisolated enum AudioImporter {
    /// AlarmKit only plays custom sounds from here.
    static var alarmSoundsDirectory: URL {
        let url = URL.libraryDirectory.appending(path: "Sounds", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static var danceMusicDirectory: URL {
        let url = URL.documentsDirectory.appending(path: "DanceMusic", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Alarm sounds must be under 30 seconds, so keep a little margin.
    private static let maxAlarmSeconds: Double = 29

    /// Converts any readable audio file into an alarm-ready CAF (16-bit linear PCM,
    /// trimmed to 29 s) in Library/Sounds. Returns the new file's name.
    static func makeAlarmSound(from source: URL) throws -> String {
        let accessing = source.startAccessingSecurityScopedResource()
        defer { if accessing { source.stopAccessingSecurityScopedResource() } }

        let input = try AVAudioFile(forReading: source)
        let format = input.processingFormat
        let destination = uniqueURL(in: alarmSoundsDirectory, base: source.deletingPathExtension().lastPathComponent, ext: "caf")
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: min(format.channelCount, 2),
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        do {
            let output = try AVAudioFile(forWriting: destination, settings: settings,
                                         commonFormat: format.commonFormat, interleaved: format.isInterleaved)
            let chunk: AVAudioFrameCount = 32_768
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk) else {
                throw CocoaError(.fileWriteUnknown)
            }
            let limit = AVAudioFramePosition(format.sampleRate * maxAlarmSeconds)
            var written: AVAudioFramePosition = 0
            while written < limit {
                let wanted = AVAudioFrameCount(min(AVAudioFramePosition(chunk), limit - written))
                try input.read(into: buffer, frameCount: wanted)
                if buffer.frameLength == 0 { break }
                try output.write(from: buffer)
                written += AVAudioFramePosition(buffer.frameLength)
            }
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
        return destination.lastPathComponent
    }

    /// Copies a song as-is for Shaky-Shaky's dance music. Returns the new file's name.
    static func copyDanceSong(from source: URL) throws -> String {
        let accessing = source.startAccessingSecurityScopedResource()
        defer { if accessing { source.stopAccessingSecurityScopedResource() } }
        let destination = uniqueURL(in: danceMusicDirectory,
                                    base: source.deletingPathExtension().lastPathComponent,
                                    ext: source.pathExtension.isEmpty ? "m4a" : source.pathExtension)
        try FileManager.default.copyItem(at: source, to: destination)
        return destination.lastPathComponent
    }

    /// "My Song.mp3" -> "My Song", for display.
    static func title(forFile file: String) -> String {
        (file as NSString).deletingPathExtension
    }

    private static func uniqueURL(in directory: URL, base: String, ext: String) -> URL {
        let clean = base.replacingOccurrences(of: "/", with: "-").trimmingCharacters(in: .whitespaces)
        let name = clean.isEmpty ? "Sound" : clean
        var candidate = directory.appending(path: "\(name).\(ext)")
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path()) {
            candidate = directory.appending(path: "\(name) \(n).\(ext)")
            n += 1
        }
        return candidate
    }
}
