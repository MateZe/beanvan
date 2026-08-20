import Foundation
import Testing
@testable import Beanvan

struct OverlayControllerTests {
    @Test func bannerUsesTriggerTimeInLocalCalendar() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "Europe/Sarajevo"))
        let triggerDate = try #require(calendar.date(from: DateComponents(
            year: 2026,
            month: 8,
            day: 20,
            hour: 14,
            minute: 7
        )))

        #expect(BannerLabel.text(for: triggerDate, calendar: calendar) == "☕ 14:07")
    }
}
