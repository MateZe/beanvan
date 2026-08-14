import Foundation
import Network

@MainActor
final class PeerDiscovery {
    nonisolated static let serviceType = "_cuppajoe._tcp"
    nonisolated static let instanceIDKey = "instance-id"
    nonisolated static let displayNameKey = "display-name"

    private let instance: AppInstance
    private let queue: DispatchQueue
    private var listener: NWListener?
    private var browser: NWBrowser?

    init(instance: AppInstance) {
        self.instance = instance
        queue = DispatchQueue(label: "com.josipmusa.cuppajoe.peer-discovery.\(instance.id.uuidString)")
    }

    func start() throws {
        let displayName = instance.displayName
        let localInstanceID = instance.id
        let port = instance.requestedPort == 0
            ? NWEndpoint.Port.any
            : NWEndpoint.Port(rawValue: instance.requestedPort)!
        let listener = try NWListener(using: .tcp, on: port)
        let txtRecord = NWTXTRecord([
            Self.instanceIDKey: instance.id.uuidString,
            Self.displayNameKey: instance.displayName,
        ])

        listener.service = NWListener.Service(
            name: instance.displayName,
            type: Self.serviceType,
            txtRecord: txtRecord
        )
        listener.newConnectionHandler = { connection in
            connection.cancel()
        }
        listener.stateUpdateHandler = { [weak listener] state in
            switch state {
            case .ready:
                if let port = listener?.port {
                    print("CuppaJoe '\(displayName)' listening on port \(port.rawValue)")
                }
            case .failed(let error):
                print("CuppaJoe listener failed: \(error)")
            default:
                break
            }
        }

        let browser = NWBrowser(
            for: .bonjourWithTXTRecord(type: Self.serviceType, domain: nil),
            using: .tcp
        )
        browser.browseResultsChangedHandler = { results, _ in
            let peers = results.filter { result in
                guard let advertisedID = Self.instanceID(from: result) else { return false }
                return advertisedID != localInstanceID
            }
            let names = peers.compactMap(Self.displayName).sorted()
            print("CuppaJoe peers: \(names.isEmpty ? "none" : names.joined(separator: ", "))")
        }
        browser.stateUpdateHandler = { state in
            if case .failed(let error) = state {
                print("CuppaJoe browser failed: \(error)")
            }
        }

        self.listener = listener
        self.browser = browser
        listener.start(queue: queue)
        browser.start(queue: queue)
    }

    func stop() {
        browser?.cancel()
        listener?.cancel()
        browser = nil
        listener = nil
    }

    nonisolated static func instanceID(from result: NWBrowser.Result) -> UUID? {
        guard case .bonjour(let txtRecord) = result.metadata else { return nil }
        return txtRecord[instanceIDKey].flatMap(UUID.init(uuidString:))
    }

    nonisolated static func displayName(from result: NWBrowser.Result) -> String? {
        guard case .bonjour(let txtRecord) = result.metadata else { return nil }
        return txtRecord[displayNameKey]
    }
}
