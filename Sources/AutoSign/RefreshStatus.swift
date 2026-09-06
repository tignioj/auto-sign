import Foundation

struct DeviceRefreshStatus: Codable, Identifiable, Sendable {
    var id: String
    var name: String
    var state: String = "尚无续签记录"
    var updatedAt: Date?
    var lastSuccess: Date?
    var expiration: Date?
    var failure: String?
    var nextEligible: Date?

    func nextAttempt(check: Date?, enabled: Bool, now: Date = Date()) -> String {
        guard enabled else { return "自动续签已关闭" }
        guard let check else { return "等待首次后台检查" }
        if check < now { return "检查时间已到，等待后台运行（Mac 需保持唤醒）" }
        let window = nextEligible ?? expiration?.addingTimeInterval(-86_400)
        let due = failure != nil ? check : max(check, window ?? check)
        return "预计 " + due.formatted(date: .abbreviated, time: .shortened)
    }
}

enum RefreshStatusStore {
    static let interval: TimeInterval = 1_800
    static func load(_ udid: String, preferences: UserDefaults = .standard) -> DeviceRefreshStatus? {
        guard let data = preferences.data(forKey: "deviceRefresh.\(udid)") else { return nil }
        return try? JSONDecoder().decode(DeviceRefreshStatus.self, from: data)
    }

    static func record(_ udid: String, name: String? = nil, state: String,
                       failure: String? = nil, expiration: Date? = nil,
                       nextEligible: Date? = nil, success: Bool = false, preferences: UserDefaults = .standard) {
        var value = load(udid, preferences: preferences) ?? DeviceRefreshStatus(id: udid, name: name ?? udid)
        if let name { value.name = name }
        value.state = state
        value.updatedAt = Date()
        value.failure = failure
        value.nextEligible = nextEligible
        if success { value.lastSuccess = Date(); value.expiration = expiration }
        if let data = try? JSONEncoder().encode(value) { preferences.set(data, forKey: "deviceRefresh.\(udid)") }
    }

    static func failureSummary(_ raw: String) -> String {
        if raw.contains("No Accounts") { return "Xcode 未读取到可用账号。请在 Xcode → Settings → Apple Accounts 检查登录状态。" }
        if raw.contains("developer disk image") { return "无法挂载开发者磁盘镜像。请解锁设备，通过 USB 连接并在 Xcode 中检查设备支持。" }
        if raw.localizedCaseInsensitiveContains("locked") { return "设备或钥匙串已锁定，请解锁后重试。" }
        return raw.split(separator: "\n").first.map(String.init) ?? raw
    }
}

struct AccountStatus: Sendable {
    var title = "正在检查 Xcode 账号…"
    var detail = "本地签名证书不代表账号仍可在线续签。"

    static func inspect() async -> AccountStatus {
        // Read the persisted account index, not a certificate or Xcode's cached UI.
        guard let result = try? await ProcessRunner.run("/usr/bin/defaults", ["export", "com.apple.dt.Xcode", "-"]),
              result.status == 0,
              let root = try? PropertyListSerialization.propertyList(from: result.data, format: nil) as? [String: Any],
              let lists = root["DVTDeveloperAccountManagerAppleIDLists"] as? [String: Any],
              let accounts = lists["IDE.Identifiers.Prod"] as? [Any] else {
            return AccountStatus(title: "账号状态未知", detail: "无法读取 Xcode 账号记录，请在 Xcode 中确认；未验证在线登录。")
        }
        if accounts.isEmpty {
            return AccountStatus(title: "未检测到 Xcode 账号记录", detail: "自动续签可能受阻。请在 Xcode → Settings → Apple Accounts 检查或添加账号。")
        }
        return AccountStatus(title: "检测到 \(accounts.count) 个 Xcode 账号记录", detail: "尚未验证在线登录有效性；实际续签结果见下方设备记录。")
    }
}
