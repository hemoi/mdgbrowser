import XCTest
@testable import RetoBrowser

final class TerminalDomainTests: XCTestCase {
    func testTmuxCommandAttachesOrCreatesUTF8Session() {
        let profile = SSHProfile(
            name: "Ops",
            host: "ops.example.com",
            username: "modot",
            password: "secret",
            usesTmux: true,
            tmuxSession: "deploy-main"
        )

        XCTAssertEqual(profile.tmuxStartupCommand, "tmux -u new-session -A -s deploy-main\r")
    }

    func testTmuxSessionRejectsShellMetacharacters() {
        let profile = SSHProfile(
            host: "ops.example.com",
            username: "modot",
            password: "secret",
            usesTmux: true,
            tmuxSession: "main; reboot"
        )

        XCTAssertNotNil(profile.validationMessage)
        XCTAssertNil(profile.tmuxStartupCommand)
    }

    func testCJKWireEncodingRoundTripsUTF8WithoutLoss() {
        let input = "한글 입력 · 中文输入 · 日本語入力 · 👨‍👩‍👧‍👦"
        let bytes = TerminalWireEncoding.bytes(for: input)

        XCTAssertEqual(String(decoding: bytes, as: UTF8.self), input)
    }

    @MainActor
    func testTerminalViewSendsComposedKoreanAndCJKAsUTF8() {
        let view = RetoTerminalView(frame: .zero)
        var sent: [UInt8] = []
        view.onInput = { sent.append(contentsOf: $0) }

        view.insertText("안녕하세요 · 中文 · 日本語")

        XCTAssertEqual(String(decoding: sent, as: UTF8.self), "안녕하세요 · 中文 · 日本語")
    }

    @MainActor
    func testKoreanFinalConsonantMovesToFollowingVowelWithoutDroppingSyllable() {
        XCTAssertEqual(
            RetoTerminalView.resyllabifyKoreanForTesting(base: "핫", followingVowel: "ㅔ"),
            "하세"
        )
        XCTAssertEqual(
            RetoTerminalView.resyllabifyKoreanForTesting(base: "읽", followingVowel: "ㅓ"),
            "일거"
        )
        XCTAssertNil(RetoTerminalView.resyllabifyKoreanForTesting(base: "하", followingVowel: "ㅔ"))
    }

    func testSSHAddressCreatesPrefilledProfileWithoutImportingASecret() throws {
        let profile = try XCTUnwrap(
            SSHProfile.draft(fromSSHAddress: "ssh://modot@ops.example.com:2222")
        )

        XCTAssertEqual(profile.host, "ops.example.com")
        XCTAssertEqual(profile.port, 2_222)
        XCTAssertEqual(profile.username, "modot")
        XCTAssertTrue(profile.password.isEmpty)
    }

    func testSSHAddressRejectsCommandsAndWebURLs() {
        XCTAssertNil(SSHProfile.draft(fromSSHAddress: "ssh://modot@example.com/run-this"))
        XCTAssertNil(SSHProfile.draft(fromSSHAddress: "https://example.com"))
    }

    func testIPv6EndpointUsesBrackets() {
        let profile = SSHProfile(host: "2001:db8::1", port: 2_222, username: "modot")

        XCTAssertEqual(profile.endpoint, "modot@[2001:db8::1]:2222")
    }

    func testPrivateKeyAuthenticationDoesNotRequirePassword() {
        let profile = SSHProfile(
            host: "ops.example.com",
            username: "modot",
            authenticationKind: .privateKey,
            privateKey: "-----BEGIN OPENSSH PRIVATE KEY-----\ndummy\n-----END OPENSSH PRIVATE KEY-----"
        )

        XCTAssertNil(profile.validationMessage)
    }

    func testPrivateKeyAuthenticationRequiresImportedKey() {
        let profile = SSHProfile(
            host: "ops.example.com",
            username: "modot",
            authenticationKind: .privateKey
        )

        XCTAssertEqual(profile.validationMessage, "An OpenSSH private key is required.")
    }

    func testLegacyPasswordProfileDecodesWithPasswordAuthentication() throws {
        let id = UUID()
        let legacy: [String: Any] = [
            "id": id.uuidString,
            "name": "Legacy",
            "host": "legacy.example.com",
            "port": 22,
            "username": "modot",
            "password": "secret",
            "usesTmux": false,
            "tmuxSession": "main"
        ]
        let data = try JSONSerialization.data(withJSONObject: legacy)

        let profile = try JSONDecoder().decode(SSHProfile.self, from: data)

        XCTAssertEqual(profile.authenticationKind, .password)
        XCTAssertEqual(profile.password, "secret")
        XCTAssertTrue(profile.privateKey.isEmpty)
    }

    func testPrivateKeyProfileRoundTripsThroughEncryptedVaultPayload() throws {
        let original = SSHProfile(
            host: "key.example.com",
            username: "modot",
            authenticationKind: .privateKey,
            privateKey: "-----BEGIN OPENSSH PRIVATE KEY-----\nfixture\n-----END OPENSSH PRIVATE KEY-----",
            privateKeyPassphrase: "passphrase"
        )

        let restored = try JSONDecoder().decode(SSHProfile.self, from: JSONEncoder().encode(original))

        XCTAssertEqual(restored, original)
    }
}
