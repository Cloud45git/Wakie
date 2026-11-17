//
//  DayNightToggle.swift
//  Wakie
//
//  The Day/Night toggle from the "Day-Night Toggle (Community)" Figma file.
//  Built at the design's native 369×145 size, then scaled to fit.
//

import SwiftUI

struct DayNightToggle: View {
    @Binding var isNight: Bool
    /// Rendered width; height keeps the design's aspect ratio.
    var width: CGFloat = 92

    private let designSize = CGSize(width: 369, height: 145)

    var body: some View {
        let scale = width / designSize.width
        Button {
            withAnimation(.spring(response: 0.55, dampingFraction: 0.78)) {
                isNight.toggle()
            }
        } label: {
            canvas
                .frame(width: designSize.width, height: designSize.height)
                .scaleEffect(scale, anchor: .topLeading)
                .frame(width: designSize.width * scale, height: designSize.height * scale, alignment: .topLeading)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Appearance")
        .accessibilityValue(isNight ? "Night" : "Day")
        .accessibilityAddTraits(.isToggle)
    }

    /// Distance the clouds and stars slide vertically between the two states.
    private var slide: CGFloat { isNight ? 0 : -226 }

    private var canvas: some View {
        ZStack(alignment: .topLeading) {
            // Halo rays behind the sun / moon
            layer("ToggleRays", size: CGSize(width: 380, height: 380), x: isNight ? 111 : -110, y: -118)

            // Clouds sink out of view at night
            layer("ToggleCloudsBack", size: CGSize(width: 399, height: 231), x: 4, y: isNight ? 184 : -42)
            layer("ToggleCloudsFront", size: CGSize(width: 393, height: 272), x: 14, y: isNight ? 214 : -12)

            // Stars drop in from above at night
            Group {
                layer("ToggleStar1", size: CGSize(width: 20.211, height: 18.5437), x: 166.4, y: 51 + slide)
                layer("ToggleStar2", size: CGSize(width: 8, height: 7.34), x: 122, y: 27 + slide)
                layer("ToggleStar3", size: CGSize(width: 72.1932, height: 23.601), x: 101.8, y: 92 + slide)
                layer("ToggleStar4", size: CGSize(width: 16.696, height: 16.8579), x: 28.2, y: 79 + slide)
                layer("ToggleStar5", size: CGSize(width: 26.8268, height: 25.7313), x: 59.9, y: 31 + slide)
            }

            // Sun & Moon knob: the moon slides over the sun inside a circular mask
            ZStack(alignment: .topLeading) {
                layer("ToggleSun", size: CGSize(width: 120, height: 120), x: 0, y: 0)
                ZStack(alignment: .topLeading) {
                    layer("ToggleMoon", size: CGSize(width: 120, height: 120), x: 0, y: 0)
                    layer("ToggleCraters", size: CGSize(width: 73, height: 81), x: 30, y: 19)
                }
                .offset(x: isNight ? 0 : 121)
            }
            .frame(width: 120, height: 120, alignment: .topLeading)
            .clipShape(Circle())
            .shadow(color: .black.opacity(0.5), radius: 1, x: 0, y: 4)
            .shadow(color: .black.opacity(0.25), radius: 2, x: 4, y: 7)
            .offset(x: isNight ? 235 : 14, y: 12)
        }
        .frame(width: designSize.width, height: designSize.height, alignment: .topLeading)
        // Sky
        .background(isNight ? Color(hex: 0x001120) : Color(hex: 0x3E8EC8))
        .clipShape(Capsule())
        // Inset shadow along the top edge of the track
        .overlay(
            Capsule()
                .stroke(Color.black.opacity(0.28), lineWidth: 10)
                .blur(radius: 7)
                .offset(y: 4)
                .mask(Capsule())
        )
        .shadow(color: .black.opacity(0.25), radius: 2, x: 0, y: -3)
        .shadow(color: .white.opacity(0.94), radius: 2, x: 0, y: 4)
    }

    private func layer(_ name: String, size: CGSize, x: CGFloat, y: CGFloat) -> some View {
        Image(name)
            .resizable()
            .frame(width: size.width, height: size.height)
            .offset(x: x, y: y)
    }
}

#Preview {
    @Previewable @State var night = false
    VStack(spacing: 30) {
        DayNightToggle(isNight: $night, width: 369)
        DayNightToggle(isNight: .constant(true), width: 369)
        DayNightToggle(isNight: $night)
    }
    .padding()
}
