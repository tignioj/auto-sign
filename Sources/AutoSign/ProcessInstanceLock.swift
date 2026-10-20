import Darwin
import Foundation

/// Keep the descriptor open for the process lifetime. Never unlink this file:
/// another process may already have opened the same inode while waiting to start.
final class ProcessInstanceLock {
    private let descriptor: Int32

    init?(url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let opened = open(url.path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard opened >= 0 else { throw Self.systemError() }
        guard flock(opened, LOCK_EX | LOCK_NB) == 0 else {
            let code = errno
            close(opened)
            if code == EWOULDBLOCK { return nil }
            throw Self.systemError(code)
        }
        // The PID is only for activating the owner. The OS lock determines
        // ownership, so stale metadata after a crash never blocks a restart.
        let pid = Array("\(getpid())\n".utf8)
        guard ftruncate(opened, 0) == 0,
              pid.withUnsafeBytes({ pwrite(opened, $0.baseAddress, $0.count, 0) }) == pid.count else {
            let error = Self.systemError()
            close(opened)
            throw error
        }
        descriptor = opened
    }

    static func ownerProcessID(at url: URL) -> pid_t? {
        guard let text = try? String(contentsOf: url, encoding: .utf8),
              let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 0 else { return nil }
        return pid
    }

    private static func systemError(_ code: Int32 = errno) -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
    }

    deinit { close(descriptor) }
}
