//
//  BlahBlahView.swift
//  Wakie
//
//  Talk out loud. Only time when the microphone hears speech-level audio counts,
//  and the recording is saved to the Blah-Blah list in Settings.
//

import SwiftUI
import AVFoundation

@Observable
final class VoiceRecorder {
    enum Phase: Equatable { case idle, recording, done, denied, failed }

    let target: Double
    private(set) var phase: Phase = .idle
    private(set) var talkedSeconds: Double = 0
    private(set) var isTalking = false
    /// Recent loudness samples (0...1) for the waveform.
    private(set) var levels: [CGFloat] = Array(repeating: 0.05, count: 36)

    @ObservationIgnored private var recorder: AVAudioRecorder?
    @ObservationIgnored private var meterTask: Task<Void, Never>?
    @ObservationIgnored private var fileURL: URL?

    /// Average power (dBFS) above which we treat the input as someone talking.
    private let speechThreshold: Float = -35

    init(target: Double) {
        self.target = target
    }

    var level: CGFloat { levels.last ?? 0 }

    func start() async {
        guard phase == .idle else { return }
        guard await AVAudioApplication.requestRecordPermission() else {
            phase = .denied
            return
        }
        do {
            // Configured off the main thread with the async API, so the UI never stalls.
            try await AudioSessionControl.activate(.playAndRecord, options: [.defaultToSpeaker])

            let stamp = Date.now.formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false).timeSeparator(.omitted))
            let url = AppModel.recordingsDirectory.appending(path: "BlahBlah-\(stamp).m4a")
            let recorder = try AVAudioRecorder(url: url, settings: [
                AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
                AVSampleRateKey: 44_100,
                AVNumberOfChannelsKey: 1,
                AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
            ])
            recorder.isMeteringEnabled = true
            guard recorder.record() else {
                phase = .failed
                return
            }
            self.recorder = recorder
            fileURL = url
            phase = .recording
            meterTask = Task { [weak self] in
                var last = ContinuousClock.now
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(100))
                    let now = ContinuousClock.now
                    let elapsed = now - last
                    last = now
                    self?.tick(Double(elapsed.components.attoseconds) / 1e18 + Double(elapsed.components.seconds))
                }
            }
        } catch {
            print("Recording failed: \(error)")
            phase = .failed
        }
    }

    private func tick(_ dt: Double) {
        guard phase == .recording, let recorder else { return }
        recorder.updateMeters()
        let power = recorder.averagePower(forChannel: 0)
        // Map -60...0 dB onto 0...1 for the waveform.
        let normalized = CGFloat(max(0, min(1, (power + 60) / 60)))
        levels.removeFirst()
        levels.append(max(0.05, normalized))
        isTalking = power > speechThreshold
        if isTalking {
            talkedSeconds = min(target, talkedSeconds + dt)
        }
        if talkedSeconds >= target {
            finish()
        }
    }

    /// Stops and keeps the recording.
    private func finish() {
        meterTask?.cancel()
        recorder?.stop()
        recorder = nil
        isTalking = false
        phase = .done
        Task { await AudioSessionControl.deactivate() }
    }

    /// Stops and throws away an unfinished recording.
    func cancel() {
        meterTask?.cancel()
        guard phase == .recording else { return }
        recorder?.stop()
        recorder = nil
        if let fileURL { try? FileManager.default.removeItem(at: fileURL) }
        phase = .idle
        Task { await AudioSessionControl.deactivate() }
    }
}

struct BlahBlahView: View {
    let onComplete: () -> Void

    @Environment(AppModel.self) private var model
    @State private var recorder: VoiceRecorder

    init(seconds: Int, onComplete: @escaping () -> Void) {
        self.onComplete = onComplete
        _recorder = State(initialValue: VoiceRecorder(target: Double(seconds)))
    }

    var body: some View {
        VStack(spacing: 20) {
            Spacer(minLength: 0)
            mascotWithRings
            VStack(spacing: 6) {
                Text(headline)
                    .font(.wakie(28, .black))
                    .foregroundStyle(Theme.ink)
                    .multilineTextAlignment(.center)
                    .contentTransition(.numericText())
                Text(subtitle)
                    .font(.wakie(15, .semibold))
                    .foregroundStyle(Theme.inkSecondary)
                    .multilineTextAlignment(.center)
            }
            Waveform(levels: recorder.levels, isActive: recorder.isTalking)
                .frame(height: 70)
            ProgressView(value: recorder.talkedSeconds, total: recorder.target)
                .tint(Theme.purple)
                .scaleEffect(y: 2)
                .padding(.horizontal, 30)
                .accessibilityLabel("Talking progress")
            if recorder.phase == .denied, let url = URL(string: UIApplication.openSettingsURLString) {
                Link("Allow microphone in Settings", destination: url)
                    .font(.wakie(15, .bold))
                    .foregroundStyle(Theme.purple)
            }
            Spacer(minLength: 0)
        }
        .task { await recorder.start() }
        .onDisappear { recorder.cancel() }
        .onChange(of: recorder.phase) { _, phase in
            if phase == .done {
                model.refreshRecordings()
                onComplete()
            }
        }
    }

    private var headline: String {
        switch recorder.phase {
        case .recording:
            let left = Int((recorder.target - recorder.talkedSeconds).rounded(.up))
            return recorder.isTalking ? "Keep going!\n\(left)s left" : "Talk for\n\(left) more seconds"
        case .denied: return "Microphone needed"
        case .failed: return "Couldn't start recording"
        default: return "Talk for\n\(Int(recorder.target)) seconds"
        }
    }

    private var subtitle: String {
        switch recorder.phase {
        case .recording: recorder.isTalking ? "I'm listening… tell me about your dreams" : "The timer pauses when you go quiet"
        case .denied: "Wakie needs the microphone to hear you talk."
        case .failed: "Something went wrong with the microphone."
        default: "Say anything. Sing, ramble, plan your day."
        }
    }

    private var mascotWithRings: some View {
        ZStack {
            ForEach(0..<4, id: \.self) { ring in
                Circle()
                    .stroke(Theme.lavender.opacity(0.5 - Double(ring) * 0.1), lineWidth: 10)
                    .frame(width: 150 + CGFloat(ring) * 44, height: 150 + CGFloat(ring) * 44)
                    .scaleEffect(1 + recorder.level * 0.12 * CGFloat(ring + 1))
            }
            MascotImage(mission: .blahBlah, size: 170)
        }
        .frame(height: 290)
        .animation(.easeOut(duration: 0.15), value: recorder.level)
    }
}

/// Symmetric bar waveform drawn from recent loudness samples.
struct Waveform: View {
    let levels: [CGFloat]
    var isActive: Bool

    var body: some View {
        GeometryReader { geo in
            let spacing: CGFloat = 4
            let barWidth = max(2, (geo.size.width - spacing * CGFloat(levels.count - 1)) / CGFloat(levels.count))
            HStack(alignment: .center, spacing: spacing) {
                ForEach(levels.indices, id: \.self) { index in
                    Capsule()
                        .fill(isActive ? Theme.purple : Theme.purple.opacity(0.45))
                        .frame(width: barWidth, height: max(6, levels[index] * geo.size.height))
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .animation(.easeOut(duration: 0.1), value: levels)
        .accessibilityHidden(true)
    }
}
