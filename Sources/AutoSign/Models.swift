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
    let developerModeEnabled: Bool
    let isConnected: Bool

    var statusText: String {
        if !isConnected { return "设备未连接" }
        if !developerModeEnabled { return "需开启开发者模式" }
        return "已连接，可安装"
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
    case finished(URL)
    case failed(String)

    var title: String {
        switch self {
        case .idle: "准备就绪"
        case .preparing: "正在检查文件…"
        case .signing: "正在签名…"
        case .installing: "正在安装到设备…"
        case .finished: "签名并安装成功"
        case .failed: "操作未完成"
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
