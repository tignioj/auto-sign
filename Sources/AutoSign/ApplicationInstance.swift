import AppKit
import Foundation

enum LaunchMode: Equatable, CaseIterable {
    case interface
    case backgroundRefresh
    case installBackgroundRefresh
    case verifyIndependentAccount

    init(arguments: [String]) {
        if arguments.contains("--verify-independent-account") { self = .verifyIndependentAccount }
        else if arguments.contains("--background-refresh") { self = .backgroundRefresh }
        else if arguments.contains("--install-background-refresh") { self = .installBackgroundRefresh }
        else { self = .interface }
    }

    var instanceRole: ApplicationInstanceRole? {
        switch self {
        case .interface, .installBackgroundRefresh: .interface
        case .backgroundRefresh: .backgroundRefresh
        case .verifyIndependentAccount: nil
        }
    }
}

enum ApplicationInstanceRole: String {
    case interface
    case backgroundRefresh

    func lockURL(in directory: URL) -> URL {
        directory.appendingPathComponent("\(rawValue).lock")
    }
}

@MainActor
final class ApplicationInstance: NSObject {
    static let shared = ApplicationInstance()
    private static let activationNotification = Notification.Name("local.autosign.desktop.activateInterface")
    private var lock: ProcessInstanceLock?
    private var windowOpener: (() -> Void)?
    private var activationPending = false

    /// Called before constructing models, checking the network or migrating launchd.
    func start(mode: LaunchMode) throws -> Bool {
        guard let role = mode.instanceRole else { return true }
        let url = role.lockURL(in: try BackgroundRefreshManager.applicationSupportURL())
        guard let acquired = try ProcessInstanceLock(url: url) else {
            if mode == .interface { activateOwner(pid: ProcessInstanceLock.ownerProcessID(at: url)) }
            return false
        }
        // Older builds have no lock. Respect an already-running legacy GUI too;
        // launchd/diagnostic processes use the accessory activation policy.
        if role == .interface, let existing = legacyInterface() {
            if mode == .interface { activateOwner(pid: existing.processIdentifier) }
            withExtendedLifetime(acquired) {}
            return false
        }
        lock = acquired
        if mode == .interface {
            DistributedNotificationCenter.default().addObserver(
                self, selector: #selector(activateInterface), name: Self.activationNotification, object: nil
            )
        }
        return true
    }

    func registerWindowOpener(_ opener: @escaping () -> Void) {
        windowOpener = opener
        if activationPending { showInterface() }
    }

    @objc private func activateInterface(_ notification: Notification) { showInterface() }

    private func showInterface() {
        activationPending = true
        guard let windowOpener else { return }
        activationPending = false
        let windows = NSApplication.shared.windows.filter(\.canBecomeMain)
        if windows.isEmpty { windowOpener() }
        for window in windows {
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
        }
        NSApplication.shared.activate()
    }

    private func activateOwner(pid: pid_t?) {
        if let application = pid.flatMap({ NSRunningApplication(processIdentifier: $0) }) ?? legacyInterface() {
            NSApplication.shared.yieldActivation(to: application)
            application.activate(from: .current, options: [.activateAllWindows])
        }
        // The owner can also recreate a closed window. A request arriving during
        // startup is remembered until SwiftUI supplies its openWindow action.
        DistributedNotificationCenter.default().postNotificationName(
            Self.activationNotification, object: nil, userInfo: nil, deliverImmediately: true
        )
    }

    private func legacyInterface() -> NSRunningApplication? {
        NSRunningApplication.runningApplications(withBundleIdentifier: "local.autosign.desktop").first {
            $0.processIdentifier != getpid() && !$0.isTerminated && $0.activationPolicy == .regular
        }
    }
}
