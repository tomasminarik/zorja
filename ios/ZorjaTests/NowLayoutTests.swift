import SwiftUI
import Testing
@testable import Zorja

@Suite("Now layout")
struct NowLayoutTests {
    init() { OutfitFont.register() }

    /// Text width on the 402 pt and 375 pt Figma frames, less the room BalancedText keeps free.
    static let regular: CGFloat = 354 - BalancedText.slack
    static let small: CGFloat = 327 - BalancedText.slack

    static let headlines: [(Phrase, [String])] = [
        (Phrase("Go Out Right Now.", emphasis: "Right Now"), ["Go Out", "Right Now."]),
        (Phrase("Wait Until 23:00.", emphasis: "23:00"), ["Wait Until", "23:00."]),
        (Phrase("Skip Tonight.", emphasis: "Skip"), ["Skip", "Tonight."]),
        (Phrase("Too Bright Until 16:10.", emphasis: "16:10"), ["Too Bright", "Until 16:10."]),
        (Phrase("Too Bright All Night.", emphasis: "All Night"), ["Too Bright", "All Night."]),
        (Phrase("Clouds Not Known.", emphasis: "Not Known"), ["Clouds", "Not Known."]),
        (Phrase("Aurora Not Known.", emphasis: "Not Known"), ["Aurora", "Not Known."]),
        (Phrase("Out Of Date Since 19:40.", emphasis: "19:40"), ["Out Of Date", "Since 19:40."]),
        (Phrase("Quiet Right Now.", emphasis: "Right Now"), ["Quiet", "Right Now."]),
        (Phrase("Partly Cloudy.", emphasis: "Cloudy"), ["Partly", "Cloudy."]),
    ]

    @Test("Headlines break as in the Figma frames, on both phone widths", arguments: headlines)
    func headline(_ phrase: Phrase, _ expected: [String]) {
        let balancer = LineBalancer.measuring(.displayXL)
        #expect(balancer.lines(phrase.text, emphasis: phrase.emphasis, width: Self.regular) == expected)
        #expect(balancer.lines(phrase.text, emphasis: phrase.emphasis, width: Self.small) == expected)
    }

    @Test("\"Dark Enough\" is wider than the 375 pt frame at 60 pt, so it takes three lines there")
    func darkEnoughOnSmallIPhone() {
        let balancer = LineBalancer.measuring(.displayXL)
        let phrase = Phrase("Dark Enough At 16:10.", emphasis: "16:10")
        #expect(balancer.lines(phrase.text, emphasis: phrase.emphasis, width: Self.regular) == ["Dark Enough", "At 16:10."])
        #expect(balancer.lines(phrase.text, emphasis: phrase.emphasis, width: Self.small) == ["Dark", "Enough", "At 16:10."])
    }

    static let bottomLines: [(Phrase, [String])] = [
        (Phrase("Tonight Best Until 01:30.", emphasis: "01:30", subject: "Tonight"), ["Tonight", "Best Until 01:30."]),
        (Phrase("Tonight Best 23:00–03:30.", emphasis: "23:00–03:30", subject: "Tonight"), ["Tonight", "Best 23:00–03:30."]),
        (Phrase("Today Best Until 18:00.", emphasis: "18:00", subject: "Today"), ["Today", "Best Until 18:00."]),
        (Phrase("Thursday Looks Clearer.", emphasis: "Thursday", subject: "Thursday"), ["Thursday", "Looks Clearer."]),
        (Phrase("Next 3 Nights No Darkness.", emphasis: "No Darkness", subject: "Next 3 Nights"), ["Next 3 Nights", "No Darkness."]),
        (Phrase("Tonight Dark Until 06:40.", emphasis: "06:40", subject: "Tonight"), ["Tonight", "Dark Until 06:40."]),
        (Phrase("Look Up And Check.", emphasis: "Look Up"), ["Look Up", "And Check."]),
        (Phrase("Checking Again At 22:20.", emphasis: "22:20"), ["Checking Again", "At 22:20."]),
    ]

    @Test("Bottom lines break as in Figma: 44 pt on the 402 pt frame, 40 pt on the 375 pt frame", arguments: bottomLines)
    func bottomLine(_ phrase: Phrase, _ expected: [String]) {
        let regular = LineBalancer.measuring(.displayL)
        let small = LineBalancer.measuring(.displayL, size: NowScreen.smallBottomLineSize)
        #expect(regular.lines(phrase.text, emphasis: phrase.emphasis, subject: phrase.subject, width: Self.regular) == expected)
        #expect(small.lines(phrase.text, emphasis: phrase.emphasis, subject: phrase.subject, width: Self.small) == expected)
    }

    @Test("Leads take two balanced lines when they would fit on one or two")
    func leads() throws {
        let balancer = LineBalancer.measuring(.lead)
        for lead in [
            "Dark, clear and aurora active overhead.",
            "The sun stays too high here for aurora to show.",
            "Cloud clears around 23:00, and it stays dark all night.",
            "It’s dark and clear, but there’s no live aurora data for here right now.",
        ] {
            let lines = try #require(balancer.lines(lead, width: Self.regular))
            #expect(lines.count == 2)
            #expect(lines.joined(separator: " ") == lead)
            let widths = lines.map(balancer.measure)
            // Balanced: the lines differ by less than the longest word that could move.
            #expect(abs(widths[0] - widths[1]) < 120)
        }
    }

    @Test("Two sentences break between them, as in Figma")
    func sentences() {
        let balancer = LineBalancer.measuring(.lead)
        #expect(balancer.lines("Aurora is active, but daylight hides it. Tonight is checked on its own.", width: Self.regular)
            == ["Aurora is active, but daylight hides it.", "Tonight is checked on its own."])
        #expect(balancer.lines("It’s polar night, dark all day. Clear until 18:00, aurora active.", width: Self.regular)
            == ["It’s polar night, dark all day.", "Clear until 18:00, aurora active."])
        #expect(balancer.lines("Zorja can’t get fresh data right now. Don’t rely on the last forecast.", width: Self.regular)
            == ["Zorja can’t get fresh data right now.", "Don’t rely on the last forecast."])
        #expect(balancer.lines("Something went wrong on Zorja’s side. It isn’t your connection.", width: Self.regular)
            == ["Something went wrong on Zorja’s side.", "It isn’t your connection."])
        // Too lopsided: the first sentence alone is wider than the space allows.
        #expect(balancer.lines("It’s dark and aurora is active, but cloud comes and goes. Watch for gaps.", width: Self.regular)
            != ["It’s dark and aurora is active, but cloud comes and goes.", "Watch for gaps."])
    }

    @Test("A long lead keeps the number of lines it needs")
    func longLead() throws {
        let lead = "Your phone is offline, so Zorja can’t check the sky. It tries again when you’re back online."
        let lines = try #require(LineBalancer.measuring(.lead).lines(lead, width: Self.regular))
        #expect(lines.count == 3)
    }

    @Test("Single words, words wider than the space and impossible splits wrap on their own")
    func fallbacks() {
        let balancer = LineBalancer.measuring(.displayXL)
        #expect(balancer.lines("Wait.", emphasis: "Wait", width: Self.regular) == nil)
        #expect(balancer.lines("Go Out Right Now.", width: 100) == nil)
        // The only break falls inside the underlined part.
        #expect(balancer.lines("Right Now.", emphasis: "Right Now.", width: Self.regular) == nil)
    }

    @Test("The subject is ignored when the rest doesn't fit on one line")
    func subjectFallsBack() throws {
        let balancer = LineBalancer.measuring(.displayL, dynamicTypeSize: .xxxLarge)
        let phrase = Phrase("Tonight Best 23:00–03:30.", emphasis: "23:00–03:30", subject: "Tonight")
        let lines = try #require(balancer.lines(phrase.text, emphasis: phrase.emphasis, subject: phrase.subject, width: Self.small))
        #expect(lines != ["Tonight", "Best 23:00–03:30."])
        #expect(lines.allSatisfy { !$0.hasSuffix("23:00–") })
    }

    @Test("The header starts at the safe area, no lower than Figma's 54 pt status bar")
    func headerTop() {
        #expect(ShellLayout.headerTop(safeAreaTop: 62) == 54) // iPhone 17 Pro
        #expect(ShellLayout.headerTop(safeAreaTop: 20) == 20) // iPhone SE
        #expect(ShellLayout.headerTop(safeAreaTop: 47) == 47)
    }

    @Test("The menu ends on the home indicator area, or 8 pt above the edge")
    func menuBottom() {
        #expect(ShellLayout.menuBottom(safeAreaBottom: 34) == 34)
        #expect(ShellLayout.menuBottom(safeAreaBottom: 0) == 8)
    }
}
