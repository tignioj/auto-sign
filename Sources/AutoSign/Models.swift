import AutoSignLocalization
import Foundation

enum DeviceKind: String, CaseIterable, Identifiable, Sendable {
    case iPhone
    case iPad

    var id: String { rawValue }
    var title: String { rawValue }
    var symbol: String { self == .iPhone ? "iphone" : "ipad" }
}

struct AppleDevice: Identifiable, Hashable, Sendable {
    let id: String
    let udid: String
    let name: String
    let marketingName: String
    let kind: DeviceKind
    let osVersion: String
    let isPaired: Bool
    let developerModeEnabled: Bool
    let isConnected: Bool

    var statusText: String {
        if !isPaired { return L10n.tr("需与这台 Mac 配对") }
        if !isConnected { return L10n.tr("设备未连接") }
        if !developerModeEnabled { return L10n.tr("需开启开发者模式") }
        return L10n.tr("已连接，可安装")
    }

    var isReadyForInstallation: Bool {
        isPaired && isConnected && developerModeEnabled
    }
}

enum DeviceSelectionStore {
    static let deviceUDIDsKey = "deviceUDIDs"
    static let legacyDeviceUDIDKey = "deviceUDID"
    static let pendingDeviceUDIDsKey = "pendingDeviceUDIDs"

    static func load(from preferences: UserDefaults) -> [String] {
        let stored = preferences.stringArray(forKey: deviceUDIDsKey) ?? []
        let candidates: [String]
        if stored.isEmpty, let legacy = preferences.string(forKey: legacyDeviceUDIDKey) {
            candidates = [legacy]
        } else {
            candidates = stored
        }
        var seen = Set<String>()
        return candidates.filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    static func save(_ udids: [String], to preferences: UserDefaults) {
        let previous = Set(load(from: preferences))
        var seen = Set<String>()
        let normalized = udids.filter { !$0.isEmpty && seen.insert($0).inserted }
        let normalizedSet = Set(normalized)
        if normalized.isEmpty {
            preferences.removeObject(forKey: deviceUDIDsKey)
            preferences.removeObject(forKey: legacyDeviceUDIDKey)
            savePending([], to: preferences)
        } else {
            preferences.set(normalized, forKey: deviceUDIDsKey)
            // Keep the legacy key so an older installed copy still has a usable target.
            preferences.set(normalized[0], forKey: legacyDeviceUDIDKey)
            var pending = Set(loadPending(from: preferences))
            pending.formIntersection(normalizedSet)
            pending.formUnion(normalizedSet.subtracting(previous))
            savePending(normalized.filter { pending.contains($0) }, to: preferences)
        }
    }

    static func loadPending(from preferences: UserDefaults) -> [String] {
        var seen = Set<String>()
        return (preferences.stringArray(forKey: pendingDeviceUDIDsKey) ?? [])
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    static func savePending(_ udids: [String], to preferences: UserDefaults) {
        var seen = Set<String>()
        let normalized = udids.filter { !$0.isEmpty && seen.insert($0).inserted }
        if normalized.isEmpty {
            preferences.removeObject(forKey: pendingDeviceUDIDsKey)
        } else {
            preferences.set(normalized, forKey: pendingDeviceUDIDsKey)
        }
    }
}

struct SigningIdentity: Identifiable, Hashable, Sendable {
    let hash: String
    let name: String
    var id: String { hash }
}

struct ProvisioningProfile: Sendable {
    let name: String
    let uuid: String
    let expirationDate: Date
    let applicationIdentifier: String
    let teamIdentifier: String
    let provisionedDevices: Set<String>
    let provisionsAllDevices: Bool
    let entitlements: [String: AnySendable]
    var signingCertificateHashes: Set<String> = []
    var creationDate: Date? = nil
    var timeToLiveDays: Int? = nil

    var isExpired: Bool { expirationDate < Date() }
}

/// A small sendable wrapper used only while moving property-list values between tasks.
struct AnySendable: @unchecked Sendable {
    let value: Any
}

enum InstallStage: Equatable, Sendable {
    case idle
    case preparing
    case signing
    case installing
    case finished
    case failed(String)

    var title: String {
        switch self {
        case .idle: L10n.tr("准备就绪")
        case .preparing: L10n.tr("正在处理应用…")
        case .signing: L10n.tr("正在签名…")
        case .installing: L10n.tr("正在安装到设备…")
        case .finished: L10n.tr("处理完成")
        case .failed: L10n.tr("操作未完成")
        }
    }

    var isRunning: Bool {
        self == .preparing || self == .signing || self == .installing
    }
}

struct CommandResult: Sendable {
    let status: Int32
    let data: Data
    var output: String { String(decoding: data, as: UTF8.self) }
}

enum AutoSignError: LocalizedError {
    case command(String)
    case invalidIPA(String)
    case invalidProfile(String)
    case incompatibleProfile(String)
    case missingSelection(String)

    var errorDescription: String? {
        switch self {
        case .command(let message), .invalidIPA(let message), .invalidProfile(let message),
             .incompatibleProfile(let message), .missingSelection(let message):
            message
        }
    }
}
