//
//  Components.swift
//  Wakie
//

import SwiftUI

/// Mission mascot artwork. The source images have generous transparent padding,
/// so the figure is scaled up to fill a `size × size` box (overflow is allowed).
struct MascotImage: View {
    let mission: Mission
    var size: CGFloat = 60

    var body: some View {
        Color.clear
            .frame(width: size, height: size)
            .overlay {
                Image(mission.mascot)
                    .resizable()
                    .scaledToFit()
                    .frame(width: size * 2.0 * artScale, height: size * 1.25 * artScale)
            }
            .accessibilityHidden(true)
    }

    /// The artwork has different amounts of padding, so each mascot gets its own boost.
    /// Shaky-Shaky's music notes make the figure itself read smaller, so it gets more.
    private var artScale: CGFloat {
        switch mission {
        case .shakyShaky: 1.35
        case .pickiePicky, .blahBlah: 1.12
        }
    }
}

/// Section label used above groups of controls ("Repeat", "Challenge").
struct SectionLabel: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.wakie(15, .bold))
            .foregroundStyle(Theme.ink)
    }
}

/// A screen title with the yellow sparkle strokes, e.g. "Alarms".
struct ScreenTitle: View {
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 4) {
            Text(text)
                .font(.wakie(36, .black))
                .foregroundStyle(Theme.ink)
                .fixedSize(horizontal: false, vertical: true)
            SparkleLines(size: 24)
                .rotationEffect(.degrees(60))
                .offset(y: 4)
        }
    }
}

/// Selectable challenge tile used in the alarm editor.
struct MissionTile: View {
    let mission: Mission
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                MascotImage(mission: mission, size: 50)
                    .padding(.top, 6)
                Text(mission.tileTitle)
                    .font(.wakie(14, .heavy))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(isSelected ? Color(hex: 0x1E1A3C) : Theme.ink)
                    .lineSpacing(-2)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 104)
            .background(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(isSelected ? AnyShapeStyle(LinearGradient(colors: [Theme.yellow, Theme.yellowDeep], startPoint: .top, endPoint: .bottom)) : AnyShapeStyle(Theme.card))
                    .shadow(color: isSelected ? Theme.yellowDeep.opacity(0.45) : Theme.shadow, radius: 10, y: 5)
            )
            .overlay(alignment: .topTrailing) {
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .black))
                        .foregroundStyle(.white)
                        .frame(width: 24, height: 24)
                        .background(Circle().fill(Theme.timeBox))
                        .overlay(Circle().stroke(.white, lineWidth: 2))
                        .offset(x: 6, y: -6)
                }
            }
        }
        .buttonStyle(PressableStyle())
        .accessibilityLabel(mission.title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// The Edit / Done and + buttons at the top right of the Alarms and World Clock tabs.
/// Shared so both screens use identical Liquid Glass buttons at the same size and position.
struct HeaderActions: View {
    @Binding var isEditing: Bool
    var showsEdit: Bool
    let addLabel: String
    let onAdd: () -> Void

    /// One height for both buttons; the + button is a circle of the same size.
    static let height: CGFloat = 44

    var body: some View {
        GlassEffectContainer(spacing: 10) {
            HStack(spacing: 10) {
                if showsEdit {
                    Button {
                        withAnimation(.snappy) { isEditing.toggle() }
                    } label: {
                        Text(isEditing ? "Done" : "Edit")
                            .font(.wakie(16, .bold))
                            .foregroundStyle(Theme.ink)
                            .contentTransition(.opacity)
                            .padding(.horizontal, 18)
                            .frame(minWidth: 72)
                            .frame(height: Self.height)
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .glassEffect(.regular.tint(Theme.purple.opacity(0.18)).interactive(), in: .capsule)
                }
                Button(action: onAdd) {
                    Image(systemName: "plus")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(Theme.ink)
                        .frame(width: Self.height, height: Self.height)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.tint(Theme.purple.opacity(0.18)).interactive(), in: .circle)
                .accessibilityLabel(addLabel)
            }
        }
    }
}

/// Fixed-height title row so header buttons land in the same spot on every tab.
struct TabHeader<Title: View>: View {
    @Binding var isEditing: Bool
    var showsEdit: Bool
    let addLabel: String
    let onAdd: () -> Void
    @ViewBuilder let title: Title

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            title
            Spacer(minLength: 8)
            HeaderActions(isEditing: $isEditing, showsEdit: showsEdit, addLabel: addLabel, onAdd: onAdd)
        }
        .frame(height: 56)
    }
}
