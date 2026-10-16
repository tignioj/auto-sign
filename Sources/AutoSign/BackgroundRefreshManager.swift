import AutoSignLocalization
import Foundation
import UserNotifications

enum BackgroundRefreshManager {
    static let label = "local.autosign.desktop.refresh"
    private static let statusKey = "lastBackgroundStatus"
    private static let dateKey = "lastBackgroundDate"

    static var launchAgentURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    static var isInstalled: Bool { FileManager.default.fileExists(atPath: launchAgentURL.path) }

    static var needsMigration: Bool {
        guard isInstalled, let executable = Bundle.main.executableURL,
              let data = try? Data(contentsOf: launchAgentURL),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return isInstalled }
        return requiresMigration(plist, executable: executable)
    }

    static func requiresMigration(_ plist: [String: Any], executable: URL,
                                  bundleID: String = Bundle.main.bundleIdentifier ?? "local.autosign.desktop") -> Bool {
        plist["ProgramArguments"] as? [String] != [executable.path, "--background-refresh"]
            || plist["AssociatedBundleIdentifiers"] as? [String] != [bundleID]
    }

    static var lastStatus: String {
        let message = UserDefaults.standard.string(forKey: statusKey) ?? L10n.tr("尚未运行后台检查")
        guard let date = UserDefaults.standard.object(forKey: dateKey) as? Date else { return message }
        return "\(L10n.date(date)) · \(message)"
    }

    static func install() async throws {
        guard LocalNetworkPreparation.isPrepared() else {
            throw AutoSignError.command(L10n.tr("请先打开 AutoSign，在前台完成本地网络授权与检查，再开启后台自动续签。"))
        }
        guard let executable = Bundle.main.executableURL else {
            throw AutoSignError.command(L10n.tr("无法定位 AutoSign 可执行文件。"))
        }
        let logs = try applicationSupportURL().appendingPathComponent("Logs", isDirectory: true)
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: launchAgentURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let plist = configuration(executable: executable, logs: logs)
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: launchAgentURL, options: .atomic)

        let domain = "gui/\(getuid())"
        _ = try? await ProcessRunner.run("/bin/launchctl", ["bootout", "\(domain)/\(label)"])
        _ = try await ProcessRunner.checked(
            "/bin/launchctl", ["bootstrap", domain, launchAgentURL.path],
            context: L10n.tr("无法启动后台自动续签任务。")
        )
        UserDefaults.standard.set(true, forKey: "autoRefreshEnabled")
        record(L10n.tr("后台任务已安装，每 30 分钟检查一次"))
    }

    static func configuration(executable: URL, logs: URL, bundleID: String = Bundle.main.bundleIdentifier ?? "local.autosign.desktop") -> [String: Any] {
        [
            "Label": label,
            "AssociatedBundleIdentifiers": [bundleID],
            "ProgramArguments": [executable.path, "--background-refresh"],
            "RunAtLoad": true,
            "StartInterval": Int(RefreshStatusStore.interval),
            "ProcessType": "Background",
            "StandardOutPath": logs.appendingPathComponent("refresh.log").path,
            "StandardErrorPath": logs.appendingPathComponent("refresh-error.log").path
        ]
    }

    static func authorizeNotifications() async {
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
    }

    static func uninstall() async throws {
        let domain = "gui/\(getuid())"
        _ = try? await ProcessRunner.run("/bin/launchctl", ["bootout", "\(domain)/\(label)"])
        if FileManager.default.fileExists(atPath: launchAgentURL.path) {
            try FileManager.default.removeItem(at: launchAgentURL)
        }
        UserDefaults.standard.set(false, forKey: "autoRefreshEnabled")
        record(L10n.tr("后台自动续签已关闭"))
    }

    static func applicationSupportURL() throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        ).appendingPathComponent("AutoSign", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    static func record(_ message: String) {
        UserDefaults.standard.set(message, forKey: statusKey)
        UserDefaults.standard.set(Date(), forKey: dateKey)
    }

    static func notify(title: String, body: String) async {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        try? await UNUserNotificationCenter.current().add(request)
    }
}
