#if DEBUG
import SwiftUI

/// Development copy of the Figma Foundations page: colours, text styles, spacing and radius.
/// Not shown in the app.
struct FoundationsGallery: View {
    var body: some View {
        ScrollView {
            FoundationsSheet()
        }
        .background(.bgBase)
    }
}

/// The gallery content without scrolling, so it can also be rendered to an image.
struct FoundationsSheet: View {
    private let sample = "Aurora tonight, best until 01:30"

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s48) {
            colours
            type
            spacing
        }
        .padding(Space.screenMargin)
        .foregroundStyle(.textPrimary)
        .background(.bgBase)
    }

    private var colours: some View {
        VStack(alignment: .leading, spacing: Space.s16) {
            Text("Colour").textStyle(.titleL)
            ForEach(ZorjaColor.allCases, id: \.self) { token in
                HStack(spacing: Space.s16) {
                    Rectangle()
                        .fill(token.color)
                        .frame(width: 56, height: 32)
                        .overlay(Rectangle().stroke(.lineHairline))
                    VStack(alignment: .leading, spacing: Space.s2) {
                        Text(token.rawValue).textStyle(.labelM)
                        Text(hexLabel(token)).textStyle(.bodyS).foregroundStyle(.textSecondary)
                    }
                }
            }
        }
    }

    private var type: some View {
        VStack(alignment: .leading, spacing: Space.s16) {
            Text("Type").textStyle(.titleL)
            ForEach(ZorjaTextStyle.allCases, id: \.self) { style in
                VStack(alignment: .leading, spacing: Space.s4) {
                    Text(typeLabel(style)).textStyle(.bodyS).foregroundStyle(.textTertiary)
                    Text(style == .tag ? "Best" : sample).textStyle(style)
                }
            }
        }
    }

    private var spacing: some View {
        VStack(alignment: .leading, spacing: Space.s12) {
            Text("Spacing and radius").textStyle(.titleL)
            ForEach(
                [("space/2", Space.s2), ("space/4", Space.s4), ("space/8", Space.s8), ("space/12", Space.s12),
                 ("space/16", Space.s16), ("space/20", Space.s20), ("space/24", Space.s24),
                 ("space/32", Space.s32), ("space/48", Space.s48)],
                id: \.0
            ) { name, value in
                HStack(spacing: Space.s16) {
                    Text("\(name) \(Int(value))").textStyle(.bodyS).frame(width: 96, alignment: .leading)
                    Rectangle().fill(.textSecondary).frame(width: value, height: 12)
                }
            }
            HStack(spacing: Space.s16) {
                RoundedRectangle(cornerRadius: Radius.none).fill(.surfaceCard).frame(width: 64, height: 40)
                RoundedRectangle(cornerRadius: Radius.card).fill(.surfaceCard).frame(width: 64, height: 40)
                Capsule().fill(.surfaceCard).frame(width: 64, height: 40)
            }
            Text("radius/none 0, radius/card 16, radius/full").textStyle(.bodyS).foregroundStyle(.textSecondary)
            ForEach(
                [("hour/size", ZorjaHour.size), ("hour/focus", ZorjaHour.focus), ("hour/legend", ZorjaHour.legend),
                 ("hour/gap", ZorjaHour.gap)],
                id: \.0
            ) { name, value in
                HStack(spacing: Space.s16) {
                    Text("\(name) \(Int(value))").textStyle(.bodyS).frame(width: 96, alignment: .leading)
                    Circle().stroke(.textSecondary).frame(width: value, height: value)
                }
            }
        }
    }

    private func hexLabel(_ token: ZorjaColor) -> String {
        let hex = "#" + String(format: "%06X", token.hex)
        return token.opacity < 1 ? "\(hex) \(Int(token.opacity * 100))%" : hex
    }

    private func typeLabel(_ style: ZorjaTextStyle) -> String {
        let tracking = style.trackingPercent == 0 ? "" : " \(Int(style.trackingPercent))%"
        return "\(style.rawValue) · \(style.font.name.replacingOccurrences(of: "Outfit-", with: "")) "
            + "\(Int(style.size))/\(Int(style.lineHeight))\(tracking)"
    }
}

#Preview {
    FoundationsGallery()
        .onAppear { OutfitFont.register() }
}

#Preview("Largest accessibility text") {
    FoundationsGallery()
        .onAppear { OutfitFont.register() }
        .dynamicTypeSize(.accessibility5)
}
#endif
