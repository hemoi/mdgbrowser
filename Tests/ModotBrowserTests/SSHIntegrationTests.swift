import XCTest
@testable import ModotBrowser

final class SSHIntegrationTests: XCTestCase {
    private struct Credentials {
        let host: String
        let port: Int
        let username: String
        let password: String
    }

    private enum ProbeError: Error {
        case timeout
        case streamEnded
    }

    func testKeyboardInteractivePlainShellAndLiveResize() async throws {
        let credentials = try credentials()
        let profile = SSHProfile(
            name: "Integration Plain",
            host: credentials.host,
            port: credentials.port,
            username: credentials.username,
            password: credentials.password
        )
        let engine = LibSSH2ConnectionEngine()
        let (stream, continuation) = AsyncStream.makeStream(of: [UInt8].self)

        let task = Task {
            defer { continuation.finish() }
            try await engine.run(
                profile: profile,
                approveHostKey: { _, _ in true },
                onOutput: { continuation.yield($0) },
                onReady: {
                    await engine.resize(cols: 132, rows: 42, pixelWidth: 0, pixelHeight: 0)
                    try? await engine.send(TerminalWireEncoding.bytes(
                        for: "printf '__MODOT_PLAIN__'; stty size | tr -d '\\r\\n'; printf '__END__\\n'\r"
                    ))
                }
            )
        }

        do {
            let output = try await collect(until: "__MODOT_PLAIN__42 132__END__", from: stream)
            XCTAssertTrue(output.contains("__MODOT_PLAIN__42 132__END__"))
        } catch {
            await engine.disconnect()
            task.cancel()
            _ = try? await task.value
            throw error
        }

        await engine.disconnect()
        task.cancel()
        _ = try? await task.value
    }

    func testKeyboardInteractiveTmuxAttachCreateAndLiveResize() async throws {
        let credentials = try credentials()
        let sessionName = "modot_xctest_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
        let profile = SSHProfile(
            name: "Integration tmux",
            host: credentials.host,
            port: credentials.port,
            username: credentials.username,
            password: credentials.password,
            usesTmux: true,
            tmuxSession: sessionName
        )
        let engine = LibSSH2ConnectionEngine()
        let (stream, continuation) = AsyncStream.makeStream(of: [UInt8].self)

        let task = Task {
            defer { continuation.finish() }
            try await engine.run(
                profile: profile,
                approveHostKey: { _, _ in true },
                onOutput: { continuation.yield($0) },
                onReady: {
                    await engine.resize(cols: 129, rows: 43, pixelWidth: 0, pixelHeight: 0)
                    try? await engine.send(TerminalWireEncoding.bytes(
                        for: "printf '__MODOT_TMUX__'; test -n \"$TMUX\" && printf yes || printf no; printf '__SIZE__'; stty size | tr -d '\\r\\n'; printf '__END__\\n'\r"
                    ))
                }
            )
        }

        do {
            let marker = "__MODOT_TMUX__yes__SIZE__42 129__END__"
            let output = try await collect(until: marker, from: stream)
            XCTAssertTrue(output.contains(marker))
            try? await engine.send([0x02, Character("d").asciiValue!])
            try? await Task.sleep(for: .milliseconds(500))
            try? await engine.send(TerminalWireEncoding.bytes(
                for: "tmux kill-session -t \(sessionName) >/dev/null 2>&1\r"
            ))
        } catch {
            await engine.disconnect()
            task.cancel()
            _ = try? await task.value
            throw error
        }

        await engine.disconnect()
        task.cancel()
        _ = try? await task.value
    }

    private func credentials() throws -> Credentials {
        let environment = ProcessInfo.processInfo.environment
        let values: [String: String]
        if let host = environment["TEST_IP"], !host.isEmpty {
            values = environment
        } else if let contents = environmentFileContents(environment: environment) {
            values = contents.split(whereSeparator: \.isNewline).reduce(into: [:]) { result, line in
                let entry = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !entry.isEmpty, !entry.hasPrefix("#"), let separator = entry.firstIndex(of: "=") else {
                    return
                }
                let key = String(entry[..<separator])
                var value = String(entry[entry.index(after: separator)...])
                if value.count >= 2,
                   (value.hasPrefix("\"") && value.hasSuffix("\"")
                    || value.hasPrefix("'") && value.hasSuffix("'")) {
                    value.removeFirst()
                    value.removeLast()
                }
                result[key] = value
            }
        } else {
            throw XCTSkip("Set TEST_IP, TEST_PORT, TEST_USERID, and TEST_PASSWD to run SSH integration tests.")
        }

        guard let host = values["TEST_IP"], !host.isEmpty,
              let portValue = values["TEST_PORT"], let port = Int(portValue),
              let username = values["TEST_USERID"], !username.isEmpty,
              let password = values["TEST_PASSWD"], !password.isEmpty
        else {
            throw XCTSkip("The SSH integration test environment is incomplete.")
        }
        return Credentials(host: host, port: port, username: username, password: password)
    }

    private func environmentFileContents(environment: [String: String]) -> String? {
        let repositoryFile = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(".env")
        let path = environment["MODOT_SSH_ENV_FILE"] ?? repositoryFile.path
        return try? String(contentsOfFile: path, encoding: .utf8)
    }

    private func collect(
        until marker: String,
        from stream: AsyncStream<[UInt8]>
    ) async throws -> String {
        try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask {
                var bytes: [UInt8] = []
                for await chunk in stream {
                    bytes.append(contentsOf: chunk)
                    let output = String(decoding: bytes, as: UTF8.self)
                    if output.contains(marker) { return output }
                    if bytes.count > 1_048_576 {
                        bytes.removeFirst(bytes.count - 524_288)
                    }
                }
                throw ProbeError.streamEnded
            }
            group.addTask {
                try await Task.sleep(for: .seconds(25))
                throw ProbeError.timeout
            }
            guard let result = try await group.next() else { throw ProbeError.streamEnded }
            group.cancelAll()
            return result
        }
    }
}
