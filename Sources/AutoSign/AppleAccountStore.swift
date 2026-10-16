import AutoSignLocalization
import Foundation
import Security

struct AppleAccountCredentials: Codable, Sendable {
    var email: String
    var password: String
    var dsid: String
    var authToken: String
    var firstName: String
    var lastName: String
    var authenticatedAt: Date
    var authenticationProvider: String? = nil
}

/// macOS login-keychain items restricted to AutoSign's code signing requirement.
/// This does not require paid-team Mac provisioning profiles. Screen locking and
/// locking the login keychain are separate; a locked keychain fails without UI.
@MainActor
enum AppleAccountStore {
    nonisolated static let service = "local.autosign.desktop.apple-account"
    nonisolated static let account = "primary-v1"

    nonisolated static func query(account: String = account) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account,
         kSecUseDataProtectionKeychain as String: false,
         kSecAttrSynchronizable as String: false]
    }

    nonisolated static func attributes(data: Data) -> [String: Any] {
        [kSecValueData as String: data,
         kSecAttrLabel as String: L10n.tr("AutoSign 独立 Apple 账号")]
    }

    static func save(_ credentials: AppleAccountCredentials) throws {
        try saveData(JSONEncoder().encode(credentials), account: account)
    }

    static func saveData(_ data: Data, account: String) throws {
        try requireUnlockedKeychain()
        let attrs = attributes(data: data)
        let status = try withoutInteraction { SecItemUpdate(query(account: account) as CFDictionary, attrs as CFDictionary) }
        if status == errSecItemNotFound {
            var creation = query(account: account).merging(attrs) { _, new in new }
            // Changing an existing ACL can require UI even when data writes are
            // allowed. Establish this app's ACL once; preserve it on token refresh.
            creation[kSecAttrAccess as String] = try applicationAccess()
            let added = try withoutInteraction { SecItemAdd(creation as CFDictionary, nil) }
            guard added == errSecSuccess else { throw failure(added) }
        } else if status != errSecSuccess { throw failure(status) }
    }

    static func load() throws -> AppleAccountCredentials? {
        guard let data = try loadData(account: account) else { return nil }
        return try JSONDecoder().decode(AppleAccountCredentials.self, from: data)
    }

    static func loadData(account: String) throws -> Data? {
        try requireUnlockedKeychain()
        var request = query(account: account)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = try withoutInteraction { SecItemCopyMatching(request as CFDictionary, &result) }
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw failure(status) }
        return data
    }

    static func remove() throws {
        try removeData(account: account)
    }

    static func removeData(account: String) throws {
        try requireUnlockedKeychain()
        let status = try withoutInteraction { SecItemDelete(query(account: account) as CFDictionary) }
        guard status == errSecSuccess || status == errSecItemNotFound else { throw failure(status) }
    }

    static func checkAvailability() throws {
        let probe = "setup-probe-" + UUID().uuidString
        defer { try? removeData(account: probe) }
        let data = Data(UUID().uuidString.utf8)
        try saveData(data, account: probe)
        guard try loadData(account: probe) == data else { throw failure(errSecDecode) }
        let updated = Data(UUID().uuidString.utf8)
        try saveData(updated, account: probe)
        guard try loadData(account: probe) == updated else { throw failure(errSecDecode) }
    }

    static func applicationAccess() throws -> SecAccess {
        var trusted: SecTrustedApplication?
        guard let executable = Bundle.main.executableURL?.path else { throw failure(errSecInternalComponent) }
        let trustedStatus = SecTrustedApplicationCreateFromPath(executable, &trusted)
        guard trustedStatus == errSecSuccess, let trusted else { throw failure(trustedStatus) }
        var access: SecAccess?
        let status = SecAccessCreate(L10n.tr("AutoSign 独立 Apple 账号") as CFString, [trusted] as CFArray, &access)
        guard status == errSecSuccess, let access else { throw failure(status) }
        return access
    }

    /// The file-based keychain uses this legacy API. Data-protection query UI
    /// flags are not supported by all legacy add/update operations. Main-actor
    /// isolation keeps this process-wide flag scoped to a synchronous operation.
    private static func withoutInteraction<T>(_ body: () -> T) throws -> T {
        var allowed: DarwinBoolean = false
        let queried = SecKeychainGetUserInteractionAllowed(&allowed)
        guard queried == errSecSuccess else { throw failure(queried) }
        let disabled = SecKeychainSetUserInteractionAllowed(false)
        guard disabled == errSecSuccess else { throw failure(disabled) }
        defer { SecKeychainSetUserInteractionAllowed(allowed.boolValue) }
        return body()
    }

    static func requireUnlockedKeychain() throws {
        var keychain: SecKeychain?
        let copied = SecKeychainCopyDefault(&keychain)
        guard copied == errSecSuccess, let keychain else { throw failure(copied) }
        var status: SecKeychainStatus = 0
        let checked = SecKeychainGetStatus(keychain, &status)
        guard checked == errSecSuccess else { throw failure(checked) }
        guard status & kSecUnlockStateStatus != 0 else { throw failure(errSecInteractionNotAllowed) }
    }

    nonisolated static func failure(_ status: OSStatus) -> AutoSignError {
        if status == errSecAuthFailed {
            return .command(L10n.tr("AutoSign 钥匙串访问认证失败（-25293）。若刚更新或重新构建应用，请完全退出 AutoSign 后重新打开再试；仍失败时，请解锁登录钥匙串并检查 AutoSign 的代码签名与钥匙串访问控制。原凭据已保留。"))
        }
        if status == errSecMissingEntitlement {
            return .command(L10n.tr("此 AutoSign 构建没有系统钥匙串访问权限，请检查应用代码签名与钥匙串访问控制。"))
        }
        if status == errSecInteractionNotAllowed {
            return .command(L10n.tr("Mac 登录钥匙串暂不可访问。请在重启后先登录一次 Mac，或解锁登录钥匙串；凭据已保留，不会因读取失败而删除。"))
        }
        return .command(L10n.tr("AutoSign 系统钥匙串操作失败（\(status)）。凭据不会写入配置文件或日志。"))
    }
}

struct IndependentTeam: Codable, Identifiable, Sendable {
    var id: String
    var name: String
    var isFree: Bool
}

struct IndependentAccountSummary: Codable, Sendable {
    var email: String
    var name: String
    var teams: [IndependentTeam]
    var authenticatedAt: Date
}

enum IndependentAccountError: Error, LocalizedError {
    case signInRequired
    case verificationRequired
    case invalidResponse
    case teamMismatch
    case providerChanged

    var errorDescription: String? {
        switch self {
        case .signInRequired: L10n.tr("请在 AutoSign“签名设置”登录独立 Apple 账号。")
        case .verificationRequired: L10n.tr("Apple 要求双重验证，请在 AutoSign“签名设置”重新登录并完成验证码验证；已保留原凭据和应用签名。")
        case .invalidResponse: L10n.tr("Apple 未返回有效的账号或签名数据，请稍后重试。")
        case .teamMismatch: L10n.tr("独立账号不属于此应用原有签名团队。请登录原团队的账号；不会自动切换团队或覆盖原应用。")
        case .providerChanged: L10n.tr("设备认证服务已改变，请在 AutoSign 重新登录独立账号；原凭据已保留。")
        }
    }
}
