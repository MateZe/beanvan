import CoffeeProtocol
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

    @Test func timePickerRoundTripsScheduleTime() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 3_600)!
        let expected = ScheduleTime(hour: 7, minute: 5)

        let date = ScheduleTimePicker.date(for: expected, calendar: calendar)

        #expect(ScheduleTimePicker.time(from: date, calendar: calendar) == expected)
    }

    @Test func localProposalIsDisplayedBeforeAnOlderRemoteProposal() {
        let localID = UUID()
        let remoteID = UUID()
        let remote = activeProposal(proposer: remoteID, createdAt: 1_000)
        let local = activeProposal(proposer: localID, createdAt: 2_000)

        let displayed = ProposalDisplay.selected(
            from: [remote, local],
            localInstanceID: localID
        )

        #expect(displayed?.id == local.id)
    }

    private func activeProposal(
        proposer: UUID,
        createdAt: EpochMilliseconds
    ) -> ActiveCoffeeProposal {
        ActiveCoffeeProposal(
            proposal: Proposal(
                id: UUID(),
                proposer: proposer,
                createdAt: createdAt,
                expiresAt: createdAt + 5 * 60 * 1_000
            ),
            proposerName: "Test",
            participantIDs: [proposer]
        )
    }
}
