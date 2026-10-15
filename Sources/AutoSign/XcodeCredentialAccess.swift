import CoreGraphics
import Foundation

/// Xcode's developer credentials use the data-protection keychain, independently
/// of the legacy login keychain. On the tested Xcode 27 build, a locked read also
/// removes the account from Xcode's persisted index. Wait before invoking Xcode.
@MainActor
enum XcodeCredentialAccess {
    enum State { case available, locked, unavailable }

    nonisolated static func currentState() -> State {
        state(session: CGSessionCopyCurrentDictionary() as? [String: Any])
    }

    nonisolated static func state(session: [String: Any]?) -> State {
        guard let session else { return .unavailable }
        // CGSession supplies this key when the console session is locked; it may
        // be absent in an unlocked session. Turning the display off alone is fine.
        if session["CGSSessionScreenIsLocked"] as? Bool == true { return .locked }
        guard session[kCGSessionOnConsoleKey as String] as? Bool == true,
              session[kCGSessionLoginDoneKey as String] as? Bool == true else { return .unavailable }
        return .available
    }

    static func waitUntilAvailable(
        state: () -> State = { currentState() },
        pause: () async throws -> Void = { try await Task.sleep(for: .seconds(3)) },
        statusChanged: @MainActor @Sendable (String) -> Void
    ) async throws {
        var waiting = false
        while true {
            try Task.checkCancellation()
            switch state() {
            case .available:
                if waiting { statusChanged("Mac 已解锁，继续请求 Xcode 续签…") }
                return
            case .locked:
                if !waiting {
                    statusChanged("等待 Mac 解锁：Xcode 账号凭据在锁屏时不可读取；解锁后自动继续，请勿重复提交。")
                    waiting = true
                }
                try await pause()
            case .unavailable:
                throw AutoSignError.command("无法确认 Mac 登录会话已解锁，已停止调用 Xcode。请切回已登录的 Mac 桌面后重试。")
            }
        }
    }

    nonisolated static func provisioningFailure(_ detail: String) -> String {
        let accountError = ["DVTDeveloperAccountCredentialsError", "missing Xcode-Username",
                            "missing Xcode-Token", "No Accounts:", "errSecInteractionNotAllowed"]
            .contains { detail.localizedCaseInsensitiveContains($0) }
        let context = accountError
            ? "Xcode 无法读取开发者账号凭据。请先解锁 Mac，再到 Xcode → Settings → Apple Accounts 检查并重新登录；锁屏期间读取失败可能导致 Xcode 移除账号记录。"
            : "Xcode 自动续期失败，具体原因见下方详情。"
        let detail = detail.trimmingCharacters(in: .whitespacesAndNewlines)
        return detail.isEmpty ? context : "\(context)\n\(detail)"
    }
}
