import Foundation
import Testing
@testable import Beanvan

struct AppInstanceTests {
    @Test func launchOptionsUseUsernameAndAutomaticPortByDefault() throws {
        let options = try LaunchOptions.parse(arguments: [], defaultName: "alice")

        #expect(options == LaunchOptions(displayName: "alice", port: 0, teamPhrase: ""))
    }

    @Test func launchOptionsParseNameAndPort() throws {
        let options = try LaunchOptions.parse(
            arguments: ["--name", "Desk A", "--port", "43120", "--phrase", "beans"],
            defaultName: "alice"
        )

        #expect(options == LaunchOptions(displayName: "Desk A", port: 43120, teamPhrase: "beans"))
    }

    @Test func rejectsInvalidPortsAndNames() {
        #expect(throws: AppInstanceError.invalidPort("65536")) {
            try LaunchOptions.parse(arguments: ["--port", "65536"], defaultName: "alice")
        }
        #expect(throws: AppInstanceError.invalidName("Display name cannot contain a path component")) {
            try LaunchOptions.parse(arguments: ["--name", "../shared"], defaultName: "alice")
        }
    }

    @Test func instancesHaveSeparateDurableIdentities() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let firstA = try AppInstance.load(
            arguments: ["--name", "A"],
            username: "ignored",
            applicationSupportDirectory: root
        )
        let secondA = try AppInstance.load(
            arguments: ["--name", "A"],
            username: "ignored",
            applicationSupportDirectory: root
        )
        let instanceB = try AppInstance.load(
            arguments: ["--name", "B"],
            username: "ignored",
            applicationSupportDirectory: root
        )

        #expect(firstA.stateDirectory == root.appendingPathComponent("Beanvan/A"))
        #expect(instanceB.stateDirectory == root.appendingPathComponent("Beanvan/B"))
        #expect(firstA.id == secondA.id)
        #expect(firstA.id != instanceB.id)
        #expect(firstA.teamPhrase.isEmpty)
    }

    @Test func persistedSettingsLoadUnlessLaunchArgumentsOverrideThem() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Beanvan-AppSettingsTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let instance = AppInstance(
            displayName: "Launch Name",
            requestedPort: 0,
            teamPhrase: "launch phrase",
            stateDirectory: root,
            id: UUID()
        )
        try AppSettings(displayName: "Saved Name", teamPhrase: "saved phrase")
            .persist(for: instance)

        #expect(AppSettings.load(for: instance, arguments: []) == AppSettings(
            displayName: "Saved Name",
            teamPhrase: "saved phrase"
        ))
        #expect(AppSettings.load(
            for: instance,
            arguments: ["--name", "Launch Name", "--phrase", "launch phrase"]
        ) == AppSettings(displayName: "Launch Name", teamPhrase: "launch phrase"))
    }

    @Test func legacySettingsDefaultInterruptionPreferencesOn() throws {
        let data = Data(#"{"displayName":"Saved Name","teamPhrase":"beans"}"#.utf8)

        let settings = try JSONDecoder().decode(AppSettings.self, from: data)

        #expect(settings.avoidsFullScreenApps)
        #expect(settings.avoidsCalls)
        #expect(!settings.soundEnabled)
        #expect(settings.proposalNotificationsEnabled)
    }

    @Test func interruptionPreferencesRoundTrip() throws {
        let settings = AppSettings(
            displayName: "Saved Name",
            teamPhrase: "beans",
            avoidsFullScreenApps: false,
            avoidsCalls: false,
            soundEnabled: true,
            proposalNotificationsEnabled: false
        )

        let decoded = try JSONDecoder().decode(
            AppSettings.self,
            from: JSONEncoder().encode(settings)
        )

        #expect(decoded == settings)
    }
}
