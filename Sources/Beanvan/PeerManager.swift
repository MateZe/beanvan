import CoffeeProtocol
import Combine
import Foundation
@preconcurrency import Network
import os

struct PresentPeer: Identifiable, Equatable, Sendable {
    let id: UUID
    let name: String
    let lastSeen: Date
}

@MainActor
final class PeerManager: ObservableObject {
    @Published private(set) var presentPeers: [PresentPeer] = []

    private var envelopeHandlers: [(Envelope) -> Void] = []
    private var connectionReadyHandlers: [() -> Void] = []

    private var core: PeerNetworkingCore
    private var isStarted = false
    private var instance: AppInstance
    private var advertisingEnabled = true

    init(instance: AppInstance, teamPhrase: String = "") {
        self.instance = instance
        core = PeerNetworkingCore(
            instance: instance,
            teamPhrase: teamPhrase,
            advertisingEnabled: true
        )
        installCoreCallbacks()
    }

    private func installCoreCallbacks() {
        let source = core
        source.onPresentPeers = { [weak self, weak source] peers in
            Task { @MainActor [weak self] in
                guard let self, let source, self.core === source else { return }
                self.presentPeers = peers
            }
        }
        source.onEnvelope = { [weak self, weak source] envelope in
            Task { @MainActor [weak self] in
                guard let self, let source, self.core === source else { return }
                self.envelopeHandlers.forEach { $0(envelope) }
            }
        }
        source.onConnectionReady = { [weak self, weak source] in
            Task { @MainActor [weak self] in
                guard let self, let source, self.core === source else { return }
                self.connectionReadyHandlers.forEach { $0() }
            }
        }
    }

    func start() throws {
        try core.start()
        isStarted = true
    }

    func stop() {
        core.stop()
        isStarted = false
    }

    func reconfigure(instance: AppInstance) throws {
        let wasStarted = isStarted
        let oldInstance = self.instance
        core.stop()
        presentPeers = []
        core = PeerNetworkingCore(
            instance: instance,
            teamPhrase: instance.teamPhrase,
            advertisingEnabled: advertisingEnabled
        )
        installCoreCallbacks()
        if wasStarted {
            do {
                try core.start()
            } catch {
                core.stop()
                core = PeerNetworkingCore(
                    instance: oldInstance,
                    teamPhrase: oldInstance.teamPhrase,
                    advertisingEnabled: advertisingEnabled
                )
                installCoreCallbacks()
                try? core.start()
                throw error
            }
        }
        self.instance = instance
    }

    func setAdvertisingEnabled(_ enabled: Bool) {
        advertisingEnabled = enabled
        core.setAdvertisingEnabled(enabled)
    }

    func send(_ envelope: Envelope) {
        core.send(envelope)
    }

    func addEnvelopeHandler(_ handler: @escaping (Envelope) -> Void) {
        envelopeHandlers.append(handler)
    }

    func addConnectionReadyHandler(_ handler: @escaping () -> Void) {
        connectionReadyHandlers.append(handler)
    }
}

private final class PeerNetworkingCore: @unchecked Sendable {
    nonisolated static let serviceType = "_beanvan._tcp"
    nonisolated static let displayNameKey = "displayName"
    nonisolated static let phraseHashKey = "phraseHash"

    var onPresentPeers: (@Sendable ([PresentPeer]) -> Void)?
    var onEnvelope: (@Sendable (Envelope) -> Void)?
    var onConnectionReady: (@Sendable () -> Void)?

    private let instance: AppInstance
    private let teamPhrase: String
    private let phraseHash: String
    private let queue: DispatchQueue
    private let logger = Logger(subsystem: "com.josipmusa.beanvan", category: "peers")

    private var listener: NWListener?
    private var browser: NWBrowser?
    private var discovered: [UUID: DiscoveredPeer] = [:]
    private var visiblePeerIDs = Set<UUID>()
    private var connections: [ObjectIdentifier: ManagedConnection] = [:]
    private var connectionByPeer: [UUID: ObjectIdentifier] = [:]
    private var retryAttempts: [UUID: Int] = [:]
    private var retryWork: [UUID: DispatchWorkItem] = [:]
    private var advertisingEnabled = true

    init(instance: AppInstance, teamPhrase: String, advertisingEnabled: Bool) {
        self.instance = instance
        self.teamPhrase = teamPhrase
        self.advertisingEnabled = advertisingEnabled
        phraseHash = TeamPhrase.shortHash(for: teamPhrase)
        queue = DispatchQueue(label: "com.josipmusa.beanvan.peer-manager.\(instance.id.uuidString)")
    }

    func start() throws {
        try queue.sync {
            guard listener == nil, browser == nil else { return }

            let browser = NWBrowser(
                for: .bonjourWithTXTRecord(type: Self.serviceType, domain: nil),
                using: .tcp
            )
            browser.browseResultsChangedHandler = { [weak self] results, _ in
                self?.browseResultsChanged(results)
            }
            browser.stateUpdateHandler = { [weak self] state in
                self?.browserStateChanged(state)
            }
            self.browser = browser
            if advertisingEnabled {
                try startListener()
            }
            browser.start(queue: queue)
        }
    }

    func setAdvertisingEnabled(_ enabled: Bool) {
        queue.async { [self] in
            guard advertisingEnabled != enabled else { return }
            advertisingEnabled = enabled
            if enabled {
                do {
                    try startListener()
                } catch {
                    logger.error("Failed to resume Bonjour advertising: \(error.localizedDescription, privacy: .public)")
                }
            } else {
                listener?.cancel()
                listener = nil
            }
        }
    }

    func stop() {
        var listenerCancellation: DispatchSemaphore?
        queue.sync { [self] in
            retryWork.values.forEach { $0.cancel() }
            retryWork.removeAll()
            connections.values.forEach { $0.connection.cancel() }
            connections.removeAll()
            connectionByPeer.removeAll()
            browser?.cancel()
            if let listener {
                let cancellation = DispatchSemaphore(value: 0)
                listenerCancellation = cancellation
                listener.stateUpdateHandler = { state in
                    if case .cancelled = state {
                        cancellation.signal()
                    }
                }
                listener.cancel()
            }
            browser = nil
            listener = nil
            discovered.removeAll()
            visiblePeerIDs.removeAll()
            publishPresentPeers()
        }
        if listenerCancellation?.wait(timeout: .now() + 2) == .timedOut {
            logger.warning("Timed out waiting for the Bonjour listener to stop")
        }
    }

    private func startListener() throws {
        guard listener == nil else { return }
        let port = instance.requestedPort == 0
            ? NWEndpoint.Port.any
            : NWEndpoint.Port(rawValue: instance.requestedPort)!
        let listener = try NWListener(using: .tcp, on: port)
        listener.service = NWListener.Service(
            name: instance.id.uuidString,
            type: Self.serviceType,
            txtRecord: NWTXTRecord([
                Self.displayNameKey: instance.displayName,
                Self.phraseHashKey: phraseHash,
            ])
        )
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.stateUpdateHandler = { [weak self, weak listener] state in
            guard let listener else { return }
            self?.listenerStateChanged(state, listener: listener)
        }
        self.listener = listener
        listener.start(queue: queue)
    }

    func send(_ envelope: Envelope) {
        queue.async { [self] in
            guard envelope.senderID == instance.id else {
                logger.error("Refusing to send an envelope with a non-local sender UUID")
                return
            }
            guard envelope.verify(teamPhrase: teamPhrase, now: Self.nowMilliseconds()) else {
                logger.error("Refusing to send an invalid or stale envelope")
                return
            }
            guard let frame = try? LengthPrefixedJSON.frame(envelope.canonicalJSONData()) else {
                logger.error("Failed to encode an envelope")
                return
            }
            for managed in connections.values where managed.isReady {
                managed.connection.send(content: frame, completion: .contentProcessed { [weak self] error in
                    if let error {
                        self?.logger.error("Envelope send failed: \(error.localizedDescription, privacy: .public)")
                    }
                })
            }
        }
    }

    private func listenerStateChanged(_ state: NWListener.State, listener: NWListener) {
        guard self.listener === listener else { return }
        switch state {
        case .ready:
            if let port = listener.port {
                logger.info("Listening as \(self.instance.id.uuidString, privacy: .public) on port \(port.rawValue)")
            }
        case .failed(let error):
            logger.error("Listener failed: \(error.localizedDescription, privacy: .public)")
            listener.cancel()
            self.listener = nil
        default:
            break
        }
    }

    private func browserStateChanged(_ state: NWBrowser.State) {
        if case .failed(let error) = state {
            logger.error("Browser failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func browseResultsChanged(_ results: Set<NWBrowser.Result>) {
        let now = Date()
        var visibleIDs = Set<UUID>()

        for result in results {
            guard let peer = Self.peer(from: result, expectedPhraseHash: phraseHash),
                  peer.id != instance.id else { continue }
            visibleIDs.insert(peer.id)
            discovered[peer.id] = DiscoveredPeer(
                id: peer.id,
                name: peer.name,
                endpoint: result.endpoint,
                lastSeen: now
            )
            if connectionByPeer[peer.id] == nil {
                connect(to: peer.id)
            }
        }
        visiblePeerIDs = visibleIDs

        let departedIDs = discovered.keys.filter {
            !visibleIDs.contains($0) && connectionByPeer[$0] == nil
        }
        for id in departedIDs {
            discovered.removeValue(forKey: id)
            retryWork.removeValue(forKey: id)?.cancel()
            retryAttempts.removeValue(forKey: id)
        }
        publishPresentPeers()
    }

    private static func peer(
        from result: NWBrowser.Result,
        expectedPhraseHash: String
    ) -> (id: UUID, name: String)? {
        guard case .service(let serviceName, _, _, _) = result.endpoint,
              let id = UUID(uuidString: serviceName),
              case .bonjour(let txtRecord) = result.metadata,
              txtRecord[phraseHashKey] == expectedPhraseHash,
              let name = txtRecord[displayNameKey],
              !name.isEmpty else { return nil }
        return (id, name)
    }

    private func connect(to peerID: UUID) {
        guard let peer = discovered[peerID], connectionByPeer[peerID] == nil else { return }
        retryWork.removeValue(forKey: peerID)?.cancel()
        let connection = NWConnection(to: peer.endpoint, using: .tcp)
        let managed = ManagedConnection(connection: connection, direction: .outgoing, peerID: peerID)
        install(managed)
    }

    private func accept(_ connection: NWConnection) {
        install(ManagedConnection(connection: connection, direction: .incoming, peerID: nil))
    }

    private func install(_ managed: ManagedConnection) {
        let identifier = ObjectIdentifier(managed)
        connections[identifier] = managed

        if let peerID = managed.peerID, !register(managed, for: peerID) {
            return
        }

        managed.connection.stateUpdateHandler = { [weak self, weak managed] state in
            guard let self, let managed else { return }
            self.connectionStateChanged(state, for: managed)
        }
        managed.connection.start(queue: queue)
    }

    @discardableResult
    private func register(_ candidate: ManagedConnection, for peerID: UUID) -> Bool {
        let candidateID = ObjectIdentifier(candidate)
        candidate.peerID = peerID

        guard let existingID = connectionByPeer[peerID],
              let existing = connections[existingID],
              existing !== candidate else {
            connectionByPeer[peerID] = candidateID
            return true
        }

        let preferred = ConnectionPolicy.preferredDirection(local: instance.id, remote: peerID)
        if candidate.direction == preferred && existing.direction != preferred {
            connectionByPeer[peerID] = candidateID
            cancel(existing, retry: false)
            return true
        }

        logger.debug("Discarding duplicate connection for \(peerID.uuidString, privacy: .public)")
        cancel(candidate, retry: false)
        return false
    }

    private func connectionStateChanged(_ state: NWConnection.State, for managed: ManagedConnection) {
        switch state {
        case .ready:
            managed.isReady = true
            if let peerID = managed.peerID {
                retryAttempts[peerID] = 0
            }
            receiveNext(on: managed)
            onConnectionReady?()
        case .failed(let error):
            logger.info("Peer connection failed: \(error.localizedDescription, privacy: .public)")
            cancel(managed, retry: managed.direction == .outgoing)
        case .cancelled:
            remove(managed, retry: managed.direction == .outgoing)
        default:
            break
        }
    }

    private func receiveNext(on managed: ManagedConnection) {
        managed.connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) {
            [weak self, weak managed] content, _, isComplete, error in
            guard let self, let managed else { return }
            if let content, !content.isEmpty {
                do {
                    for data in try managed.decoder.append(content) {
                        self.receiveEnvelope(data, on: managed)
                    }
                } catch {
                    self.logger.error("Dropping connection with an invalid frame: \(error.localizedDescription, privacy: .public)")
                    self.cancel(managed, retry: managed.direction == .outgoing)
                    return
                }
            }
            if let error {
                self.logger.info("Peer receive failed: \(error.localizedDescription, privacy: .public)")
                self.cancel(managed, retry: managed.direction == .outgoing)
            } else if isComplete {
                self.cancel(managed, retry: managed.direction == .outgoing)
            } else {
                self.receiveNext(on: managed)
            }
        }
    }

    private func receiveEnvelope(_ data: Data, on managed: ManagedConnection) {
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: data),
              envelope.verify(teamPhrase: teamPhrase, now: Self.nowMilliseconds()) else {
            logger.error("Dropped an envelope with an invalid signature, timestamp, or JSON body")
            return
        }
        guard envelope.senderID != instance.id else {
            logger.error("Dropped an envelope claiming the local instance UUID")
            return
        }
        if let expectedID = managed.peerID, expectedID != envelope.senderID {
            logger.error("Peer UUID does not match its Bonjour advertisement")
            cancel(managed, retry: false)
            return
        }
        guard register(managed, for: envelope.senderID) else { return }

        let existing = discovered[envelope.senderID]
        discovered[envelope.senderID] = DiscoveredPeer(
            id: envelope.senderID,
            name: envelope.senderName,
            endpoint: existing?.endpoint ?? managed.connection.endpoint,
            lastSeen: Date()
        )
        publishPresentPeers()
        onEnvelope?(envelope)
    }

    private func cancel(_ managed: ManagedConnection, retry: Bool) {
        managed.connection.stateUpdateHandler = nil
        managed.connection.cancel()
        remove(managed, retry: retry)
    }

    private func remove(_ managed: ManagedConnection, retry: Bool) {
        let identifier = ObjectIdentifier(managed)
        guard connections.removeValue(forKey: identifier) != nil else { return }
        managed.isReady = false
        if let peerID = managed.peerID, connectionByPeer[peerID] == identifier {
            connectionByPeer.removeValue(forKey: peerID)
            if !visiblePeerIDs.contains(peerID) {
                discovered.removeValue(forKey: peerID)
                retryWork.removeValue(forKey: peerID)?.cancel()
                retryAttempts.removeValue(forKey: peerID)
            } else if retry {
                scheduleRetry(for: peerID)
            }
        }
        publishPresentPeers()
    }

    private func scheduleRetry(for peerID: UUID) {
        guard visiblePeerIDs.contains(peerID), discovered[peerID] != nil,
              retryWork[peerID] == nil else { return }
        let attempt = retryAttempts[peerID, default: 0]
        retryAttempts[peerID] = attempt + 1
        let delay = min(pow(2.0, Double(attempt)), 30.0)
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.retryWork.removeValue(forKey: peerID)
            self.connect(to: peerID)
        }
        retryWork[peerID] = work
        queue.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func publishPresentPeers() {
        let peers = discovered.values
            .filter { visiblePeerIDs.contains($0.id) }
            .map { PresentPeer(id: $0.id, name: $0.name, lastSeen: $0.lastSeen) }
            .sorted {
                let order = $0.name.localizedCaseInsensitiveCompare($1.name)
                return order == .orderedSame ? $0.id.uuidString < $1.id.uuidString : order == .orderedAscending
            }
        onPresentPeers?(peers)
    }

    private static func nowMilliseconds() -> EpochMilliseconds {
        EpochMilliseconds(Date().timeIntervalSince1970 * 1_000)
    }
}

private struct DiscoveredPeer {
    let id: UUID
    let name: String
    let endpoint: NWEndpoint
    let lastSeen: Date
}

private final class ManagedConnection: @unchecked Sendable {
    let connection: NWConnection
    let direction: ConnectionDirection
    var peerID: UUID?
    var decoder = LengthPrefixedJSON.Decoder()
    var isReady = false

    init(connection: NWConnection, direction: ConnectionDirection, peerID: UUID?) {
        self.connection = connection
        self.direction = direction
        self.peerID = peerID
    }
}

enum ConnectionDirection {
    case incoming
    case outgoing
}

enum ConnectionPolicy {
    static func preferredDirection(local: UUID, remote: UUID) -> ConnectionDirection {
        local.uuidString < remote.uuidString ? .outgoing : .incoming
    }
}

enum LengthPrefixedJSON {
    static let maximumPayloadSize = 1_048_576

    enum FrameError: LocalizedError, Equatable {
        case emptyPayload
        case payloadTooLarge(Int)

        var errorDescription: String? {
            switch self {
            case .emptyPayload:
                "A frame cannot be empty"
            case .payloadTooLarge(let size):
                "Frame size \(size) exceeds the \(LengthPrefixedJSON.maximumPayloadSize)-byte limit"
            }
        }
    }

    static func frame(_ payload: Data) throws -> Data {
        guard !payload.isEmpty else { throw FrameError.emptyPayload }
        guard payload.count <= maximumPayloadSize else { throw FrameError.payloadTooLarge(payload.count) }
        let length = UInt32(payload.count)
        var result = Data([
            UInt8((length >> 24) & 0xff),
            UInt8((length >> 16) & 0xff),
            UInt8((length >> 8) & 0xff),
            UInt8(length & 0xff),
        ])
        result.append(payload)
        return result
    }

    struct Decoder {
        private var buffer = Data()

        mutating func append(_ data: Data) throws -> [Data] {
            buffer.append(data)
            var payloads: [Data] = []

            while buffer.count >= 4 {
                let length = buffer.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
                guard length > 0 else { throw FrameError.emptyPayload }
                guard length <= maximumPayloadSize else { throw FrameError.payloadTooLarge(Int(length)) }
                let frameSize = 4 + Int(length)
                guard buffer.count >= frameSize else { break }
                payloads.append(buffer.subdata(in: 4..<frameSize))
                buffer.removeSubrange(0..<frameSize)
            }
            return payloads
        }
    }
}
