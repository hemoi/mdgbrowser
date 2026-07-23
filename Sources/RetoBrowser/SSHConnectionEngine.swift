@preconcurrency import Citadel
import Crypto
import CryptoKit
import Foundation
import Network
import NIOCore
@preconcurrency import NIOSSH

enum SSHConnectionEngineError: LocalizedError {
    case hostKeyRejected
    case notConnected
    case unsupportedPrivateKeyType(String)

    var errorDescription: String? {
        switch self {
        case .hostKeyRejected:
            "The SSH server host key was not trusted."
        case .notConnected:
            "The terminal is not connected."
        case .unsupportedPrivateKeyType(let type):
            "Private key type \(type) is not supported. Use an Ed25519 or RSA OpenSSH key."
        }
    }
}

typealias SSHHostKeyApproval = @Sendable (
    _ fingerprint: String,
    _ expectedFingerprint: String?
) async -> Bool

protocol SSHConnectionEngineProtocol: AnyObject, Sendable {
    func run(
        profile: SSHProfile,
        startupCommand: String?,
        approveHostKey: @escaping SSHHostKeyApproval,
        onOutput: @escaping @Sendable ([UInt8]) async -> Void,
        onReady: @escaping @Sendable () async -> Void
    ) async throws

    func send(_ bytes: [UInt8]) async throws
    func resize(cols: Int, rows: Int, pixelWidth: Int, pixelHeight: Int) async
    func disconnect() async
}

extension SSHConnectionEngineProtocol {
    /// Backwards-compatible entry point: the startup command defaults to the
    /// profile's fixed tmux attach/create behavior.
    func run(
        profile: SSHProfile,
        approveHostKey: @escaping SSHHostKeyApproval,
        onOutput: @escaping @Sendable ([UInt8]) async -> Void,
        onReady: @escaping @Sendable () async -> Void
    ) async throws {
        try await run(
            profile: profile,
            startupCommand: profile.tmuxStartupCommand,
            approveHostKey: approveHostKey,
            onOutput: onOutput,
            onReady: onReady
        )
    }
}

private struct SSHClientBox: @unchecked Sendable {
    let value: SSHClient
}

private struct TTYWriterBox: @unchecked Sendable {
    let value: TTYStdinWriter
}

private struct EventLoopPromiseBox: @unchecked Sendable {
    let value: EventLoopPromise<Void>
}

private struct SSHAuthenticationMethodBox: @unchecked Sendable {
    let value: SSHAuthenticationMethod
}

private final class PinnedHostKeyDelegate: NIOSSHClientServerAuthenticationDelegate, @unchecked Sendable {
    private let expectedFingerprint: String?
    private let approval: SSHHostKeyApproval

    init(expectedFingerprint: String?, approval: @escaping SSHHostKeyApproval) {
        self.expectedFingerprint = expectedFingerprint
        self.approval = approval
    }

    func validateHostKey(
        hostKey: NIOSSHPublicKey,
        validationCompletePromise: EventLoopPromise<Void>
    ) {
        let fingerprint = Self.fingerprint(for: hostKey)
        if fingerprint == expectedFingerprint {
            validationCompletePromise.succeed(())
            return
        }

        let promise = EventLoopPromiseBox(value: validationCompletePromise)
        Task {
            if await approval(fingerprint, expectedFingerprint) {
                promise.value.succeed(())
            } else {
                promise.value.fail(SSHConnectionEngineError.hostKeyRejected)
            }
        }
    }

    private static func fingerprint(for hostKey: NIOSSHPublicKey) -> String {
        var buffer = ByteBufferAllocator().buffer(capacity: 512)
        hostKey.write(to: &buffer)
        let digest = SHA256.hash(data: Data(buffer.readableBytesView))
        let base64 = Data(digest).base64EncodedString().replacingOccurrences(of: "=", with: "")
        return "SHA256:\(base64)"
    }
}

final class SSHConnectionEngine: SSHConnectionEngineProtocol, @unchecked Sendable {
    typealias OutputHandler = @Sendable ([UInt8]) async -> Void
    typealias ReadyHandler = @Sendable () async -> Void

    private let stateLock = NSLock()
    private var client: SSHClientBox?
    private var writer: TTYWriterBox?

    func run(
        profile: SSHProfile,
        startupCommand: String?,
        approveHostKey: @escaping SSHHostKeyApproval,
        onOutput: @escaping OutputHandler,
        onReady: @escaping ReadyHandler
    ) async throws {
        let profile = profile.normalized
        let settings = try Self.clientSettings(for: profile, approveHostKey: approveHostKey)

        let connectedClient = try await SSHClient.connect(to: settings)
        if Task.isCancelled {
            try? await connectedClient.close()
            throw CancellationError()
        }
        setClient(connectedClient)

        let request = SSHChannelRequestEvent.PseudoTerminalRequest(
            wantReply: true,
            term: profile.resolvedTerminalType,
            terminalCharacterWidth: 100,
            terminalRowHeight: 30,
            terminalPixelWidth: 0,
            terminalPixelHeight: 0,
            terminalModes: SSHTerminalModes([.ECHO: 1])
        )
        let environment = [
            SSHChannelRequestEvent.EnvironmentRequest(
                wantReply: false,
                name: "LANG",
                value: "en_US.UTF-8"
            ),
            SSHChannelRequestEvent.EnvironmentRequest(
                wantReply: false,
                name: "LC_CTYPE",
                value: "en_US.UTF-8"
            ),
            SSHChannelRequestEvent.EnvironmentRequest(
                wantReply: false,
                name: "COLORTERM",
                value: "truecolor"
            )
        ]

        do {
            try await connectedClient.withPTY(request, environment: environment) { inbound, outbound in
                installWriter(outbound)

                if let command = startupCommand {
                    try await outbound.write(ByteBuffer(bytes: TerminalWireEncoding.bytes(for: command)))
                }
                await onReady()

                for try await event in inbound {
                    switch event {
                    case .stdout(var buffer), .stderr(var buffer):
                        if let bytes = buffer.readBytes(length: buffer.readableBytes), !bytes.isEmpty {
                            await onOutput(bytes)
                        }
                    }
                }
            }
            clearState()
            try? await connectedClient.close()
        } catch {
            clearState()
            try? await connectedClient.close()
            throw error
        }
    }

    fileprivate static func authenticationMethod(for profile: SSHProfile) throws -> SSHAuthenticationMethod {
        switch profile.authenticationKind {
        case .password:
            return .passwordBased(username: profile.username, password: profile.password)
        case .privateKey:
            let passphrase = profile.privateKeyPassphrase.isEmpty
                ? nil
                : Data(profile.privateKeyPassphrase.utf8)
            let keyType = try SSHKeyDetection.detectPrivateKeyType(from: profile.privateKey)
            if keyType == .ed25519 {
                let key = try Curve25519.Signing.PrivateKey(
                    sshEd25519: profile.privateKey,
                    decryptionKey: passphrase
                )
                return .ed25519(username: profile.username, privateKey: key)
            }
            if keyType == .rsa {
                let key = try Insecure.RSA.PrivateKey(
                    sshRsa: profile.privateKey,
                    decryptionKey: passphrase
                )
                return .rsa(username: profile.username, privateKey: key)
            }
            throw SSHConnectionEngineError.unsupportedPrivateKeyType(keyType.description)
        }
    }

    fileprivate static func clientSettings(
        for profile: SSHProfile,
        approveHostKey: @escaping SSHHostKeyApproval
    ) throws -> SSHClientSettings {
        let profile = profile.normalized
        let hostKeyDelegate = PinnedHostKeyDelegate(
            expectedFingerprint: profile.hostKeyFingerprint,
            approval: approveHostKey
        )
        let authenticationMethod = SSHAuthenticationMethodBox(
            value: try authenticationMethod(for: profile)
        )
        var settings = SSHClientSettings(
            host: profile.host,
            port: profile.port,
            authenticationMethod: { authenticationMethod.value },
            hostKeyValidator: .custom(hostKeyDelegate)
        )
        settings.connectTimeout = .seconds(20)
        return settings
    }

    func send(_ bytes: [UInt8]) async throws {
        guard let writer = currentWriter() else { throw SSHConnectionEngineError.notConnected }
        try await writer.value.write(ByteBuffer(bytes: bytes))
    }

    func resize(cols: Int, rows: Int, pixelWidth: Int, pixelHeight: Int) async {
        guard cols > 0, rows > 0, let writer = currentWriter() else { return }
        try? await writer.value.changeSize(
            cols: cols,
            rows: rows,
            pixelWidth: pixelWidth,
            pixelHeight: pixelHeight
        )
    }

    func disconnect() async {
        let client = takeClientAndClearState()
        guard let client else { return }
        try? await client.value.close()
    }

    private func installWriter(_ writer: TTYStdinWriter) {
        stateLock.lock()
        self.writer = TTYWriterBox(value: writer)
        stateLock.unlock()
    }

    private func setClient(_ client: SSHClient) {
        stateLock.lock()
        self.client = SSHClientBox(value: client)
        stateLock.unlock()
    }

    private func currentWriter() -> TTYWriterBox? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return writer
    }

    private func clearState() {
        stateLock.lock()
        writer = nil
        client = nil
        stateLock.unlock()
    }

    private func takeClientAndClearState() -> SSHClientBox? {
        stateLock.lock()
        defer { stateLock.unlock() }
        let currentClient = client
        writer = nil
        client = nil
        return currentClient
    }
}

// MARK: - Local port forwarding

enum SSHLocalPortForwardError: LocalizedError {
    case invalidConfiguration(String)
    case listenerFailed(String)
    case tunnelClosed

    var errorDescription: String? {
        switch self {
        case .invalidConfiguration(let message): message
        case .listenerFailed(let message): "Local listener failed: \(message)"
        case .tunnelClosed: "The SSH tunnel closed."
        }
    }
}

/// Sends bytes received from a direct-tcpip SSH child channel back to the
/// accepted loopback connection.
private final class SSHForwardInboundHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer

    private let connection: NWConnection
    private let onClosed: @Sendable () -> Void

    init(connection: NWConnection, onClosed: @escaping @Sendable () -> Void) {
        self.connection = connection
        self.onClosed = onClosed
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let buffer = unwrapInboundIn(data)
        let payload = Data(buffer.readableBytesView)
        guard !payload.isEmpty else { return }
        connection.send(content: payload, completion: .contentProcessed { error in
            if error != nil { self.connection.cancel() }
        })
    }

    func channelInactive(context: ChannelHandlerContext) {
        connection.cancel()
        onClosed()
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        connection.cancel()
        onClosed()
        context.close(promise: nil)
    }
}

private final class SSHForwardContinuationGate: @unchecked Sendable {
    private let lock = NSLock()
    private var resumed = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !resumed else { return false }
        resumed = true
        return true
    }
}

/// Owns one accepted local TCP connection and its matching SSH direct-tcpip
/// channel. Web pages normally open several such connections in parallel;
/// all of them share the parent authenticated SSH client.
private final class SSHForwardConnectionBridge: @unchecked Sendable {
    let id = UUID()

    private let connection: NWConnection
    private let queue: DispatchQueue
    private let onClosed: @Sendable (UUID) -> Void
    private let lock = NSLock()
    private var channel: Channel?
    private var closed = false

    init(
        connection: NWConnection,
        queue: DispatchQueue,
        onClosed: @escaping @Sendable (UUID) -> Void
    ) {
        self.connection = connection
        self.queue = queue
        self.onClosed = onClosed
    }

    func start(client: SSHClient, forward: SSHLocalPortForward) async throws {
        connection.start(queue: queue)
        let originator = try SocketAddress(ipAddress: "127.0.0.1", port: forward.localPort)
        let bridgeID = id
        let channel = try await client.createDirectTCPIPChannel(
            using: SSHChannelType.DirectTCPIP(
                targetHost: forward.remoteHost,
                targetPort: forward.remotePort,
                originatorAddress: originator
            )
        ) { [connection, onClosed] channel in
            channel.pipeline.addHandler(
                SSHForwardInboundHandler(connection: connection) {
                    onClosed(bridgeID)
                }
            )
        }
        lock.withLock { self.channel = channel }
        receiveNext()
    }

    func cancel() {
        lock.lock()
        guard !closed else {
            lock.unlock()
            return
        }
        closed = true
        let channel = channel
        self.channel = nil
        lock.unlock()
        connection.cancel()
        channel?.close(promise: nil)
    }

    private func receiveNext() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1_024) { [weak self] data, _, complete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.lock.lock()
                let channel = self.channel
                let isClosed = self.closed
                self.lock.unlock()
                if let channel, !isClosed {
                    var buffer = channel.allocator.buffer(capacity: data.count)
                    buffer.writeBytes(data)
                    channel.writeAndFlush(buffer, promise: nil)
                }
            }
            if complete || error != nil {
                self.cancel()
                self.onClosed(self.id)
            } else {
                self.receiveNext()
            }
        }
    }
}

/// A foreground-scoped SSH local forward. It binds only to loopback and
/// multiplexes accepted web connections over one authenticated SSH client.
final class SSHLocalPortForwardService: @unchecked Sendable {
    private let queue = DispatchQueue(label: "dev.modot.RetoBrowser.ssh-forward")
    private let lock = NSLock()
    private var listener: NWListener?
    private var client: SSHClient?
    private var bridges: [UUID: SSHForwardConnectionBridge] = [:]

    func start(
        forward rawForward: SSHLocalPortForward,
        profile rawProfile: SSHProfile,
        approveHostKey: @escaping SSHHostKeyApproval
    ) async throws {
        let forward = rawForward.normalized
        if let validationMessage = forward.validationMessage {
            throw SSHLocalPortForwardError.invalidConfiguration(validationMessage)
        }
        try await startValidated(
            forward: forward,
            profile: rawProfile.normalized,
            approveHostKey: approveHostKey
        )
    }

    private func startValidated(
        forward: SSHLocalPortForward,
        profile: SSHProfile,
        approveHostKey: @escaping SSHHostKeyApproval
    ) async throws {
        let settings = try SSHConnectionEngine.clientSettings(
            for: profile,
            approveHostKey: approveHostKey
        )
        let connectedClient = try await SSHClient.connect(to: settings)

        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        parameters.requiredLocalEndpoint = .hostPort(
            host: NWEndpoint.Host("127.0.0.1"),
            port: NWEndpoint.Port(rawValue: UInt16(forward.localPort))!
        )
        let listener = try NWListener(
            using: parameters,
            on: NWEndpoint.Port(rawValue: UInt16(forward.localPort))!
        )

        lock.withLock {
            client = connectedClient
            self.listener = listener
        }

        listener.newConnectionHandler = { [weak self, weak connectedClient] connection in
            guard let self, let connectedClient else {
                connection.cancel()
                return
            }
            let bridge = SSHForwardConnectionBridge(
                connection: connection,
                queue: self.queue
            ) { [weak self] bridgeID in
                self?.removeBridge(bridgeID)
            }
            self.lock.lock()
            self.bridges[bridge.id] = bridge
            self.lock.unlock()
            Task {
                do {
                    try await bridge.start(client: connectedClient, forward: forward)
                } catch {
                    bridge.cancel()
                    self.removeBridge(bridge.id)
                }
            }
        }

        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let gate = SSHForwardContinuationGate()
                listener.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        if gate.claim() { continuation.resume() }
                    case .failed(let error):
                        if gate.claim() {
                            continuation.resume(throwing: SSHLocalPortForwardError.listenerFailed(error.localizedDescription))
                        }
                    default:
                        break
                    }
                }
                listener.start(queue: queue)
            }
        } catch {
            await stop()
            throw error
        }
    }

    func stop() async {
        let stoppedResources = lock.withLock { () -> (NWListener?, SSHClient?, [SSHForwardConnectionBridge]) in
            let resources = (listener, client, Array(bridges.values))
            listener = nil
            client = nil
            bridges.removeAll()
            return resources
        }

        stoppedResources.0?.cancel()
        stoppedResources.2.forEach { $0.cancel() }
        if let client = stoppedResources.1 { try? await client.close() }
    }

    private func removeBridge(_ id: UUID) {
        lock.lock()
        bridges.removeValue(forKey: id)
        lock.unlock()
    }
}

/// One-shot exec runner for private-key profiles. Opens a short-lived Citadel
/// connection, runs a single command on an exec channel, and closes — the
/// interactive terminal session is never involved.
final class CitadelOneShotCommandRunner: SSHOneShotCommandRunning {
    func run(
        command: String,
        profile: SSHProfile,
        approveHostKey: @escaping SSHHostKeyApproval
    ) async throws -> SSHCommandResult {
        let profile = profile.normalized
        let hostKeyDelegate = PinnedHostKeyDelegate(
            expectedFingerprint: profile.hostKeyFingerprint,
            approval: approveHostKey
        )
        let authenticationMethod = SSHAuthenticationMethodBox(
            value: try SSHConnectionEngine.authenticationMethod(for: profile)
        )
        var settings = SSHClientSettings(
            host: profile.host,
            port: profile.port,
            authenticationMethod: { authenticationMethod.value },
            hostKeyValidator: .custom(hostKeyDelegate)
        )
        settings.connectTimeout = .seconds(20)

        let client = try await SSHClient.connect(to: settings)
        defer {
            let box = SSHClientBox(value: client)
            Task { try? await box.value.close() }
        }

        var collected = ""
        var exitCode: Int32? = 0
        do {
            let stream = try await client.executeCommandStream(command)
            for try await chunk in stream {
                switch chunk {
                case .stdout(var buffer), .stderr(var buffer):
                    if let text = buffer.readString(length: buffer.readableBytes) {
                        collected += text
                    }
                }
                if collected.utf8.count > 1_048_576 {
                    break
                }
            }
        } catch let failure as SSHClient.CommandFailed {
            exitCode = Int32(failure.exitCode)
        }
        return SSHCommandResult(exitCode: exitCode, output: collected)
    }
}
