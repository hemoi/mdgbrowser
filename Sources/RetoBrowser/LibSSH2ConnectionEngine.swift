import CSSH
import CryptoKit
import Darwin
import Foundation

enum LibSSH2ConnectionError: LocalizedError {
    case runtimeInitializationFailed
    case connectionFailed
    case handshakeFailed
    case authenticationFailed
    case hostKeyUnavailable
    case hostKeyRejected
    case channelFailed
    case notConnected
    case transportFailed

    var errorDescription: String? {
        switch self {
        case .runtimeInitializationFailed:
            "The SSH runtime could not be initialized."
        case .connectionFailed:
            "The SSH server could not be reached."
        case .handshakeFailed:
            "The SSH handshake failed."
        case .authenticationFailed:
            "Authentication failed. Password and keyboard-interactive authentication were attempted."
        case .hostKeyUnavailable:
            "The SSH server host key could not be verified."
        case .hostKeyRejected:
            "The SSH server host key was not trusted."
        case .channelFailed:
            "The SSH terminal channel could not be opened."
        case .notConnected:
            "The terminal is not connected."
        case .transportFailed:
            "The SSH connection was interrupted."
        }
    }
}

private final class KeyboardInteractiveSecret: @unchecked Sendable {
    private let lock = NSLock()
    private var password: String?

    func set(_ password: String?) {
        lock.lock()
        self.password = password
        lock.unlock()
    }

    func duplicatePassword() -> UnsafeMutablePointer<CChar>? {
        lock.lock()
        defer { lock.unlock() }
        guard let password else { return nil }
        return strdup(password)
    }
}

private func keyboardInteractiveSecret(
    from abstract: UnsafeMutablePointer<UnsafeMutableRawPointer?>?
) -> KeyboardInteractiveSecret? {
    guard let pointer = abstract?.pointee else { return nil }
    return Unmanaged<KeyboardInteractiveSecret>.fromOpaque(pointer).takeUnretainedValue()
}

nonisolated(unsafe) private let keyboardInteractiveCallback: @convention(c) (
    UnsafePointer<CChar>?,
    Int32,
    UnsafePointer<CChar>?,
    Int32,
    Int32,
    UnsafePointer<LIBSSH2_USERAUTH_KBDINT_PROMPT>?,
    UnsafeMutablePointer<LIBSSH2_USERAUTH_KBDINT_RESPONSE>?,
    UnsafeMutablePointer<UnsafeMutableRawPointer?>?
) -> Void = { _, _, _, _, promptCount, _, responses, abstract in
    guard promptCount > 0,
          let responses,
          let secret = keyboardInteractiveSecret(from: abstract)
    else { return }

    for index in 0..<Int(promptCount) {
        guard let password = secret.duplicatePassword() else { continue }
        responses[index].text = password
        responses[index].length = UInt32(strlen(password))
    }
}

/// Socket/handshake/auth primitives shared by the interactive engine and the
/// one-shot command runner so both speak the same libssh2 dialect.
private enum LibSSH2Primitives {
    static let runtimeResult: Int32 = libssh2_init(0)

    static func connectSocket(host: String, port: Int, shouldAbort: () -> Bool) throws -> Int32 {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        hints.ai_protocol = IPPROTO_TCP

        var addresses: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, String(port), &hints, &addresses) == 0, let first = addresses else {
            throw LibSSH2ConnectionError.connectionFailed
        }
        defer { freeaddrinfo(addresses) }

        var candidate: UnsafeMutablePointer<addrinfo>? = first
        while let address = candidate {
            if shouldAbort() { throw CancellationError() }
            let descriptor = Darwin.socket(
                address.pointee.ai_family,
                address.pointee.ai_socktype,
                address.pointee.ai_protocol
            )
            if descriptor >= 0 {
                do {
                    try setNonBlocking(descriptor)
                    let result = Darwin.connect(
                        descriptor,
                        address.pointee.ai_addr,
                        address.pointee.ai_addrlen
                    )
                    if result == 0 || (result == -1 && errno == EINPROGRESS && socketBecameWritable(descriptor)) {
                        try setBlocking(descriptor)
                        configureSocket(descriptor)
                        return descriptor
                    }
                } catch {
                    Darwin.close(descriptor)
                    throw error
                }
                Darwin.close(descriptor)
            }
            candidate = address.pointee.ai_next
        }
        throw LibSSH2ConnectionError.connectionFailed
    }

    static func socketBecameWritable(_ descriptor: Int32) -> Bool {
        var descriptorState = pollfd(fd: descriptor, events: Int16(POLLOUT), revents: 0)
        guard poll(&descriptorState, 1, 20_000) > 0 else { return false }
        var socketError: Int32 = 0
        var length = socklen_t(MemoryLayout<Int32>.size)
        guard getsockopt(descriptor, SOL_SOCKET, SO_ERROR, &socketError, &length) == 0 else {
            return false
        }
        return socketError == 0
    }

    static func configureSocket(_ descriptor: Int32) {
        var enabled: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(descriptor, IPPROTO_TCP, TCP_NODELAY, &enabled, socklen_t(MemoryLayout<Int32>.size))
        var timeout = timeval(tv_sec: 20, tv_usec: 0)
        setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    }

    static func setNonBlocking(_ descriptor: Int32) throws {
        let flags = fcntl(descriptor, F_GETFL, 0)
        guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 else {
            throw LibSSH2ConnectionError.connectionFailed
        }
    }

    static func setBlocking(_ descriptor: Int32) throws {
        let flags = fcntl(descriptor, F_GETFL, 0)
        guard flags >= 0, fcntl(descriptor, F_SETFL, flags & ~O_NONBLOCK) == 0 else {
            throw LibSSH2ConnectionError.connectionFailed
        }
    }

    static func hostKeyFingerprint(session: OpaquePointer) throws -> String {
        guard let hash = libssh2_hostkey_hash(session, Int32(LIBSSH2_HOSTKEY_HASH_SHA256)) else {
            throw LibSSH2ConnectionError.hostKeyUnavailable
        }
        let data = Data(bytes: hash, count: SHA256.byteCount)
        let base64 = data.base64EncodedString().replacingOccurrences(of: "=", with: "")
        return "SHA256:\(base64)"
    }

    static func authenticate(
        session: OpaquePointer,
        profile: SSHProfile,
        secret: KeyboardInteractiveSecret
    ) throws {
        let username = profile.username
        let password = profile.password
        let available: String
        if let methods = libssh2_userauth_list(session, username, UInt32(username.utf8.count)) {
            available = String(cString: methods)
        } else if libssh2_userauth_authenticated(session) != 0 {
            return
        } else {
            available = "password,keyboard-interactive"
        }

        var result = Int32(LIBSSH2_ERROR_AUTHENTICATION_FAILED)
        if available.contains("password") {
            result = username.withCString { usernamePointer in
                password.withCString { passwordPointer in
                    libssh2_userauth_password_ex(
                        session,
                        usernamePointer,
                        UInt32(username.utf8.count),
                        passwordPointer,
                        UInt32(password.utf8.count),
                        nil
                    )
                }
            }
        }

        if result != 0, available.contains("keyboard-interactive") {
            secret.set(password)
            defer { secret.set(nil) }
            result = username.withCString { usernamePointer in
                libssh2_userauth_keyboard_interactive_ex(
                    session,
                    usernamePointer,
                    UInt32(username.utf8.count),
                    keyboardInteractiveCallback
                )
            }
        }

        guard result == 0 else { throw LibSSH2ConnectionError.authenticationFailed }
    }

    static func setEnvironment(_ name: String, value: String, channel: OpaquePointer) {
        name.withCString { namePointer in
            value.withCString { valuePointer in
                _ = libssh2_channel_setenv_ex(
                    channel,
                    namePointer,
                    UInt32(name.utf8.count),
                    valuePointer,
                    UInt32(value.utf8.count)
                )
            }
        }
    }
}

/// Password SSH transport backed by libssh2. Citadel remains the private-key
/// transport; libssh2 is used here because SwiftNIO SSH does not implement the
/// RFC 4256 keyboard-interactive exchange required by many PAM SSH servers.
final class LibSSH2ConnectionEngine: SSHConnectionEngineProtocol, @unchecked Sendable {
    private struct TerminalSize: Sendable {
        let cols: Int
        let rows: Int
        let pixelWidth: Int
        let pixelHeight: Int
    }

    private let stateLock = NSLock()
    private let keyboardSecret = KeyboardInteractiveSecret()
    private var socketDescriptor: Int32 = -1
    private var ready = false
    private var stopped = false
    private var pendingWrites: [[UInt8]] = []
    private var pendingSize: TerminalSize?

    func run(
        profile: SSHProfile,
        startupCommand: String?,
        approveHostKey: @escaping SSHHostKeyApproval,
        onOutput: @escaping @Sendable ([UInt8]) async -> Void,
        onReady: @escaping @Sendable () async -> Void
    ) async throws {
        guard LibSSH2Primitives.runtimeResult == 0 else {
            throw LibSSH2ConnectionError.runtimeInitializationFailed
        }

        resetForConnection()
        try await withTaskCancellationHandler {
            try await Task.detached(priority: .userInitiated) { [self] in
                try await runSession(
                    profile: profile.normalized,
                    startupCommand: startupCommand,
                    approveHostKey: approveHostKey,
                    onOutput: onOutput,
                    onReady: onReady
                )
            }.value
        } onCancel: { [self] in
            requestStop()
        }
    }

    func send(_ bytes: [UInt8]) async throws {
        guard !bytes.isEmpty else { return }
        try enqueue(bytes)
    }

    private func enqueue(_ bytes: [UInt8]) throws {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard ready, !stopped else { throw LibSSH2ConnectionError.notConnected }
        pendingWrites.append(bytes)
    }

    func resize(cols: Int, rows: Int, pixelWidth: Int, pixelHeight: Int) async {
        guard cols > 0, rows > 0 else { return }
        enqueueSize(
            TerminalSize(
                cols: cols,
                rows: rows,
                pixelWidth: max(0, pixelWidth),
                pixelHeight: max(0, pixelHeight)
            )
        )
    }

    private func enqueueSize(_ size: TerminalSize) {
        stateLock.lock()
        if ready, !stopped {
            pendingSize = size
        }
        stateLock.unlock()
    }

    func disconnect() async {
        requestStop()
    }

    private func runSession(
        profile: SSHProfile,
        startupCommand: String?,
        approveHostKey: @escaping SSHHostKeyApproval,
        onOutput: @escaping @Sendable ([UInt8]) async -> Void,
        onReady: @escaping @Sendable () async -> Void
    ) async throws {
        let socket = try LibSSH2Primitives.connectSocket(
            host: profile.host,
            port: profile.port,
            shouldAbort: { [self] in isStopped }
        )
        setSocket(socket)

        let abstract = Unmanaged.passUnretained(keyboardSecret).toOpaque()
        guard let session = libssh2_session_init_ex(nil, nil, nil, abstract) else {
            throw LibSSH2ConnectionError.runtimeInitializationFailed
        }

        var channel: OpaquePointer?
        defer {
            markNotReady()
            keyboardSecret.set(nil)
            if let channel {
                _ = libssh2_channel_close(channel)
                _ = libssh2_channel_free(channel)
            }
            _ = libssh2_session_disconnect_ex(session, 11, "Normal shutdown", "")
            _ = libssh2_session_free(session)
            Darwin.close(socket)
            clearSocket(socket)
        }

        libssh2_session_set_blocking(session, 1)
        libssh2_session_set_timeout(session, 20_000)
        _ = libssh2_session_method_pref(
            session,
            Int32(LIBSSH2_METHOD_HOSTKEY),
            "ssh-ed25519,ecdsa-sha2-nistp256,rsa-sha2-512,rsa-sha2-256,ssh-rsa"
        )
        guard libssh2_session_handshake(session, socket) == 0 else {
            throw LibSSH2ConnectionError.handshakeFailed
        }
        try Task.checkCancellation()
        guard !isStopped else { throw CancellationError() }

        let fingerprint = try LibSSH2Primitives.hostKeyFingerprint(session: session)
        if fingerprint != profile.hostKeyFingerprint {
            guard await approveHostKey(fingerprint, profile.hostKeyFingerprint) else {
                throw LibSSH2ConnectionError.hostKeyRejected
            }
        }
        try Task.checkCancellation()
        guard !isStopped else { throw CancellationError() }

        try LibSSH2Primitives.authenticate(session: session, profile: profile, secret: keyboardSecret)
        guard let openedChannel = libssh2_channel_open_ex(
            session,
            "session",
            7,
            2 * 1_024 * 1_024,
            32_768,
            nil,
            0
        ) else {
            throw LibSSH2ConnectionError.channelFailed
        }
        channel = openedChannel

        guard libssh2_channel_request_pty_ex(
            openedChannel,
            profile.resolvedTerminalType,
            UInt32(profile.resolvedTerminalType.utf8.count),
            nil,
            0,
            100,
            30,
            0,
            0
        ) == 0 else {
            throw LibSSH2ConnectionError.channelFailed
        }

        LibSSH2Primitives.setEnvironment("LANG", value: "en_US.UTF-8", channel: openedChannel)
        LibSSH2Primitives.setEnvironment("LC_CTYPE", value: "en_US.UTF-8", channel: openedChannel)
        LibSSH2Primitives.setEnvironment("COLORTERM", value: "truecolor", channel: openedChannel)
        guard libssh2_channel_process_startup(openedChannel, "shell", 5, nil, 0) == 0 else {
            throw LibSSH2ConnectionError.channelFailed
        }

        if let command = startupCommand {
            try writeBlocking(TerminalWireEncoding.bytes(for: command), channel: openedChannel)
        }

        try LibSSH2Primitives.setNonBlocking(socket)
        libssh2_session_set_blocking(session, 0)
        markReady()
        await onReady()

        try await ioLoop(channel: openedChannel, onOutput: onOutput)
    }

    private func writeBlocking(_ bytes: [UInt8], channel: OpaquePointer) throws {
        var offset = 0
        while offset < bytes.count {
            let written = bytes.withUnsafeBytes { rawBuffer -> Int in
                guard let baseAddress = rawBuffer.baseAddress else { return 0 }
                let pointer = baseAddress.advanced(by: offset).assumingMemoryBound(to: CChar.self)
                return libssh2_channel_write_ex(channel, 0, pointer, bytes.count - offset)
            }
            guard written > 0 else { throw LibSSH2ConnectionError.transportFailed }
            offset += written
        }
    }

    private func ioLoop(
        channel: OpaquePointer,
        onOutput: @escaping @Sendable ([UInt8]) async -> Void
    ) async throws {
        var readBuffer = [CChar](repeating: 0, count: 32_768)
        var activeWrite: [UInt8] = []
        var writeOffset = 0

        while !Task.isCancelled, !isStopped {
            var didWork = false

            if let size = takePendingSize() {
                let result = libssh2_channel_request_pty_size_ex(
                    channel,
                    Int32(size.cols),
                    Int32(size.rows),
                    Int32(size.pixelWidth),
                    Int32(size.pixelHeight)
                )
                if result == Int32(LIBSSH2_ERROR_EAGAIN) {
                    restorePendingSize(size)
                } else if result != 0 {
                    throw LibSSH2ConnectionError.transportFailed
                } else {
                    didWork = true
                }
            }

            if activeWrite.isEmpty, let next = takePendingWrite() {
                activeWrite = next
                writeOffset = 0
            }
            if !activeWrite.isEmpty {
                let written = activeWrite.withUnsafeBytes { rawBuffer -> Int in
                    guard let baseAddress = rawBuffer.baseAddress else { return 0 }
                    let pointer = baseAddress.advanced(by: writeOffset).assumingMemoryBound(to: CChar.self)
                    return libssh2_channel_write_ex(
                        channel,
                        0,
                        pointer,
                        activeWrite.count - writeOffset
                    )
                }
                if written > 0 {
                    writeOffset += written
                    didWork = true
                    if writeOffset == activeWrite.count {
                        activeWrite.removeAll(keepingCapacity: true)
                        writeOffset = 0
                    }
                } else if written != Int(LIBSSH2_ERROR_EAGAIN) {
                    throw LibSSH2ConnectionError.transportFailed
                }
            }

            for stream in [0, Int32(SSH_EXTENDED_DATA_STDERR)] {
                let count = libssh2_channel_read_ex(channel, stream, &readBuffer, readBuffer.count)
                if count > 0 {
                    let output = readBuffer.prefix(Int(count)).map(UInt8.init(bitPattern:))
                    await onOutput(output)
                    didWork = true
                } else if count < 0, count != Int(LIBSSH2_ERROR_EAGAIN) {
                    throw LibSSH2ConnectionError.transportFailed
                }
            }

            if libssh2_channel_eof(channel) != 0 { return }
            if !didWork {
                try await Task.sleep(for: .milliseconds(4))
            }
        }

        if Task.isCancelled { throw CancellationError() }
    }

    private var isStopped: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return stopped
    }

    private func resetForConnection() {
        stateLock.lock()
        socketDescriptor = -1
        ready = false
        stopped = false
        pendingWrites.removeAll(keepingCapacity: true)
        pendingSize = nil
        stateLock.unlock()
    }

    private func setSocket(_ descriptor: Int32) {
        stateLock.lock()
        socketDescriptor = descriptor
        stateLock.unlock()
    }

    private func clearSocket(_ descriptor: Int32) {
        stateLock.lock()
        if socketDescriptor == descriptor { socketDescriptor = -1 }
        ready = false
        pendingWrites.removeAll(keepingCapacity: true)
        pendingSize = nil
        stateLock.unlock()
    }

    private func markReady() {
        stateLock.lock()
        ready = true
        stateLock.unlock()
    }

    private func markNotReady() {
        stateLock.lock()
        ready = false
        stateLock.unlock()
    }

    private func requestStop() {
        stateLock.lock()
        stopped = true
        ready = false
        let descriptor = socketDescriptor
        stateLock.unlock()
        if descriptor >= 0 {
            Darwin.shutdown(descriptor, SHUT_RDWR)
        }
    }

    private func takePendingWrite() -> [UInt8]? {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard !pendingWrites.isEmpty else { return nil }
        return pendingWrites.removeFirst()
    }

    private func takePendingSize() -> TerminalSize? {
        stateLock.lock()
        defer { stateLock.unlock() }
        let size = pendingSize
        pendingSize = nil
        return size
    }

    private func restorePendingSize(_ size: TerminalSize) {
        stateLock.lock()
        if pendingSize == nil { pendingSize = size }
        stateLock.unlock()
    }
}

/// One-shot exec runner for password profiles. Uses its own blocking libssh2
/// session and an "exec" channel (no PTY, no shell), so nothing is typed into
/// or echoed by the user's visible terminal.
final class LibSSH2OneShotCommandRunner: SSHOneShotCommandRunning, @unchecked Sendable {
    private static let maxCollectedOutput = 1_048_576

    func run(
        command: String,
        profile: SSHProfile,
        approveHostKey: @escaping SSHHostKeyApproval
    ) async throws -> SSHCommandResult {
        guard LibSSH2Primitives.runtimeResult == 0 else {
            throw LibSSH2ConnectionError.runtimeInitializationFailed
        }
        let profile = profile.normalized
        return try await Task.detached(priority: .utility) {
            try await Self.execute(command: command, profile: profile, approveHostKey: approveHostKey)
        }.value
    }

    private static func execute(
        command: String,
        profile: SSHProfile,
        approveHostKey: @escaping SSHHostKeyApproval
    ) async throws -> SSHCommandResult {
        let socket = try LibSSH2Primitives.connectSocket(
            host: profile.host,
            port: profile.port,
            shouldAbort: { Task.isCancelled }
        )
        let secret = KeyboardInteractiveSecret()
        let abstract = Unmanaged.passUnretained(secret).toOpaque()
        guard let session = libssh2_session_init_ex(nil, nil, nil, abstract) else {
            Darwin.close(socket)
            throw LibSSH2ConnectionError.runtimeInitializationFailed
        }

        var channel: OpaquePointer?
        defer {
            secret.set(nil)
            if let channel {
                _ = libssh2_channel_close(channel)
                _ = libssh2_channel_free(channel)
            }
            _ = libssh2_session_disconnect_ex(session, 11, "Normal shutdown", "")
            _ = libssh2_session_free(session)
            Darwin.close(socket)
        }

        libssh2_session_set_blocking(session, 1)
        libssh2_session_set_timeout(session, 20_000)
        _ = libssh2_session_method_pref(
            session,
            Int32(LIBSSH2_METHOD_HOSTKEY),
            "ssh-ed25519,ecdsa-sha2-nistp256,rsa-sha2-512,rsa-sha2-256,ssh-rsa"
        )
        guard libssh2_session_handshake(session, socket) == 0 else {
            throw LibSSH2ConnectionError.handshakeFailed
        }

        let fingerprint = try LibSSH2Primitives.hostKeyFingerprint(session: session)
        if fingerprint != profile.hostKeyFingerprint {
            guard await approveHostKey(fingerprint, profile.hostKeyFingerprint) else {
                throw LibSSH2ConnectionError.hostKeyRejected
            }
        }
        try Task.checkCancellation()

        try LibSSH2Primitives.authenticate(session: session, profile: profile, secret: secret)
        guard let openedChannel = libssh2_channel_open_ex(
            session,
            "session",
            7,
            2 * 1_024 * 1_024,
            32_768,
            nil,
            0
        ) else {
            throw LibSSH2ConnectionError.channelFailed
        }
        channel = openedChannel

        let startupResult = command.withCString { pointer in
            libssh2_channel_process_startup(
                openedChannel,
                "exec",
                4,
                pointer,
                UInt32(command.utf8.count)
            )
        }
        guard startupResult == 0 else { throw LibSSH2ConnectionError.channelFailed }

        var output: [UInt8] = []
        var readBuffer = [CChar](repeating: 0, count: 32_768)
        for stream in [0, Int32(SSH_EXTENDED_DATA_STDERR)] {
            while output.count < maxCollectedOutput {
                let count = libssh2_channel_read_ex(openedChannel, stream, &readBuffer, readBuffer.count)
                if count > 0 {
                    output.append(contentsOf: readBuffer.prefix(count).map(UInt8.init(bitPattern:)))
                } else if count == Int(LIBSSH2_ERROR_EAGAIN) {
                    continue
                } else if count < 0 {
                    throw LibSSH2ConnectionError.transportFailed
                } else {
                    break
                }
            }
        }

        _ = libssh2_channel_close(openedChannel)
        _ = libssh2_channel_wait_closed(openedChannel)
        let exitCode = libssh2_channel_get_exit_status(openedChannel)
        return SSHCommandResult(exitCode: exitCode, output: String(decoding: output, as: UTF8.self))
    }
}
