import XCTest
@testable import RetoBrowser

/// Keeps SSH profile persistence in memory so these tests never touch the
/// real Keychain and never depend on run order or device state.
private final class InMemorySSHProfileVault: SSHProfileVault {
    var stored: [SSHProfile] = []

    func loadProfiles() throws -> [SSHProfile] { stored }
    func saveProfiles(_ profiles: [SSHProfile]) throws { stored = profiles }
}

@MainActor
final class TerminalWorkspaceStoreTests: XCTestCase {
    func testVisibleProfilesMatchesServiceBookmarkVisibilitySemantics() {
        let (store, _) = makeStore()
        let workspaceA = UUID()
        let workspaceB = UUID()

        store.saveProfile(SSHProfile(host: "shared.example.com", username: "modot", password: "x"))
        store.saveProfile(SSHProfile(host: "a-only.example.com", username: "modot", password: "x", workspaceID: workspaceA))
        store.saveProfile(SSHProfile(host: "b-only.example.com", username: "modot", password: "x", workspaceID: workspaceB))

        store.setActiveWorkspace(workspaceA)
        XCTAssertEqual(
            Set(store.visibleProfiles.map(\.host)),
            ["shared.example.com", "a-only.example.com"]
        )

        store.setActiveWorkspace(workspaceB)
        XCTAssertEqual(
            Set(store.visibleProfiles.map(\.host)),
            ["shared.example.com", "b-only.example.com"]
        )
    }

    func testVisibleProfilesShowsEverythingBeforeWorkspaceContextIsWired() {
        let (store, _) = makeStore()
        store.saveProfile(SSHProfile(host: "one.example.com", username: "modot", password: "x", workspaceID: UUID()))

        // The view layer hasn't called setActiveWorkspace yet — fail open
        // rather than hiding a saved server behind an unknown workspace.
        XCTAssertNil(store.activeWorkspaceID)
        XCTAssertEqual(store.visibleProfiles.count, 1)
    }

    func testLegacyStoredProfileStaysVisibleInEveryWorkspaceAfterUpgrade() throws {
        let vault = InMemorySSHProfileVault()
        let legacy: [String: Any] = [
            "id": UUID().uuidString,
            "name": "Legacy",
            "host": "legacy.example.com",
            "port": 22,
            "username": "modot",
            "password": "secret",
            "usesTmux": false,
            "tmuxSession": "main"
        ]
        vault.stored = [try JSONDecoder().decode(SSHProfile.self, from: JSONSerialization.data(withJSONObject: legacy))]

        let store = TerminalWorkspaceStore(vault: vault, defaults: makeDefaults())
        store.setActiveWorkspace(UUID())

        XCTAssertEqual(store.visibleProfiles.count, 1)
        XCTAssertEqual(store.visibleProfiles.first?.host, "legacy.example.com")
    }

    func testAssigningProfileToGroupPersists() throws {
        let (store, _) = makeStore()
        store.saveProfile(SSHProfile(host: "ops.example.com", username: "modot", password: "x"))
        let profileID = try XCTUnwrap(store.profiles.first?.id)
        let groupID = UUID()

        store.assignProfile(profileID, toGroup: groupID)

        XCTAssertEqual(store.profiles.first?.groupID, groupID)
    }

    func testClearGroupRemovesGroupIDFromMemberProfilesOnly() {
        let (store, _) = makeStore()
        let groupID = UUID()
        let otherGroupID = UUID()
        store.saveProfile(SSHProfile(host: "in-group.example.com", username: "modot", password: "x", groupID: groupID))
        store.saveProfile(SSHProfile(host: "other-group.example.com", username: "modot", password: "x", groupID: otherGroupID))

        store.clearGroup(groupID)

        let inGroup = store.profiles.first(where: { $0.host == "in-group.example.com" })
        let otherGroup = store.profiles.first(where: { $0.host == "other-group.example.com" })
        XCTAssertNil(inGroup?.groupID)
        XCTAssertEqual(otherGroup?.groupID, otherGroupID)
    }

    func testResetWorkspaceScopedProfilesClearsOnlyThatWorkspaceAndDoesNotDeleteAnyProfile() {
        let (store, _) = makeStore()
        let deletedWorkspaceID = UUID()
        let otherWorkspaceID = UUID()
        store.saveProfile(SSHProfile(host: "scoped.example.com", username: "modot", password: "x", workspaceID: deletedWorkspaceID))
        store.saveProfile(SSHProfile(host: "elsewhere.example.com", username: "modot", password: "x", workspaceID: otherWorkspaceID))

        store.resetWorkspaceScopedProfiles(deletedWorkspaceID)

        // Nothing is deleted — the server config a user typed in stays.
        XCTAssertEqual(store.profiles.count, 2)
        let scoped = store.profiles.first(where: { $0.host == "scoped.example.com" })
        let elsewhere = store.profiles.first(where: { $0.host == "elsewhere.example.com" })
        XCTAssertNil(scoped?.workspaceID)
        XCTAssertEqual(elsewhere?.workspaceID, otherWorkspaceID)
    }

    private func makeStore() -> (TerminalWorkspaceStore, UserDefaults) {
        let defaults = makeDefaults()
        return (TerminalWorkspaceStore(vault: InMemorySSHProfileVault(), defaults: defaults), defaults)
    }

    private func makeDefaults() -> UserDefaults {
        let suiteName = "TerminalWorkspaceStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }
}
