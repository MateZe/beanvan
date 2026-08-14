import Foundation
import Testing
@testable import CuppaJoe

struct AppInstanceTests {
    @Test func launchOptionsUseUsernameAndAutomaticPortByDefault() throws {
        let options = try LaunchOptions.parse(arguments: [], defaultName: "alice")

        #expect(options == LaunchOptions(displayName: "alice", port: 0))
    }

    @Test func launchOptionsParseNameAndPort() throws {
        let options = try LaunchOptions.parse(
            arguments: ["--name", "Desk A", "--port", "43120"],
            defaultName: "alice"
        )

        #expect(options == LaunchOptions(displayName: "Desk A", port: 43120))
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

        #expect(firstA.stateDirectory == root.appendingPathComponent("CuppaJoe/A"))
        #expect(instanceB.stateDirectory == root.appendingPathComponent("CuppaJoe/B"))
        #expect(firstA.id == secondA.id)
        #expect(firstA.id != instanceB.id)
    }
}
