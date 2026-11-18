import Testing
import UIKit
@testable import Zorja

@Suite("Bundled resources")
struct AppResourcesTests {
    @Test("Every Outfit weight registers and loads by its PostScript name")
    func fontsLoad() {
        OutfitFont.register()
        #expect(OutfitFont.failures.isEmpty)
        for font in OutfitFont.allCases {
            #expect(UIFont(name: font.name, size: 17) != nil, "\(font.name) did not load")
        }
    }

    @Test("Registering twice is harmless")
    func registerTwice() {
        OutfitFont.register()
        OutfitFont.register()
        #expect(OutfitFont.failures.isEmpty)
    }

    @Test("The font licence ships with the app")
    func licenceBundled() throws {
        let url = try #require(Bundle.main.url(forResource: "OFL", withExtension: "txt"))
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text.contains("SIL Open Font License"))
    }

    @Test("The launch screen's colour is bg/base and its glow fills 402 x 240 pt")
    @MainActor func launchScreenAssets() throws {
        let color = try #require(UIColor(named: "Launch/LaunchBackground", in: .main, compatibleWith: nil))
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        #expect(color.getRed(&red, green: &green, blue: &blue, alpha: &alpha))
        let hex = UInt32((red * 255).rounded()) << 16 | UInt32((green * 255).rounded()) << 8 | UInt32((blue * 255).rounded())
        #expect(hex == ZorjaColor.bgBase.hex)
        #expect(alpha == 1)

        let glow = try #require(UIImage(named: "Launch/LaunchGlow", in: .main, with: nil))
        #expect(glow.size.width * glow.scale == 1206)
        #expect(glow.size.height * glow.scale == LaunchGlow.height * 3)
    }

    @MainActor @Test("The launch glow is full until the first sky, then fades out once")
    func launchGlowFade() {
        LaunchGlow.resetForTesting()
        defer { LaunchGlow.resetForTesting() }
        let start = Date(timeIntervalSince1970: 1_000)
        #expect(LaunchGlow.opacity(at: start) == 1)
        #expect(!LaunchGlow.isFinished(at: start))
        LaunchGlow.startFade(at: start, duration: 2.4)
        // A sky recreated later doesn't restart it.
        LaunchGlow.startFade(at: start.addingTimeInterval(1), duration: 2.4)
        #expect(LaunchGlow.opacity(at: start) == 1)
        #expect(abs(LaunchGlow.opacity(at: start.addingTimeInterval(1.2)) - 0.25) < 1e-6)
        #expect(abs(LaunchGlow.remaining(at: start.addingTimeInterval(1.2)) - 1.2) < 1e-6)
        #expect(LaunchGlow.opacity(at: start.addingTimeInterval(2.4)) < 1e-6)
        #expect(LaunchGlow.isFinished(at: start.addingTimeInterval(3)))
    }

    @Test("Every icon exists as a template image", arguments: ZorjaIcon.allCases)
    func iconLoads(_ icon: ZorjaIcon) throws {
        let image = try #require(UIImage(named: icon.assetName, in: .main, with: nil))
        #expect(image.renderingMode == .alwaysTemplate)
        #expect(image.size == CGSize(width: 24, height: 24))
    }

    @Test("Stroked icons have 16 and 20 pt variants that keep the 1.75 stroke", arguments: ZorjaIcon.allCases)
    func iconVariants(_ icon: ZorjaIcon) throws {
        for size in [IconSize.small, IconSize.button] {
            let name = "\(icon.assetName)-\(Int(size))"
            let image = UIImage(named: name, in: .main, with: nil)
            if icon.hasSizedVariants {
                let variant = try #require(image, "missing \(name)")
                #expect(variant.renderingMode == .alwaysTemplate)
                #expect(variant.size == CGSize(width: size, height: size))
            } else {
                #expect(image == nil)
            }
        }
    }

    @Test("Glyph insets scale with the icon but keep the stroke")
    func glyphInsets() {
        // Calendar: path starts 3.5 pt in on the 24 grid; ink starts half a stroke earlier.
        #expect(abs(ZorjaIcon.calendarAdd.glyphInsets(size: 24).leading - 2.625) < 0.01)
        #expect(abs(ZorjaIcon.calendarAdd.glyphInsets(size: 16).leading - (3.5 * 16 / 24 - 0.875)) < 0.01)
        // Outline-only icons scale as a whole.
        #expect(abs(ZorjaIcon.locationOff.glyphInsets(size: 16).leading - 3.125 * 16 / 24) < 0.01)
    }
}
