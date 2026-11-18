import SwiftUI
import Testing
@testable import Zorja

@Suite("Components")
struct ComponentTests {
    @Test("Menu items swap to the bold or filled icon when selected")
    func menuIcons() {
        #expect(MenuTab.now.icon(selected: false) == .now)
        #expect(MenuTab.now.icon(selected: true) == .nowBold)
        #expect(MenuTab.tonight.icon(selected: false) == .tonight)
        #expect(MenuTab.tonight.icon(selected: true) == .tonightFilled)
        #expect(MenuTab.threeNights.icon(selected: false) == .threeNights)
        #expect(MenuTab.threeNights.icon(selected: true) == .threeNightsFilled)
        #expect(MenuTab.allCases.map(\.title) == ["Now", "Tonight", "3 Nights"])
    }

    @Test("Chevron directions rotate the one right-pointing icon")
    func chevronAngles() {
        #expect(Chevron.Direction.right.angle == .zero)
        #expect(Chevron.Direction.down.angle == .degrees(90))
        #expect(Chevron.Direction.left.angle == .degrees(180))
        #expect(Chevron.Direction.up.angle == .degrees(-90))
    }

    @Test("Tag and key row words match the Figma components")
    func fixedWords() {
        #expect(ZorjaTag.Kind.allCases.map(\.title) == ["Best", "Skip", "Clear sky", "Offline"])
        #expect([KeyRow.Kind.darkSky, .clearSky, .aurora].map(\.title) == ["Dark Sky", "Clear Sky", "Aurora"])
    }

    @Test("Tags take the Figma fills: yellow Best, white Skip and Clear sky, red Offline")
    func tagFills() {
        #expect(ZorjaTag.Kind.best.fill == .dataClearSky)
        #expect(ZorjaTag.Kind.skip.fill == .controlSelected)
        #expect(ZorjaTag.Kind.clearSky.fill == .controlSelected)
        #expect(ZorjaTag.Kind.offline.fill == .statusOffline)
    }

    @Test("Every Sky variant has its Figma icon; Unknown has no storm variant")
    func skyAssets() {
        for kind in Sky.Kind.allCases {
            for storm in [false, true] {
                let sky = Sky(kind: kind, storm: storm)
                #expect(UIImage(named: sky.assetName) != nil, "\(sky.assetName)")
            }
        }
        #expect(Sky(kind: .unknown, storm: true).assetName == "Sky/sky-unknown")
        #expect(Sky(kind: .cloudy, storm: true).assetName == "Sky/sky-cloudy-storm")
    }

    @Test("The Dark Sky key uses the arc's track colour")
    func darkSkyKey() {
        #expect(KeyRow.Kind.darkSky.color == .dataTrack)
    }

    @Test("Hour mark sizes and fills match the Figma variants")
    func hourMarkGeometry() {
        #expect(HourMark.Size.allCases.map(\.diameter) == [58, 88, 48])
        #expect(HourMark.Size.allCases.map(\.auroraWidth) == [4, 4, 3])
        // Figma: clear r 24 / 40 / 21, or r 19 / 35 / 18 inside the aurora ring; gaps r 10.5 / 16 / 8.5.
        #expect(HourMark.Size.allCases.map { HourMark(sky: .clear, size: $0).clearDiameter } == [48, 80, 42])
        #expect(HourMark.Size.allCases.map { HourMark(sky: .clear, aurora: true, size: $0).clearDiameter } == [38, 70, 36])
        #expect(HourMark.Size.allCases.map { HourMark(sky: .partlyCloudy, size: $0).clearDiameter } == [21, 32, 17])
        for sky in [HourMark.Sky.cloudy, .unknown, .twilight, .daylight, .loading] {
            #expect(HourMark(sky: sky).clearDiameter == nil)
        }
        // The ring hugs a clear hour and sits 5 / 4 / 3 pt in otherwise.
        #expect(HourMark(sky: .clear, aurora: true).auroraInset == 0)
        #expect(HourMark.Size.allCases.map { HourMark(sky: .cloudy, aurora: true, size: $0).auroraInset } == [5, 4, 3])
    }

    @Test("No aurora ring in daylight or while loading")
    func hourMarkAurora() {
        #expect(!HourMark(sky: .daylight, aurora: true).showsAurora)
        #expect(!HourMark(sky: .loading, aurora: true).showsAurora)
        for sky in [HourMark.Sky.clear, .partlyCloudy, .cloudy, .unknown, .twilight] {
            #expect(HourMark(sky: sky, aurora: true).showsAurora)
            #expect(!HourMark(sky: sky).showsAurora)
        }
    }

    @Test("The aurora glow flickers between 40 % and full strength and loops seamlessly")
    func auroraGlowLoop() {
        var values: [Double] = []
        for step in 0...600 {
            let time = Double(step) * 0.01
            let value = HourGlow.strength(at: time)
            #expect(value >= HourGlow.floor - 1e-9 && value <= 1 + 1e-9)
            #expect(abs(value - HourGlow.strength(at: time + HourGlow.period)) < 1e-9)
            values.append(value)
        }
        // Visible: it swings over at least half its range within a loop.
        #expect(values.max()! - values.min()! > (1 - HourGlow.floor) / 2)
        // Neighbouring rings are out of step.
        #expect(HourGlow.strength(at: 1, phase: 0.37) != HourGlow.strength(at: 1))
    }
}
