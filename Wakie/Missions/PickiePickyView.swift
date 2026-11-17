//
//  PickiePickyView.swift
//  Wakie
//
//  Find a random household item and show it to the back camera. Vision's built-in
//  image classifier has to recognise it for a few frames in a row.
//

import SwiftUI
import AVFoundation

@Observable
final class ObjectFinder {
    private(set) var item: PickItem
    private(set) var bestGuess: String?
    private(set) var confidence: Float = 0
    private(set) var isFound = false
    private var streak = 0

    /// Minimum classifier confidence for a frame to count as a sighting.
    private let threshold: Float = 0.3
    /// Consecutive sightings needed (~0.75 s at 4 fps) so a lucky frame doesn't count.
    private let requiredStreak = 3

    /// Broad scene labels that aren't useful as "I see…" feedback.
    private static let genericLabels: Set<String> = [
        "indoor", "outdoor", "structure", "people", "adult", "interior_room", "room", "machine",
        "material", "textile", "wood_processed", "furniture", "consumer_electronics", "liquid", "food",
    ]

    init(item: PickItem) {
        self.item = item
    }

    func reset(to item: PickItem) {
        self.item = item
        streak = 0
        confidence = 0
        bestGuess = nil
    }

    func ingest(_ labels: [String: Float]) {
        guard !isFound else { return }
        let score = item.labels.compactMap { labels[$0] }.max() ?? 0
        confidence = score
        streak = score >= threshold ? streak + 1 : max(0, streak - 1)
        if streak >= requiredStreak { isFound = true }

        bestGuess = labels
            .filter { !Self.genericLabels.contains($0.key) }
            .max { $0.value < $1.value }
            .map { $0.key.replacingOccurrences(of: "_", with: " ") }
    }
}

struct PickiePickyView: View {
    let onComplete: () -> Void
    let onFallback: () -> Void

    @Environment(AppModel.self) private var model
    @State private var camera = CameraPipeline(position: .back)
    @State private var classifier = ObjectClassifier()
    @State private var finder: ObjectFinder
    @State private var status: CameraStatus = .starting
    @State private var device: AVCaptureDevice?
    @State private var swapsLeft = 2

    init(item: PickItem, onComplete: @escaping () -> Void, onFallback: @escaping () -> Void) {
        self.onComplete = onComplete
        self.onFallback = onFallback
        _finder = State(initialValue: ObjectFinder(item: item))
    }

    var body: some View {
        VStack(spacing: 16) {
            targetCard
            CameraCard(camera: camera, device: device, status: status, onFallback: onFallback) {
                scanFrame
            }
            .frame(maxHeight: .infinity)
            feedback
            Button {
                swapsLeft -= 1
                finder.reset(to: model.randomPickItem(excluding: finder.item))
            } label: {
                Label("Different item (\(swapsLeft) left)", systemImage: "shuffle")
                    .font(.wakie(15, .bold))
                    .foregroundStyle(Theme.ink)
                    .padding(.horizontal, 18)
                    .frame(height: 44)
                    .background(Capsule().fill(Theme.lavenderPill))
            }
            .buttonStyle(PressableStyle())
            .disabled(swapsLeft == 0 || model.pickItems.count < 2)
            .opacity(swapsLeft == 0 || model.pickItems.count < 2 ? 0.5 : 1)
        }
        .task {
            let finder = finder
            let classifier = classifier
            camera.frameHandler = { buffer in
                guard let labels = classifier.process(buffer) else { return }
                Task { @MainActor in finder.ingest(labels) }
            }
            (status, device) = await camera.start()
        }
        .onDisappear { camera.stop() }
        .onChange(of: finder.isFound) { _, found in
            if found {
                camera.stop()
                onComplete()
            }
        }
    }

    private var targetCard: some View {
        HStack(spacing: 14) {
            Text(finder.item.emoji)
                .font(.system(size: 46))
            VStack(alignment: .leading, spacing: 0) {
                Text("Go find a")
                    .font(.wakie(14, .semibold))
                    .foregroundStyle(Theme.inkSecondary)
                Text(finder.item.name)
                    .font(.wakie(30, .black))
                    .foregroundStyle(Theme.ink)
                    .contentTransition(.opacity)
            }
            Spacer()
            Image(systemName: "magnifyingglass")
                .font(.system(size: 24, weight: .bold))
                .foregroundStyle(Theme.purple)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .wakieCard(radius: 26)
        .accessibilityElement(children: .combine)
    }

    /// Corner brackets that fill with yellow as confidence grows.
    private var scanFrame: some View {
        RoundedRectangle(cornerRadius: 28, style: .continuous)
            .stroke(
                Theme.yellow.opacity(0.35 + Double(min(finder.confidence * 2, 1)) * 0.65),
                style: StrokeStyle(lineWidth: 5, lineCap: .round, dash: [44, 120])
            )
            .padding(40)
            .animation(.easeOut(duration: 0.2), value: finder.confidence)
            .allowsHitTesting(false)
    }

    private var feedback: some View {
        HStack(spacing: 8) {
            Image(systemName: finder.confidence >= 0.3 ? "checkmark.circle.fill" : "eye.fill")
                .foregroundStyle(finder.confidence >= 0.3 ? .green : Theme.purple)
            Text(feedbackText)
                .font(.wakie(15, .bold))
                .foregroundStyle(Theme.ink)
                .lineLimit(1)
        }
        .padding(.horizontal, 18)
        .frame(height: 42)
        .wakieCard(radius: 21)
    }

    private var feedbackText: String {
        guard status == .running else { return "Point the camera at the item" }
        if finder.confidence >= 0.3 { return "That's it! Hold it steady…" }
        if let guess = finder.bestGuess { return "Hmm, I see: \(guess)" }
        return "Show me the \(finder.item.name.lowercased())"
    }
}
