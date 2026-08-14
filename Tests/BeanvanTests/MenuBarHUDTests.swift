import Foundation
import Testing
@testable import Beanvan

struct MenuBarHUDTests {
    @Test func iconMovesFromIdleToSteamAndBackAtFire() {
        let fireDate = Date(timeIntervalSince1970: 1_000)

        #expect(!MenuBarIconState.showsSteam(
            at: fireDate.addingTimeInterval(-301),
            nextFireDate: fireDate,
            peerCount: 1,
            isSkippingToday: false
        ))
        #expect(MenuBarIconState.showsSteam(
            at: fireDate.addingTimeInterval(-300),
            nextFireDate: fireDate,
            peerCount: 1,
            isSkippingToday: false
        ))
        #expect(!MenuBarIconState.showsSteam(
            at: fireDate,
            nextFireDate: fireDate,
            peerCount: 1,
            isSkippingToday: false
        ))
    }

    @Test func iconGatesSteamAndDimsWhenSkipping() {
        let now = Date(timeIntervalSince1970: 1_000)
        let fireDate = now.addingTimeInterval(60)

        #expect(!MenuBarIconState.showsSteam(
            at: now,
            nextFireDate: fireDate,
            peerCount: 0,
            isSkippingToday: false
        ))
        #expect(!MenuBarIconState.showsSteam(
            at: now,
            nextFireDate: fireDate,
            peerCount: 1,
            isSkippingToday: true
        ))
        #expect(MenuBarIconState.truckOpacity(isSkippingToday: false) == 1)
        #expect(MenuBarIconState.truckOpacity(isSkippingToday: true) == 0.4)
    }

    @Test func timeInputKeepsTwoDigitsAndNormalizesComponents() {
        #expect(TimeComponentInput.digits(from: "1a2b3") == "12")

        let hour = TimeComponentInput.normalized("12", maximum: 23, fallback: 10)
        #expect(hour.value == 12)
        #expect(hour.text == "12")

        let singleMinute = TimeComponentInput.normalized("5", maximum: 59, fallback: 30)
        #expect(singleMinute.value == 5)
        #expect(singleMinute.text == "05")

        let clampedHour = TimeComponentInput.normalized("29", maximum: 23, fallback: 10)
        #expect(clampedHour.value == 23)
        #expect(clampedHour.text == "23")

        let empty = TimeComponentInput.normalized("", maximum: 59, fallback: 30)
        #expect(empty.value == 30)
        #expect(empty.text == "30")
    }
}
