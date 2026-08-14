import Foundation

struct AppInstance: Sendable {
    static let appName = "CuppaJoe"

    let displayName: String
    let requestedPort: UInt16
    let teamPhrase: String
    let stateDirectory: URL
    let id: UUID

    static func load(
        arguments: [String] = Array(CommandLine.arguments.dropFirst()),
        username: String = NSUserName(),
        applicationSupportDirectory: URL? = nil,
        fileManager: FileManager = .default
    ) throws -> AppInstance {
        let options = try LaunchOptions.parse(arguments: arguments, defaultName: username)
        let applicationSupportDirectory = applicationSupportDirectory
            ?? fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let stateDirectory = applicationSupportDirectory
            .appendingPathComponent(appName, isDirectory: true)
            .appendingPathComponent(options.displayName, isDirectory: true)

        try fileManager.createDirectory(
            at: stateDirectory,
            withIntermediateDirectories: true,
            attributes: nil
        )

        let identityURL = stateDirectory.appendingPathComponent("instance-id", isDirectory: false)
        let id = try loadOrCreateID(at: identityURL, fileManager: fileManager)

        return AppInstance(
            displayName: options.displayName,
            requestedPort: options.port,
            teamPhrase: options.teamPhrase,
            stateDirectory: stateDirectory,
            id: id
        )
    }

    private static func loadOrCreateID(at url: URL, fileManager: FileManager) throws -> UUID {
        if fileManager.fileExists(atPath: url.path) {
            let value = try String(contentsOf: url, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard let id = UUID(uuidString: value) else {
                throw AppInstanceError.invalidIdentityFile(url)
            }
            return id
        }

        let id = UUID()
        try Data("\(id.uuidString)\n".utf8).write(to: url, options: .atomic)
        return id
    }
}

struct LaunchOptions: Equatable, Sendable {
    let displayName: String
    let port: UInt16
    let teamPhrase: String

    static func parse(arguments: [String], defaultName: String) throws -> LaunchOptions {
        var displayName = defaultName
        var port: UInt16 = 0
        var teamPhrase = ""
        var index = 0

        while index < arguments.count {
            let argument = arguments[index]
            guard argument == "--name" || argument == "--port" || argument == "--phrase" else {
                throw AppInstanceError.unknownArgument(argument)
            }
            guard index + 1 < arguments.count else {
                throw AppInstanceError.missingValue(argument)
            }

            let value = arguments[index + 1]
            if argument == "--name" {
                displayName = value
            } else if argument == "--port" {
                guard let parsedPort = UInt16(value) else {
                    throw AppInstanceError.invalidPort(value)
                }
                port = parsedPort
            } else {
                teamPhrase = value
            }
            index += 2
        }

        guard !displayName.isEmpty else {
            throw AppInstanceError.invalidName("Display name cannot be empty")
        }
        guard displayName != ".", displayName != "..", !displayName.contains("/") else {
            throw AppInstanceError.invalidName("Display name cannot contain a path component")
        }
        guard displayName.utf8.count <= 63 else {
            throw AppInstanceError.invalidName("Display name must be at most 63 UTF-8 bytes")
        }

        return LaunchOptions(displayName: displayName, port: port, teamPhrase: teamPhrase)
    }
}

enum AppInstanceError: LocalizedError, Equatable {
    case unknownArgument(String)
    case missingValue(String)
    case invalidName(String)
    case invalidPort(String)
    case invalidIdentityFile(URL)

    var errorDescription: String? {
        switch self {
        case .unknownArgument(let argument):
            "Unknown launch argument: \(argument)"
        case .missingValue(let argument):
            "Missing value for \(argument)"
        case .invalidName(let reason):
            reason
        case .invalidPort(let value):
            "Invalid port '\(value)'; expected an integer from 0 through 65535"
        case .invalidIdentityFile(let url):
            "Invalid instance identity at \(url.path)"
        }
    }
}
