import Foundation

/// Result of a one-shot remote command. `output` merges stdout and stderr so
/// tmux's "no server running" style diagnostics stay classifiable.
struct SSHCommandResult: Equatable, Sendable {
    let exitCode: Int32?
    let output: String
}

/// Runs a single command over a dedicated SSH exec channel on its own
/// connection. Nothing is ever typed into — or read back from — the visible
/// interactive terminal, so discovery cannot corrupt a running session.
protocol SSHOneShotCommandRunning: Sendable {
    func run(
        command: String,
        profile: SSHProfile,
        approveHostKey: @escaping SSHHostKeyApproval
    ) async throws -> SSHCommandResult
}

/// Mirrors the interactive engine choice: libssh2 for password logins (PAM
/// keyboard-interactive fallback), Citadel for imported private keys.
enum SSHOneShotCommandRunnerFactory {
    static func makeRunner(for profile: SSHProfile) -> any SSHOneShotCommandRunning {
        switch profile.authenticationKind {
        case .password:
            LibSSH2OneShotCommandRunner()
        case .privateKey:
            CitadelOneShotCommandRunner()
        }
    }
}
