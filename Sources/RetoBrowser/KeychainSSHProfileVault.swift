import Foundation
import Security

protocol SSHProfileVault: AnyObject {
    func loadProfiles() throws -> [SSHProfile]
    func saveProfiles(_ profiles: [SSHProfile]) throws
}

enum SSHProfileVaultError: LocalizedError {
    case keychain(OSStatus)
    case invalidData

    var errorDescription: String? {
        switch self {
        case .keychain(let status):
            if let message = SecCopyErrorMessageString(status, nil) as String? {
                return "Keychain error: \(message)"
            }
            return "Keychain error (\(status))."
        case .invalidData:
            return "The saved SSH profiles could not be decoded."
        }
    }
}

final class KeychainSSHProfileVault: SSHProfileVault {
    private let service: String
    private let account: String

    init(
        service: String = "dev.modot.RetoBrowser.ssh-profiles",
        account: String = "profiles.v1"
    ) {
        self.service = service
        self.account = account
    }

    func loadProfiles() throws -> [SSHProfile] {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess else { throw SSHProfileVaultError.keychain(status) }
        guard let data = result as? Data else { throw SSHProfileVaultError.invalidData }

        do {
            return try JSONDecoder().decode([SSHProfile].self, from: data)
        } catch {
            throw SSHProfileVaultError.invalidData
        }
    }

    func saveProfiles(_ profiles: [SSHProfile]) throws {
        let data = try JSONEncoder().encode(profiles)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]
        let updateStatus = SecItemUpdate(baseQuery as CFDictionary, attributes as CFDictionary)

        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw SSHProfileVaultError.keychain(updateStatus)
        }

        var addQuery = baseQuery
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        guard addStatus == errSecSuccess else { throw SSHProfileVaultError.keychain(addStatus) }
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: false,
            kSecUseDataProtectionKeychain as String: true,
        ]
    }
}
