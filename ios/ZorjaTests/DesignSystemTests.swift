import SwiftUI
import Testing
@testable import Zorja

@Suite("Design system")
struct DesignSystemTests {
    /// The Figma `Color` collection as read on 2026-11-13 (variable name: hex, alpha), without
    /// the archived colours of the old charts, which the app no longer has.
    private let figmaColours: [String: (hex: UInt32, opacity: Double)] = [
        "bg/base": (0x05070D, 1), "surface/card": (0x202020, 1), "surface/control": (0x151515, 1),
        "surface/top": (0x0C0E15, 1),
        "line/hairline": (0x2A2A2A, 1), "line/outline": (0xFFFFFF, 0.4),
        "text/primary": (0xFFFFFF, 1), "text/secondary": (0x9E9E9E, 1), "text/tertiary": (0x7A8698, 1),
        "icon/primary": (0xFFFFFF, 1), "icon/secondary": (0x9E9E9E, 1),
        "control/selected": (0xFFFFFF, 1), "control/on-selected": (0x000000, 1),
        "action/primary": (0x0AFF74, 1), "action/on-primary": (0x000000, 1),
        "action/secondary": (0x434343, 1), "action/on-secondary": (0xFFFFFF, 1),
        "data/clear-sky": (0xFFD60A, 1), "data/aurora": (0xE742FD, 1),
        "data/unknown": (0x9E9E9E, 1), "data/track": (0x202020, 1), "status/offline": (0xFF5F5F, 1),
    ]

    @Test("Colours match the Figma variables one to one")
    func coloursMatchFigma() {
        #expect(Set(ZorjaColor.allCases.map(\.rawValue)) == Set(figmaColours.keys))
        for token in ZorjaColor.allCases {
            let expected = figmaColours[token.rawValue]
            #expect(token.hex == expected?.hex, "\(token.rawValue)")
            #expect(token.opacity == expected?.opacity, "\(token.rawValue)")
        }
    }

    @Test("Text styles match Figma at the default text size")
    func textStylesAtDefaultSize() throws {
        // Figma: name, weight, size / line height, letter spacing %.
        let figma: [ZorjaTextStyle: (OutfitFont, CGFloat, CGFloat, CGFloat)] = [
            .displayXL: (.semiBold, 60, 60, -4), .displayL: (.semiBold, 44, 48, -4),
            .titleL: (.semiBold, 24, 28, -3), .titleM: (.semiBold, 20, 24, -2), .titleS: (.semiBold, 18, 22, -1),
            .lead: (.regular, 18, 24, 0), .bodyL: (.regular, 16, 22, 0), .bodyM: (.regular, 15, 20, 0),
            .bodyS: (.regular, 13, 18, 0), .bodyXS: (.regular, 11, 14, 0), .labelM: (.medium, 15, 20, 0), .labelS: (.medium, 12, 14, 1),
            .tag: (.semiBold, 11, 14, 0),
        ]
        #expect(figma.count == ZorjaTextStyle.allCases.count)
        for style in ZorjaTextStyle.allCases {
            let (font, size, lineHeight, tracking) = try #require(figma[style])
            let metrics = style.metrics(for: .large)
            #expect(style.font == font, "\(style.rawValue)")
            #expect(metrics.size == size, "\(style.rawValue)")
            #expect(metrics.lineHeight == lineHeight, "\(style.rawValue)")
            #expect(abs(metrics.tracking - size * tracking / 100) < 0.001, "\(style.rawValue)")
        }
    }

    @Test("Text styles grow with Dynamic Type and keep their proportions", arguments: ZorjaTextStyle.allCases)
    func textStylesScale(_ style: ZorjaTextStyle) {
        let base = style.metrics(for: .large)
        let small = style.metrics(for: .xSmall)
        let largest = style.metrics(for: .accessibility5)
        #expect(small.size <= base.size)
        #expect(largest.size > base.size)
        let factor = largest.size / base.size
        #expect(abs(largest.lineHeight - base.lineHeight * factor) < 0.001)
        #expect(abs(largest.tracking - base.tracking * factor) < 0.001)
    }

    @Test("A fitted headline shrinks size, line height and tracking together", arguments: [ZorjaTextStyle.displayXL, .displayL])
    func fittedScale(_ style: ZorjaTextStyle) {
        let full = style.metrics(for: .accessibility5)
        let fitted = style.metrics(for: .accessibility5, scale: 0.6)
        #expect(abs(fitted.size - full.size * 0.6) < 0.001)
        #expect(abs(fitted.lineHeight - full.lineHeight * 0.6) < 0.001)
        #expect(abs(fitted.tracking - full.tracking * 0.6) < 0.001)
    }

    @Test("The privacy manifest declares coarse location only, and no tracking")
    func privacyManifest() throws {
        let url = try #require(Bundle.main.url(forResource: "PrivacyInfo", withExtension: "xcprivacy"))
        let manifest = try #require(try PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil) as? [String: Any])
        #expect(manifest["NSPrivacyTracking"] as? Bool == false)
        #expect((manifest["NSPrivacyTrackingDomains"] as? [String])?.isEmpty == true)
        let collected = try #require(manifest["NSPrivacyCollectedDataTypes"] as? [[String: Any]])
        #expect(collected.map { $0["NSPrivacyCollectedDataType"] as? String } == ["NSPrivacyCollectedDataTypeCoarseLocation"])
        #expect(collected.first?["NSPrivacyCollectedDataTypeLinked"] as? Bool == false)
        #expect(Bundle.main.object(forInfoDictionaryKey: "ITSAppUsesNonExemptEncryption") as? Bool == false)
    }

    @Test("Spacing, radius, and hour sizes match the Figma Layout collection")
    func layout() {
        #expect([Space.s2, Space.s4, Space.s8, Space.s12, Space.s16, Space.s20, Space.s24, Space.s32, Space.s48]
            == [2, 4, 8, 12, 16, 20, 24, 32, 48])
        #expect(Space.screenMargin == 24)
        #expect([Radius.none, Radius.card, Radius.full] == [0, 16, 999])
        #expect([ZorjaHour.size, ZorjaHour.focus, ZorjaHour.legend, ZorjaHour.gap] == [58, 88, 48, 8])
    }

    @Test("The app always runs in dark mode")
    func darkOnly() {
        #expect(Bundle.main.object(forInfoDictionaryKey: "UIUserInterfaceStyle") as? String == "Dark")
    }

    @Test("Labels in pills centre their capitals; other text centres the font, as Figma does",
          arguments: [ZorjaTextStyle.labelM, .tag])
    func capCentredBaseline(_ style: ZorjaTextStyle) {
        let metrics = style.metrics(for: .large)
        let font = style.uiFont(metrics)
        let figma = OverflowTextRenderer.LineBox(style: style, metrics: metrics)
        let centred = OverflowTextRenderer.LineBox(style: style, metrics: metrics, capCentered: true)
        // Capitals span baseline − cap height … baseline; their middle is the line box's.
        #expect(abs((centred.baseline - font.capHeight / 2) - metrics.lineHeight / 2) < 0.001)
        // Outfit's font box puts the capitals a little low, by less than half a point.
        let shift = figma.baseline - centred.baseline
        #expect(shift > 0 && shift < 0.5)
    }

    @Test("Text draws where Figma puts it on every iOS version", arguments: [ZorjaTextStyle.labelM, .tag, .displayXL])
    @MainActor
    func drawnCapitalsSitInTheirLineBox(_ style: ZorjaTextStyle) throws {
        // iOS 27 started the first line of a layout lower than iOS 26 did (3 pt for
        // Label/M, 10 pt for Display/XL), and text drew that much too high on the phone.
        let metrics = style.metrics(for: .large)
        let view = Text("HH").textStyle(style).foregroundStyle(.white)
            .frame(height: metrics.lineHeight).background(.black).environment(\.dynamicTypeSize, .large)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 4
        let image = try #require(renderer.cgImage)
        let rows = try inkRows(image)
        let font = style.uiFont(metrics)
        let baseline = OverflowTextRenderer.LineBox(style: style, metrics: metrics).baseline
        let capTop = (rows.lowerBound) / 4
        let capBottom = (rows.upperBound) / 4
        #expect(abs(capTop - (baseline - font.capHeight)) < 0.75, "cap top \(capTop)")
        #expect(abs(capBottom - baseline) < 0.75, "baseline \(capBottom)")
    }

    /// First and last pixel rows with ink (any bright pixel), in pixels.
    private func inkRows(_ image: CGImage) throws -> ClosedRange<CGFloat> {
        let width = image.width, height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let context = try #require(CGContext(
            data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let inked = (0..<height).filter { row in
            (0..<width).contains { pixels[(row * width + $0) * 4] > 128 }
        }
        let first = try #require(inked.first), last = try #require(inked.last)
        return CGFloat(first)...CGFloat(last + 1)
    }
}
