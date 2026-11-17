//
//  RingingView.swift
//  Wakie
//
//  Full-screen "Time to wake up!" screen shown while an alarm waits for its mission.
//

import SwiftUI
import AudioToolbox

struct RingingView: View {
    let session: WakeSession

    @Environment(AppModel.self) private var model
    @State private var missionStarted = false
    @State private var appeared = false
    @State private var canDismiss = false

    /// How long the alarm rings before the Dismiss button appears.
    private let dismissDelay: TimeInterval = 10

    var body: some View {
        Group {
            if missionStarted {
                MissionView(run: MissionRun(mission: session.mission, isPractice: false)) {
                    model.completeSession()
                }
                .transition(.move(edge: .bottom))
            } else {
                ringing
                    .transition(.opacity)
            }
        }
        .animation(.spring(duration: 0.5), value: missionStarted)
        .interactiveDismissDisabled()
        .task(id: missionStarted) {
            // Buzz until the mission starts, in case the system alarm was already silenced.
            while !missionStarted && !Task.isCancelled {
                AudioServicesPlaySystemSound(kSystemSoundID_Vibrate)
                try? await Task.sleep(for: .seconds(1.6))
            }
        }
        .task {
            // Offer a way out once the alarm has been ringing for a little while.
            let remaining = dismissDelay - Date.now.timeIntervalSince(session.startedAt)
            if remaining > 0 { try? await Task.sleep(for: .seconds(remaining)) }
            withAnimation(.spring(duration: 0.6)) { canDismiss = true }
        }
    }

    private var ringing: some View {
        ZStack {
            RingingBackground()
            FloatingNotes()
            VStack(spacing: 6) {
                Spacer(minLength: 0)
                MascotStage(mission: session.mission)
                    .scaleEffect(appeared ? 1 : 0.4)
                    .opacity(appeared ? 1 : 0)
                Text("Time to\nwake up!")
                    .font(.wakie(42, .black))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .lineSpacing(-6)
                    .rotationEffect(.degrees(-3))
                    .shadow(color: Theme.yellow.opacity(0.35), radius: 14)
                    .offset(y: appeared ? 0 : 30)
                    .opacity(appeared ? 1 : 0)
                RingingClock()
                    .opacity(appeared ? 1 : 0)
                LiveWave()
                    .frame(width: 190, height: 44)
                    .padding(.top, 4)
                missionChip
                    .padding(.top, 6)
                Spacer(minLength: 12)
                SwipeUpControl {
                    model.missionDidStart()
                    missionStarted = true
                }
                .padding(.horizontal, 28)
                bottomActions
                    .frame(height: 50)
                    .padding(.top, 10)
            }
            .padding(.bottom, 16)
        }
        .onAppear {
            withAnimation(.spring(response: 0.7, dampingFraction: 0.65)) { appeared = true }
        }
    }

    private var missionChip: some View {
        HStack(spacing: 8) {
            Image(systemName: session.mission.symbol)
                .font(.system(size: 13, weight: .bold))
            Text("Today's mission · \(session.mission.title)")
                .font(.wakie(14, .bold))
        }
        .foregroundStyle(Color(hex: 0x1E1A3C))
        .padding(.horizontal, 14)
        .frame(height: 32)
        .background(Capsule().fill(session.mission.bannerColor))
        .opacity(appeared ? 1 : 0)
    }

    private var bottomActions: some View {
        GlassEffectContainer(spacing: 12) {
            HStack(spacing: 12) {
                if session.canSnooze {
                    Button {
                        model.snoozeCurrentSession()
                    } label: {
                        Label("Snooze \(session.snoozeMinutes) min", systemImage: "zzz")
                            .font(.wakie(15, .bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 18)
                            .frame(height: 46)
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    // Darker tint keeps the white label readable over the yellow glow.
                    .glassEffect(.regular.tint(Theme.ringTop.opacity(0.55)).interactive(), in: .capsule)
                    .accessibilityHint("You can only snooze once")
                }
                if canDismiss {
                    Button {
                        model.dismissSession()
                    } label: {
                        Label("Dismiss", systemImage: "xmark")
                            .font(.wakie(15, .bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 18)
                            .frame(height: 46)
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .glassEffect(.regular.tint(Theme.danger.opacity(0.55)).interactive(), in: .capsule)
                    .accessibilityHint("Turns the alarm off without doing the mission")
                    .transition(.scale(scale: 0.6).combined(with: .opacity))
                }
            }
        }
    }
}

// MARK: - Background

/// Deep purple sky with slowly drifting glow blobs and twinkling stars.
private struct RingingBackground: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            GeometryReader { geo in
                let w = geo.size.width, h = geo.size.height
                ZStack {
                    LinearGradient(colors: [Theme.ringTop, Color(hex: 0x4B3AA0), Theme.ringBottom],
                                   startPoint: .top, endPoint: .bottom)
                    Circle()
                        .fill(Theme.yellow.opacity(0.75))
                        .frame(width: w * 0.65)
                        .blur(radius: 30)
                        .position(x: w * (0.05 + 0.06 * sin(t * 0.35)), y: h * (0.86 + 0.03 * cos(t * 0.3)))
                    Circle()
                        .fill(Theme.lavender.opacity(0.35))
                        .frame(width: w * 0.75)
                        .blur(radius: 20)
                        .position(x: w * (0.98 + 0.05 * cos(t * 0.25)), y: h * (0.96 + 0.03 * sin(t * 0.4)))
                    Circle()
                        .fill(Color(hex: 0xFF8FD8).opacity(0.18))
                        .frame(width: w * 0.55)
                        .blur(radius: 24)
                        .position(x: w * (0.92 + 0.06 * sin(t * 0.3)), y: h * (0.18 + 0.04 * cos(t * 0.35)))
                    StarField()
                }
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}

/// Music notes and sparkles drifting up the screen.
private struct FloatingNotes: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private struct Note {
        let symbol: String
        let x: Double
        let size: CGFloat
        let duration: Double
        let delay: Double
        let color: Color
    }

    private static let notes: [Note] = [
        Note(symbol: "music.note", x: 0.12, size: 22, duration: 7, delay: 0, color: Theme.lavender),
        Note(symbol: "sparkle", x: 0.85, size: 16, duration: 6, delay: 1.5, color: Theme.yellow),
        Note(symbol: "music.quarternote.3", x: 0.28, size: 26, duration: 8, delay: 3, color: Theme.lavender),
        Note(symbol: "music.note", x: 0.72, size: 20, duration: 6.5, delay: 4.2, color: Theme.yellow),
        Note(symbol: "sparkle", x: 0.5, size: 14, duration: 5.5, delay: 2.4, color: .white),
        Note(symbol: "music.note", x: 0.92, size: 18, duration: 7.5, delay: 5.4, color: Theme.lavender),
    ]

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            GeometryReader { geo in
                ForEach(Self.notes.indices, id: \.self) { index in
                    let note = Self.notes[index]
                    let progress = ((t + note.delay).truncatingRemainder(dividingBy: note.duration)) / note.duration
                    Image(systemName: note.symbol)
                        .font(.system(size: note.size, weight: .bold))
                        .foregroundStyle(note.color)
                        .rotationEffect(.degrees(sin(t * 2 + Double(index)) * 15))
                        // Fade in at the bottom, out near the top.
                        .opacity(sin(progress * .pi) * 0.8)
                        .position(
                            x: geo.size.width * note.x + sin(t * 1.3 + Double(index)) * 18,
                            y: geo.size.height * (1.0 - progress * 0.85)
                        )
                }
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

// MARK: - Mascot

/// The mission mascot shaking like a ringing alarm, with ripples and pulsing sparkles.
private struct MascotStage: View {
    let mission: Mission
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60, paused: reduceMotion)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            ZStack {
                // Sound ripples spreading out behind the mascot.
                ForEach(0..<3, id: \.self) { ring in
                    let phase = ((t / 2.4) + Double(ring) / 3).truncatingRemainder(dividingBy: 1)
                    Circle()
                        .stroke(.white.opacity(0.45 * (1 - phase)), lineWidth: 3)
                        .frame(width: 150, height: 150)
                        .scaleEffect(0.7 + phase * 1.1)
                }
                SparkleLines(size: 64)
                    .scaleEffect(1 + 0.18 * abs(sin(t * 4)))
                    .offset(x: -118, y: -10)
                    .rotationEffect(.degrees(-20))
                SparkleLines(size: 64)
                    .scaleEffect(1 + 0.18 * abs(sin(t * 4 + 1.2)))
                    .offset(x: 118, y: -10)
                    .rotationEffect(.degrees(20))
                MascotImage(mission: mission, size: 160)
                    // Rapid alarm-clock shake, with a hop every second or so.
                    .rotationEffect(.degrees(sin(t * 22) * 5 * max(0, sin(t * 2.2))))
                    .offset(y: -abs(sin(t * 3)) * 14)
                    .scaleEffect(1 + 0.03 * sin(t * 6))
            }
            .frame(height: 210)
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Clock & wave

/// Current time with a blinking colon, and the date.
private struct RingingClock: View {
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let parts = Calendar.current.dateComponents([.hour, .minute, .second], from: context.date)
            let now = WakieAlarm(hour: parts.hour ?? 0, minute: parts.minute ?? 0)
            let colonVisible = (parts.second ?? 0).isMultiple(of: 2)
            VStack(spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 0) {
                    Text("\(now.hour12)")
                    Text(":").opacity(colonVisible ? 1 : 0.25)
                    Text(String(format: "%02d", now.minute))
                    Text(" \(now.periodText)")
                        .font(.wakie(30, .heavy))
                }
                .font(.wakie(70, .black))
                .monospacedDigit()
                .contentTransition(.numericText())
                .animation(.easeInOut(duration: 0.3), value: colonVisible)
                Text(context.date.formatted(.dateTime.weekday(.wide)) + " · " + context.date.formatted(.dateTime.day().month(.abbreviated).year()))
                    .font(.wakie(17, .semibold))
                    .opacity(0.85)
            }
            .foregroundStyle(.white)
            .accessibilityElement(children: .combine)
        }
    }
}

/// Bouncing sound-wave bars, like the alarm is shouting.
private struct LiveWave: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            Canvas { canvas, size in
                let bars = 23
                let spacing: CGFloat = 4
                let width = (size.width - spacing * CGFloat(bars - 1)) / CGFloat(bars)
                for i in 0..<bars {
                    let x = CGFloat(i) * (width + spacing)
                    // Louder in the middle, wobbling over time.
                    let envelope = sin(Double(i) / Double(bars - 1) * .pi)
                    let wobble = 0.5 + 0.5 * sin(t * 7 + Double(i) * 0.7) * sin(t * 3.1 + Double(i))
                    let height = max(5, size.height * envelope * (0.25 + 0.75 * wobble))
                    let rect = CGRect(x: x, y: (size.height - height) / 2, width: width, height: height)
                    canvas.fill(Path(roundedRect: rect, cornerRadius: width / 2), with: .color(.white.opacity(0.9)))
                }
            }
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Swipe up

/// White pill with a yellow arrow knob. Drag it up to start the mission.
struct SwipeUpControl: View {
    let onTrigger: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var drag: CGFloat = 0
    @State private var triggered = false
    private let threshold: CGFloat = 110

    var body: some View {
        let progress = min(1, max(0, -drag / threshold))
        VStack(spacing: 10) {
            chevrons
                .opacity(1 - progress)
            HStack(spacing: 14) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 26, weight: .black))
                    .foregroundStyle(Color(hex: 0x1E1A3C))
                    .frame(width: 66, height: 66)
                    .background(Circle().fill(Theme.yellow))
                    .scaleEffect(1 + progress * 0.15)
                Text("Swipe up to\nstart mission")
                    .font(.wakie(18, .heavy))
                    .foregroundStyle(Color(hex: 0x1E1A3C))
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
            }
            .padding(6)
            .padding(.trailing, 16)
            .background(
                Capsule()
                    .fill(.white)
                    .shadow(color: Theme.yellow.opacity(0.25 + progress * 0.5), radius: 12 + progress * 18)
            )
            .offset(y: drag)
            .phaseAnimator([0, -8, 0], trigger: reduceMotion ? 0 : 1) { content, hop in
                // Gentle idle hop hinting at the swipe direction (only while untouched).
                content.offset(y: drag == 0 ? hop : 0)
            } animation: { _ in .easeInOut(duration: 0.6).delay(0.8) }
        }
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 4)
                .onChanged { value in
                    // Upward only; pulling down just resists.
                    let dy = value.translation.height
                    drag = dy < 0 ? dy : dy * 0.15
                }
                .onEnded { value in
                    let flicked = value.predictedEndTranslation.height < -threshold * 1.6
                    if -value.translation.height > threshold || flicked {
                        triggered = true
                        withAnimation(.easeOut(duration: 0.25)) { drag = -420 }
                        onTrigger()
                    } else {
                        withAnimation(.spring(response: 0.45, dampingFraction: 0.6)) { drag = 0 }
                    }
                }
        )
        .sensoryFeedback(.impact(weight: .heavy), trigger: triggered)
        .sensoryFeedback(.selection, trigger: progress >= 1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Start mission")
        .accessibilityHint("Swipe up, or double tap, to begin")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { onTrigger() }
    }

    /// Three chevrons lighting up bottom-to-top, pointing the way.
    private var chevrons: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            VStack(spacing: -6) {
                ForEach(0..<3, id: \.self) { i in
                    let phase = (t * 1.4 - Double(2 - i) * 0.25).truncatingRemainder(dividingBy: 1)
                    Image(systemName: "chevron.up")
                        .font(.system(size: 20, weight: .black))
                        .foregroundStyle(.white.opacity(0.25 + 0.75 * max(0, sin(phase * .pi))))
                }
            }
        }
        .accessibilityHidden(true)
    }
}

#Preview {
    RingingView(session: WakeSession(alarmID: UUID(), mission: .shakyShaky, startedAt: .now.addingTimeInterval(-20),
                                     canSnooze: true, snoozeMinutes: 5, backupAlarmID: nil))
        .environment(AppModel.shared)
}
