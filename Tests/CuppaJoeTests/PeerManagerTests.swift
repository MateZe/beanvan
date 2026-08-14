import Foundation
import Testing
@testable import CuppaJoe

struct PeerManagerTests {
    private let lower = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    private let higher = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!

    @Test func bothSidesPreferTheSamePhysicalConnection() {
        #expect(ConnectionPolicy.preferredDirection(local: lower, remote: higher) == .outgoing)
        #expect(ConnectionPolicy.preferredDirection(local: higher, remote: lower) == .incoming)
    }

    @Test func framingHandlesSplitAndCoalescedTCPReads() throws {
        let first = Data("{\"one\":1}".utf8)
        let second = Data("{\"two\":2}".utf8)
        let bytes = try LengthPrefixedJSON.frame(first) + LengthPrefixedJSON.frame(second)
        var decoder = LengthPrefixedJSON.Decoder()

        #expect(try decoder.append(bytes.prefix(3)).isEmpty)
        #expect(try decoder.append(bytes.dropFirst(3).prefix(8)).isEmpty)
        #expect(try decoder.append(bytes.dropFirst(11)) == [first, second])
    }

    @Test func framingRejectsEmptyAndOversizedPayloads() {
        #expect(throws: LengthPrefixedJSON.FrameError.emptyPayload) {
            try LengthPrefixedJSON.frame(Data())
        }
        #expect(throws: LengthPrefixedJSON.FrameError.payloadTooLarge(
            LengthPrefixedJSON.maximumPayloadSize + 1
        )) {
            try LengthPrefixedJSON.frame(Data(count: LengthPrefixedJSON.maximumPayloadSize + 1))
        }
    }
}
