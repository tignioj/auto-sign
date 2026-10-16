import AutoSignLocalization
import Foundation

/// Retry only Xcode's device preparation failures, at most once per operation.
enum DevicePreparationRetry {
    static func isRetryable(_ message: String) -> Bool {
        message.localizedCaseInsensitiveContains("developer disk image could not be mounted")
            || message.localizedCaseInsensitiveContains("Timed out waiting for all destinations matching")
    }

    static func run(
        operation: () async throws -> Void,
        beforeRetry: () async throws -> Void
    ) async throws {
        do {
            try await operation()
        } catch {
            guard isRetryable(error.localizedDescription) else { throw error }
            try Task.checkCancellation()
            try await beforeRetry()
            try Task.checkCancellation()
            do {
                try await operation()
            } catch {
                if error is CancellationError { throw error }
                throw AutoSignError.command(L10n.tr("等待设备准备后已自动重试 1 次，仍未成功。\n\(error.localizedDescription)"))
            }
        }
    }
}
