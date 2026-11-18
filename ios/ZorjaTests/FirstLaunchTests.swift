import Foundation
import Testing
@testable import Zorja

/// First launch and the two location states on Now (Figma: First launch and location).
struct FirstLaunchTests {
    // MARK: When Now has no place

    @Test func aSavedPlaceAlwaysHasAPlace() {
        for access in [LocationReader.Access.notAsked, .allowed, .off] {
            #expect(PlacesModel.locationProblem(hasPlace: true, access: access, hasReading: false,
                                                lastReading: .notFound) == nil)
        }
    }

    @Test func myLocationWithLocationOffHasNoPlace() {
        #expect(PlacesModel.locationProblem(hasPlace: false, access: .off, hasReading: false, lastReading: nil) == .off)
        // Never asked (all places removed after choosing one at first launch): the same screen,
        // and Turn On Location asks.
        #expect(PlacesModel.locationProblem(hasPlace: false, access: .notAsked, hasReading: false, lastReading: nil) == .off)
    }

    @Test func aFailedReadIsNotFound() {
        #expect(PlacesModel.locationProblem(hasPlace: false, access: .allowed, hasReading: false,
                                            lastReading: .notFound) == .notFound)
        // A read that is still running, or an earlier reading, is not a problem.
        #expect(PlacesModel.locationProblem(hasPlace: false, access: .allowed, hasReading: false, lastReading: nil) == nil)
        #expect(PlacesModel.locationProblem(hasPlace: false, access: .allowed, hasReading: true,
                                            lastReading: .notFound) == nil)
    }

    @MainActor @Test func locationForcedOffWithoutPlacesHasNoPlace() {
        let places = PlacesModel(store: PlaceStore(places: []), location: LocationReader(forcedOff: true),
                                 connectivity: Connectivity(), search: SamplePlaceSearch())
        #expect(places.locationProblem == .off)
        places.store.add(PlaceCandidate(name: "Tromsø", countryCode: "NO",
                                        coordinate: RoundedCoordinate(latitude: 69.65, longitude: 18.96),
                                        timeZone: "Europe/Oslo"))
        #expect(places.locationProblem == nil)
    }

    // MARK: The two Now states

    @Test func whereAreYou() throws {
        // It replaces any forecast: without a place there is nothing to forecast for.
        let forecast = try ScreenStateTests.forecast("promising-now")
        var input = ScreenInput(forecast: forecast, place: "Stockholm")
        input.location = .off
        let state = ScreenState.make(input, now: forecast.generatedAt)
        #expect(state.kind == .noPlace)
        #expect(state.sky == .off)
        #expect(state.status == nil)
        #expect(state.headline == Phrase("Where Are You?", emphasis: "You"))
        #expect(state.lead == "Location is off for Zorja, so it can’t check the sky where you are. Choose a place, or turn location on.")
        #expect(state.actions == [.choosePlace, .turnOnLocation])
        #expect(state.bottomLine == nil && state.retry == nil)
        #expect(state.tonight == nil && state.threeNights == nil)
        #expect(!state.showsPlace)
        #expect(!state.auroraActive)
    }

    @Test func cantFindYou() {
        var input = ScreenInput(problem: .offline, place: "My Location")
        input.location = .notFound
        let state = ScreenState.make(input, now: .now)
        #expect(state.kind == .locationNotFound)
        #expect(state.sky == .off)
        #expect(state.headline == Phrase("Can’t Find You."))
        #expect(state.lead == "Your phone couldn’t work out where you are. Try again in a moment, or choose a place.")
        #expect(state.actions == [.findMeAgain, .choosePlace])
        #expect(state.tonight == nil && state.threeNights == nil)
        #expect(state.showsPlace)
        #expect(!state.balancesLead)
    }

    @Test func buttonsMatchFigma() {
        #expect(NowAction.choosePlace.title == "Choose A Place" && NowAction.choosePlace.icon == .search)
        #expect(NowAction.turnOnLocation.title == "Turn On Location" && NowAction.turnOnLocation.icon == .location)
        #expect(NowAction.findMeAgain.title == "Try Again" && NowAction.findMeAgain.icon == .location)
    }

    @Test func forecastStatesHaveNoLocationButtons() throws {
        for sample in ScreenStateTests.samples {
            let forecast = try ScreenStateTests.forecast(sample.sample)
            let state = ScreenState.make(ScreenInput(forecast: forecast, place: "Stockholm"), now: forecast.generatedAt)
            #expect(state.actions.isEmpty)
            #expect(state.showsPlace)
        }
    }
}
