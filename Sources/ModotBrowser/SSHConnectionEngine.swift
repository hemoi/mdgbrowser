@preconcurrency import Citadel
import Crypto
import CryptoKit
import Foundation
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
        approveHostKey: @escaping SSHHostKeyApproval,
        onOutput: @escaping @Sendable ([UInt8]) async -> Void,
        onReady: @escaping @Sendable () async -> Void
    ) async throws

    func send(_ bytes: [UInt8]) async throws
    func resize(cols: Int, rows: Int, pixelWidth: Int, pixelHeight: Int) async
    func disconnect() async
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
        approveHostKey: @escaping SSHHostKeyApproval,
        onOutput: @escaping OutputHandler,
        onReady: @escaping ReadyHandler
    ) async throws {
        let profile = profile.normalized
        let hostKeyDelegate = PinnedHostKeyDelegate(
            expectedFingerprint: profile.hostKeyFingerprint,
            approval: approveHostKey
        )
        let authenticationMethod = SSHAuthenticationMethodBox(
            value: try Self.authenticationMethod(for: profile)
        )
        var settings = SSHClientSettings(
            host: profile.host,
            port: profile.port,
            authenticationMethod: { authenticationMethod.value },
            hostKeyValidator: .custom(hostKeyDelegate)
        )
        settings.connectTimeout = .seconds(20)

        let connectedClient = try await SSHClient.connect(to: settings)
        if Task.isCancelled {
            try? await connectedClient.close()
            throw CancellationError()
        }
        setClient(connectedClient)

        let request = SSHChannelRequestEvent.PseudoTerminalRequest(
            wantReply: true,
            term: "xterm-256color",
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
            )
        ]

        do {
            try await connectedClient.withPTY(request, environment: environment) { inbound, outbound in
                installWriter(outbound)

                if let command = profile.tmuxStartupCommand {
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

    private static func authenticationMethod(for profile: SSHProfile) throws -> SSHAuthenticationMethod {
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
