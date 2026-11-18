import Foundation
import Testing
@testable import Zorja

/// Tips (eye timer, checklist) and About (Data Sources, Privacy, Licences).
struct TipsAboutTests {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    // MARK: Eye timer

    @Test func idleReadsTwentyMinutes() {
        let phase = EyeTimer().phase(at: start)
        #expect(phase == .idle)
        #expect(EyeTimer.clock(phase) == "20:00")
        #expect(EyeTimer.progress(phase) == 0)
    }

    @Test func runningCountsDownFromTheStart() {
        let timer = EyeTimer(startedAt: start)
        #expect(EyeTimer.clock(timer.phase(at: start)) == "20:00")
        // Figma's running frame: 14:32 left.
        let figma = timer.phase(at: start.addingTimeInterval(5 * 60 + 28))
        #expect(EyeTimer.clock(figma) == "14:32")
        #expect(abs(EyeTimer.progress(figma) - 328.0 / 1200) < 1e-9)
        // Part of a second left still reads 00:01, not 00:00.
        #expect(EyeTimer.clock(timer.phase(at: start.addingTimeInterval(1199.5))) == "00:01")
    }

    @Test func readyAfterTwentyMinutesAndAfterLeavingTheApp() {
        let timer = EyeTimer(startedAt: start)
        #expect(timer.phase(at: start.addingTimeInterval(1200)) == .ready)
        // Counted from the start time, so an hour away still reads ready, not a stale count.
        let later = timer.phase(at: start.addingTimeInterval(3600))
        #expect(later == .ready)
        #expect(EyeTimer.clock(later) == "00:00")
        #expect(EyeTimer.progress(later) == 1)
    }

    @Test func aClockSetBackNeverShowsMoreThanTwentyMinutes() {
        let phase = EyeTimer(startedAt: start).phase(at: start.addingTimeInterval(-60))
        #expect(EyeTimer.clock(phase) == "20:00")
        #expect(EyeTimer.progress(phase) == 0)
    }

    @Test func stopAndStartAgain() {
        var timer = EyeTimer(startedAt: start)
        timer.stop()
        #expect(timer.phase(at: start.addingTimeInterval(60)) == .idle)
        let again = start.addingTimeInterval(2000)
        timer.start(at: again)
        #expect(EyeTimer.clock(timer.phase(at: again)) == "20:00")
    }

    @Test func cardWordsFollowFigma() {
        let running = EyeTimer.Phase.running(remaining: 872, progress: 0.27)
        #expect(EyeTimerCard.title(.idle) == "Let Your Eyes Adjust")
        #expect(EyeTimerCard.title(running) == "Eyes Adjusting")
        #expect(EyeTimerCard.title(.ready) == "Your Eyes Are Ready")
        #expect(EyeTimerCard.message(.ready) == "Look up. Faint aurora can look grey at first.")
        #expect(EyeTimerCard.spokenTime(running) == "14 minutes 32 seconds left")
    }

    @Test func checklistStoresOnlyThreeFixedKeys() {
        #expect(BeforeYouGoCard.keys.count == BeforeYouGoCard.labels.count)
        #expect(Set(BeforeYouGoCard.keys).count == 3)
        #expect(BeforeYouGoCard.keys.allSatisfy { $0.hasPrefix("tips.checklist.") })
    }

    // MARK: About

    private func text(_ section: AboutScreen.Section) -> String {
        AboutScreen.entries(section).map { "\($0.title) \(String($0.body.characters))" }.joined(separator: " ")
    }

    private func links(_ section: AboutScreen.Section) -> [URL] {
        AboutScreen.entries(section).flatMap { $0.body.runs.compactMap(\.link) }
    }

    @Test func dataSourcesNameNoaaAndMetNorwayWithItsLicenceLinked() {
        let sources = text(.sources)
        #expect(sources.contains("NOAA Space Weather Prediction Center"))
        #expect(sources.contains("MET Norway"))
        #expect(sources.contains("CC BY 4.0"))
        #expect(links(.sources) == [URL(string: "https://creativecommons.org/licenses/by/4.0/")!])
    }

    @Test func privacyMatchesTwoDecimalRounding() {
        // Coordinates are rounded to two decimals (at most about 0.6 km off), not 100 m.
        let privacy = text(.privacy)
        #expect(privacy.contains("about 1 km"))
        #expect(!privacy.contains("100 m"))
        #expect(privacy.contains("within 6 hours"))
        #expect(privacy.contains("No account, no ads and no analytics."))
    }

    @Test func fontLicenceIsBundledAndShownInFull() throws {
        let licence = try #require(AboutScreen.fontLicence)
        #expect(licence.contains("Copyright 2021 The Outfit Project Authors"))
        #expect(licence.contains("SIL OPEN FONT LICENSE Version 1.1"))
        #expect(text(.licences).contains("SIL Open Font License 1.1"))
    }
}
