import Foundation

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
