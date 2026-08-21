import Foundation

struct AppSettings: Codable, Equatable, Sendable {
    var displayName: String
    var teamPhrase: String
    var avoidsFullScreenApps: Bool
    var avoidsCalls: Bool
    var soundEnabled: Bool
    var proposalNotificationsEnabled: Bool

    init(
        displayName: String,
        teamPhrase: String,
        avoidsFullScreenApps: Bool = true,
        avoidsCalls: Bool = true,
        soundEnabled: Bool = false,
        proposalNotificationsEnabled: Bool = true
    ) {
        self.displayName = displayName
        self.teamPhrase = teamPhrase
        self.avoidsFullScreenApps = avoidsFullScreenApps
        self.avoidsCalls = avoidsCalls
        self.soundEnabled = soundEnabled
        self.proposalNotificationsEnabled = proposalNotificationsEnabled
    }

    private enum CodingKeys: String, CodingKey {
        case displayName
        case teamPhrase
        case avoidsFullScreenApps
        case avoidsCalls
        case soundEnabled
        case proposalNotificationsEnabled
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        displayName = try container.decode(String.self, forKey: .displayName)
        teamPhrase = try container.decode(String.self, forKey: .teamPhrase)
        avoidsFullScreenApps = try container.decodeIfPresent(
            Bool.self,
            forKey: .avoidsFullScreenApps
        ) ?? true
        avoidsCalls = try container.decodeIfPresent(Bool.self, forKey: .avoidsCalls) ?? true
        soundEnabled = try container.decodeIfPresent(Bool.self, forKey: .soundEnabled) ?? false
        proposalNotificationsEnabled = try container.decodeIfPresent(
            Bool.self,
            forKey: .proposalNotificationsEnabled
        ) ?? true
    }

    static func load(for instance: AppInstance, arguments: [String]) -> AppSettings {
        let url = persistenceURL(for: instance)
        let persisted = try? JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
        let explicitlyNamed = arguments.contains("--name")
        let explicitlyPhrased = arguments.contains("--phrase")
        return AppSettings(
            displayName: explicitlyNamed
                ? instance.displayName
                : persisted?.displayName ?? instance.displayName,
            teamPhrase: explicitlyPhrased
                ? instance.teamPhrase
                : persisted?.teamPhrase ?? instance.teamPhrase,
            avoidsFullScreenApps: persisted?.avoidsFullScreenApps ?? true,
            avoidsCalls: persisted?.avoidsCalls ?? true,
            soundEnabled: persisted?.soundEnabled ?? false,
            proposalNotificationsEnabled: persisted?.proposalNotificationsEnabled ?? true
        )
    }

    func validated() throws -> AppSettings {
        let options = try LaunchOptions.parse(
            arguments: ["--name", displayName, "--phrase", teamPhrase],
            defaultName: displayName
        )
        return AppSettings(
            displayName: options.displayName,
            teamPhrase: options.teamPhrase,
            avoidsFullScreenApps: avoidsFullScreenApps,
            avoidsCalls: avoidsCalls,
            soundEnabled: soundEnabled,
            proposalNotificationsEnabled: proposalNotificationsEnabled
        )
    }

    func persist(for instance: AppInstance) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: Self.persistenceURL(for: instance), options: .atomic)
    }

    private static func persistenceURL(for instance: AppInstance) -> URL {
        instance.stateDirectory.appendingPathComponent("settings.json")
    }
}
