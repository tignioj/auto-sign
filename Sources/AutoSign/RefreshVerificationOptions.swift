import AutoSignLocalization
import Foundation

struct RefreshVerificationOptions: Sendable {
    static let launchPreferenceKey = "verifyLaunchAfterRefresh"

    let verifyLaunch: Bool

    static func load(from preferences: UserDefaults = .standard) -> Self {
        Self(verifyLaunch: preferences.bool(forKey: launchPreferenceKey))
    }

    var completionMessage: String {
        verifyLaunch ? L10n.tr("启动验证通过") : L10n.tr("已跳过启动验证")
    }

    /// Profile verification remains mandatory even when the user skips launching.
    func verify(profile: () async throws -> Void, launch: () async throws -> Void) async throws {
        try Task.checkCancellation()
        try await profile()
        try Task.checkCancellation()
        if verifyLaunch { try await launch() }
    }
}
