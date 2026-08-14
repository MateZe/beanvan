import CryptoKit
import Foundation

public typealias EpochMilliseconds = Int64

public enum CoffeeProtocolError: Error, Equatable, Sendable {
    case tooManyScheduleEntries
}

public enum Weekday: Int, CaseIterable, Codable, Comparable, Sendable {
    case monday = 1
    case tuesday
    case wednesday
    case thursday
    case friday
    case saturday
    case sunday

    public static func < (lhs: Weekday, rhs: Weekday) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

public struct ScheduleTime: Codable, Equatable, Sendable {
    public let hour: Int
    public let minute: Int

    public init(hour: Int, minute: Int) {
        self.hour = hour
        self.minute = minute
    }
}

public struct ScheduleEntry: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public var time: ScheduleTime
    public var weekdays: Set<Weekday>
    public var lastEditedBy: UUID
    public var lastEditedAt: EpochMilliseconds

    public init(
        id: UUID,
        time: ScheduleTime,
        weekdays: Set<Weekday>,
        lastEditedBy: UUID,
        lastEditedAt: EpochMilliseconds
    ) {
        self.id = id
        self.time = time
        self.weekdays = weekdays
        self.lastEditedBy = lastEditedBy
        self.lastEditedAt = lastEditedAt
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case time
        case weekdays
        case lastEditedBy
        case lastEditedAt
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        time = try container.decode(ScheduleTime.self, forKey: .time)
        weekdays = Set(try container.decode([Weekday].self, forKey: .weekdays))
        lastEditedBy = try container.decode(UUID.self, forKey: .lastEditedBy)
        lastEditedAt = try container.decode(EpochMilliseconds.self, forKey: .lastEditedAt)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(time, forKey: .time)
        try container.encode(weekdays.sorted(), forKey: .weekdays)
        try container.encode(lastEditedBy, forKey: .lastEditedBy)
        try container.encode(lastEditedAt, forKey: .lastEditedAt)
    }
}

public struct Schedule: Codable, Equatable, Sendable {
    public static let maximumEntryCount = 3

    public let entries: [ScheduleEntry]
    public let lastModified: EpochMilliseconds

    public init(entries: [ScheduleEntry], lastModified: EpochMilliseconds) throws {
        guard entries.count <= Self.maximumEntryCount else {
            throw CoffeeProtocolError.tooManyScheduleEntries
        }
        self.entries = entries
        self.lastModified = lastModified
    }

    private enum CodingKeys: String, CodingKey {
        case entries
        case lastModified
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let entries = try container.decode([ScheduleEntry].self, forKey: .entries)
        guard entries.count <= Self.maximumEntryCount else {
            throw DecodingError.dataCorruptedError(
                forKey: .entries,
                in: container,
                debugDescription: "A schedule may contain at most \(Self.maximumEntryCount) entries"
            )
        }
        self.entries = entries
        lastModified = try container.decode(EpochMilliseconds.self, forKey: .lastModified)
    }
}

public struct VersionedSchedule: Equatable, Sendable {
    public var schedule: Schedule
    public var senderID: UUID

    public init(schedule: Schedule, senderID: UUID) {
        self.schedule = schedule
        self.senderID = senderID
    }
}

public func merge(local: VersionedSchedule, incoming: VersionedSchedule) -> VersionedSchedule {
    if incoming.schedule.lastModified > local.schedule.lastModified {
        return incoming
    }
    if incoming.schedule.lastModified < local.schedule.lastModified {
        return local
    }
    return incoming.senderID.uuidString < local.senderID.uuidString ? incoming : local
}

public struct Proposal: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let proposer: UUID
    public let createdAt: EpochMilliseconds
    public let expiresAt: EpochMilliseconds

    public init(
        id: UUID,
        proposer: UUID,
        createdAt: EpochMilliseconds,
        expiresAt: EpochMilliseconds
    ) {
        self.id = id
        self.proposer = proposer
        self.createdAt = createdAt
        self.expiresAt = expiresAt
    }
}

public struct Accept: Codable, Equatable, Sendable {
    public let proposalID: UUID
    public let accepter: UUID

    public init(proposalID: UUID, accepter: UUID) {
        self.proposalID = proposalID
        self.accepter = accepter
    }
}

public func quorumMet(proposal: Proposal, accepts: [Accept], threshold: Int) -> Bool {
    var participants = Set([proposal.proposer])
    for accept in accepts where accept.proposalID == proposal.id {
        participants.insert(accept.accepter)
    }
    return participants.count >= threshold
}

public func isExpired(_ proposal: Proposal, at timestamp: EpochMilliseconds) -> Bool {
    timestamp >= proposal.expiresAt
}

public func cooldownElapsed(
    lastProposalAt: EpochMilliseconds?,
    now: EpochMilliseconds,
    cooldown: EpochMilliseconds
) -> Bool {
    guard let lastProposalAt else { return true }
    guard now >= lastProposalAt else { return false }
    let (elapsed, overflow) = now.subtractingReportingOverflow(lastProposalAt)
    return overflow || elapsed >= max(0, cooldown)
}

public enum Payload: Codable, Equatable, Sendable {
    case schedule(Schedule)
    case proposal(Proposal)
    case accept(Accept)

    private enum CodingKeys: String, CodingKey {
        case type
        case value
    }

    private enum Kind: String, Codable {
        case schedule
        case proposal
        case accept
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .type) {
        case .schedule:
            self = .schedule(try container.decode(Schedule.self, forKey: .value))
        case .proposal:
            self = .proposal(try container.decode(Proposal.self, forKey: .value))
        case .accept:
            self = .accept(try container.decode(Accept.self, forKey: .value))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .schedule(schedule):
            try container.encode(Kind.schedule, forKey: .type)
            try container.encode(schedule, forKey: .value)
        case let .proposal(proposal):
            try container.encode(Kind.proposal, forKey: .type)
            try container.encode(proposal, forKey: .value)
        case let .accept(accept):
            try container.encode(Kind.accept, forKey: .type)
            try container.encode(accept, forKey: .value)
        }
    }
}

public struct Envelope: Codable, Equatable, Sendable {
    public static let maximumAge: EpochMilliseconds = 24 * 60 * 60 * 1_000

    public let senderID: UUID
    public let senderName: String
    public let timestamp: EpochMilliseconds
    public let payload: Payload
    public let signature: Data

    public init(
        senderID: UUID,
        senderName: String,
        timestamp: EpochMilliseconds,
        payload: Payload,
        signature: Data
    ) {
        self.senderID = senderID
        self.senderName = senderName
        self.timestamp = timestamp
        self.payload = payload
        self.signature = signature
    }

    public static func signed(
        senderID: UUID,
        senderName: String,
        timestamp: EpochMilliseconds,
        payload: Payload,
        teamPhrase: String = ""
    ) throws -> Envelope {
        let unsigned = UnsignedEnvelope(
            senderID: senderID,
            senderName: senderName,
            timestamp: timestamp,
            payload: payload
        )
        let authenticationCode = HMAC<SHA256>.authenticationCode(
            for: try CanonicalJSON.encode(unsigned),
            using: key(for: teamPhrase)
        )
        return Envelope(
            senderID: senderID,
            senderName: senderName,
            timestamp: timestamp,
            payload: payload,
            signature: Data(authenticationCode)
        )
    }

    public func verify(teamPhrase: String = "", now: EpochMilliseconds) -> Bool {
        let (oldestAllowed, underflow) = now.subtractingReportingOverflow(Self.maximumAge)
        guard underflow || timestamp >= oldestAllowed else { return false }

        let unsigned = UnsignedEnvelope(
            senderID: senderID,
            senderName: senderName,
            timestamp: timestamp,
            payload: payload
        )
        guard let bytes = try? CanonicalJSON.encode(unsigned) else { return false }
        return HMAC<SHA256>.isValidAuthenticationCode(
            signature,
            authenticating: bytes,
            using: Self.key(for: teamPhrase)
        )
    }

    public func canonicalJSONData() throws -> Data {
        try CanonicalJSON.encode(self)
    }

    private static func key(for teamPhrase: String) -> SymmetricKey {
        let material: Data
        if teamPhrase.isEmpty {
            material = Data("CuppaJoe CoffeeProtocol default key v1".utf8)
        } else {
            material = Data("CuppaJoe CoffeeProtocol team phrase v1\u{0}\(teamPhrase)".utf8)
        }
        return SymmetricKey(data: SHA256.hash(data: material))
    }
}

private struct UnsignedEnvelope: Codable {
    let senderID: UUID
    let senderName: String
    let timestamp: EpochMilliseconds
    let payload: Payload
}

private enum CanonicalJSON {
    static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }
}
