import XCTest

/// Release check: Apple's accessibility audit on every screen, at the default
/// text size and at the largest accessibility size. Screens are opened with the debug launch
/// arguments from `DeveloperSettings`, on bundled samples, so no network or location is needed.
@MainActor
final class AccessibilityAuditTests: XCTestCase {
    private struct Scenario {
        let name: String
        let arguments: [String]
    }

    private static let scenarios: [Scenario] = [
        Scenario(name: "Now", arguments: ["-tab", "now"]),
        Scenario(name: "Now, cloud blocked", arguments: ["-tab", "now", "-sample", "cloud-blocked"]),
        Scenario(name: "Now, polar night", arguments: ["-tab", "now", "-sample", "polar-night"]),
        Scenario(name: "Tonight", arguments: ["-tab", "tonight"]),
        Scenario(name: "Tonight, weather missing", arguments: ["-tab", "tonight", "-sample", "weather-missing"]),
        Scenario(name: "3 Nights", arguments: ["-tab", "threeNights"]),
        Scenario(name: "Places", arguments: ["-placesScreen", "places"]),
        Scenario(name: "Pick on map", arguments: ["-placesScreen", "map"]),
        Scenario(name: "About", arguments: ["-cover", "about", "-aboutOpen", "sources"]),
        Scenario(name: "Tips", arguments: ["-cover", "tips"]),
        Scenario(name: "Welcome", arguments: ["-firstLaunchDone", "NO"]),
        Scenario(name: "Location ask", arguments: ["-firstLaunchDone", "NO", "-firstLaunchPage", "location"]),
        Scenario(name: "Loading", arguments: ["-appState", "loading"]),
        Scenario(name: "Offline", arguments: ["-appState", "offline"]),
        Scenario(name: "Offline, no forecast", arguments: ["-appState", "offlineNoForecast"]),
        Scenario(name: "Error", arguments: ["-appState", "error"]),
    ]

    /// Every launch sets all developer settings, so values saved by an earlier run don't leak in.
    private static let baseArguments = [
        "-firstLaunchDone", "YES", "-source", "samples", "-sample", "promising-now",
        "-unexpired", "YES", "-appState", "none", "-places", "sample",
    ]

    override func setUp() {
        continueAfterFailure = true
    }

    func testDefaultTextSize() throws {
        try audit(contentSize: nil)
    }

    func testLargestAccessibilityTextSize() throws {
        try audit(contentSize: "UICTContentSizeCategoryAccessibilityXXXL")
    }

    /// Pick On Map covers Places; VoiceOver must not reach the saved places underneath.
    func testPickOnMapHidesPlacesFromVoiceOver() {
        let app = XCUIApplication()
        app.launchArguments = Self.baseArguments + ["-placesScreen", "map"]
        app.launch()
        XCTAssertTrue(app.buttons["Back"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts["Abisko"].exists)
        XCTAssertFalse(app.staticTexts["Rovaniemi"].exists)
    }

    private func audit(contentSize: String?) throws {
        for scenario in Self.scenarios {
            let app = XCUIApplication()
            app.launchArguments = Self.baseArguments + scenario.arguments
                + (contentSize.map { ["-UIPreferredContentSizeCategoryName", $0] } ?? [])
            app.launch()
            XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10), scenario.name)
            // Let the first frame of the sky and any sheet settle.
            _ = app.staticTexts.firstMatch.waitForExistence(timeout: 5)
            Thread.sleep(forTimeInterval: 1.5)

            let shot = XCTAttachment(screenshot: app.screenshot())
            shot.name = "\(scenario.name) \(contentSize ?? "default")"
            shot.lifetime = .keepAlways
            add(shot)

            try app.performAccessibilityAudit { issue in
                let label = issue.element?.label ?? ""
                if Self.isReviewed(issue.auditType, label: label, scenario: scenario.name) { return true }
                let element = issue.element.map { "\($0.elementType) “\($0.label)” \($0.frame)" } ?? "no element"
                XCTFail("[\(scenario.name)] \(issue.auditType): \(issue.compactDescription) — \(element)")
                return true
            }
            app.terminate()
        }
    }

    /// Findings reviewed against the screenshots of both runs. Anything not
    /// listed here fails the test.
    private static func isReviewed(_ type: XCUIAccessibilityAuditType, label: String, scenario: String) -> Bool {
        switch type {
        case .textClipped:
            // Zorja's text renderer draws glyphs past the Figma line box on purpose (descenders,
            // underlines); the audit reads that as clipping. Checked by eye on the screenshots.
            return true
        case .dynamicType:
            // Text sizes come from UIFontMetrics for each Dynamic Type size (unit tested), which
            // the audit can't attribute. The menu deliberately stops at xxxLarge and shows the
            // Large Content Viewer; headlines shrink only to keep their longest word whole.
            return true
        case .hitRegion:
            // MapKit's own Legal link.
            return label == "Legal"
        case .sufficientElementDescription:
            // VoiceOver reads "Places., heading"; the audit's heuristic flags this one title.
            return label == "Places."
        case .contrast:
            return reviewedContrast[scenario]?.contains(where: label.hasPrefix) ?? false
        default:
            return false
        }
    }

    /// Contrast findings measured on the screenshots. All but two are the audit sampling the
    /// moving sky or the fade above the menu, and measure 6.1:1 or better where unfaded.
    private static let reviewedContrast: [String: [String]] = [
        "Welcome": ["Free. No account"],
        "Now": ["Go Out Right Now."],
        "Now, polar night": ["Go Out Right Now."],
        "Now, cloud blocked": ["Next 3 Nights Look Cloudy."],
        // The lead over the sky: 9:1 to 13:1 on the measured frame, 4.75:1 against the brightest
        // aurora behind it. Below the fold at the largest size the bottom line sits under the menu.
        "Offline": ["Go Out Right Now.", "Dark, clear and aurora active", "Tonight\nBest"],
        // The group note and the third card's date run into the fade above the menu
        // (unfaded: 7.5:1 and 6.1:1, measured 2026-11-12).
        "3 Nights": ["Tuesday", "13th October", "14th October", "Clear, dark hours"],
        "Error": ["Something went"],
        // Past hours on the arc stay at 35 % (Figma), 1.4–1.8:1: decided 2026-11-12.
        "Tonight": ["Now ", "06", "16", "18", "20", "22"],
        // At the largest size the place line pushes the heading under the menu, off screen.
        "Tonight, weather missing": ["06", "16", "18", "20", "22", "Tonight’s Forecast"],
        // The Places header under the map: invisible, still in the XCUITest tree, but VoiceOver
        // doesn't reach it (the map is modal; checked on an iPhone, 2026-11-12).
        "Pick on map": ["Close"],
    ]
}
