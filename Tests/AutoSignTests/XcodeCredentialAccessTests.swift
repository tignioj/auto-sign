import AutoSignLocalization
import CoreGraphics
import Foundation
import Testing
@testable import AutoSign

@Test func xcodeCredentialAccessRequiresAnUnlockedConsoleSession() {
    let unlocked: [String: Any] = [kCGSessionOnConsoleKey as String: true,
                                   kCGSessionLoginDoneKey as String: true]
    #expect(XcodeCredentialAccess.state(session: unlocked) == .available)
    var locked = unlocked
    locked["CGSSessionScreenIsLocked"] = true
    #expect(XcodeCredentialAccess.state(session: locked) == .locked)
    #expect(XcodeCredentialAccess.state(session: nil) == .unavailable)
    #expect(XcodeCredentialAccess.state(session: [:]) == .unavailable)
    #expect(XcodeCredentialAccess.state(session: [kCGSessionOnConsoleKey as String: false]) == .unavailable)
}

@MainActor @Test func xcodeCredentialsWaitThroughLockAndResumeOnce() async throws {
    var waits = 0
    var messages: [String] = []
    try await XcodeCredentialAccess.waitUntilAvailable(
        state: { waits < 2 ? .locked : .available },
        pause: { waits += 1 },
        statusChanged: { messages.append($0) })
    #expect(waits == 2)
    #expect(messages.count == 2)
    #expect(messages.first?.contains((AppLanguage.current == .english ? "Waiting for the Mac to unlock" : "等待 Mac 解锁")) == true)
    #expect(messages.last?.contains((AppLanguage.current == .english ? "Resuming" : "继续")) == true)
}

@MainActor @Test func xcodeCredentialWaitCancellationNeverResumes() async {
    var messages: [String] = []
    do {
        try await XcodeCredentialAccess.waitUntilAvailable(state: { .locked },
            pause: { throw CancellationError() }, statusChanged: { messages.append($0) })
        Issue.record("Expected cancellation")
    } catch { #expect(error is CancellationError) }
    #expect(messages.count == 1)
    #expect(messages.first?.contains((AppLanguage.current == .english ? "Waiting for the Mac to unlock" : "等待 Mac 解锁")) == true)
}

@MainActor @Test func xcodeCredentialWaitFailsClosedWhenSessionIsUnknown() async {
    var waits = 0
    do {
        try await XcodeCredentialAccess.waitUntilAvailable(state: { .unavailable },
            pause: { waits += 1 }, statusChanged: { _ in })
        Issue.record("Expected unavailable session failure")
    } catch { #expect(error.localizedDescription.contains((AppLanguage.current == .english ? "Xcode was not called" : "已停止调用 Xcode"))) }
    #expect(waits == 0)
}

@Test func xcodeCredentialFailuresExplainRecoveryAndKeepOriginalDetails() {
    for detail in ["Invalid credentials in keychain: missing Xcode-Username",
                   "error: No Accounts: Add a new account", "errSecInteractionNotAllowed (-25308)"] {
        let message = XcodeCredentialAccess.provisioningFailure(detail)
        #expect(message.contains("Apple Accounts"))
        #expect(message.contains((AppLanguage.current == .english ? "Unlock your Mac" : "解锁 Mac")))
        #expect(message.contains(detail))
    }
    let preparation = "The developer disk image could not be mounted"
    #expect(DevicePreparationRetry.isRetryable(XcodeCredentialAccess.provisioningFailure(preparation)))
    #expect(!XcodeCredentialAccess.provisioningFailure(preparation).contains(L10n.tr("重新登录")))
}
