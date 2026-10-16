import AutoSignLocalization
import AppKit
import CryptoKit
import Foundation
import Network

enum LocalNetworkPreparation {
    static let preferenceKey = "localNetworkPreparedExecutable"
    static var isRequired: Bool { ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 15 }

    static func executableIdentity(url: URL? = Bundle.main.executableURL,
                                   bundleID: String? = Bundle.main.bundleIdentifier) -> String? {
        guard let url, let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return "\(bundleID ?? "")|\(url.standardizedFileURL.path)|\(hash)"
    }

    /// This records a successful foreground check, not an OS authorization value.
    static func isPrepared(preferences: UserDefaults = .standard,
                           identity: String? = executableIdentity(), required: Bool = isRequired) -> Bool {
        guard required else { return true }
        guard let identity else { return false }
        return preferences.string(forKey: preferenceKey) == identity
    }
}

@MainActor
final class LocalNetworkAccess: ObservableObject {
    enum State: Equatable, Sendable {
        case notChecked, checking, ready, needsPermission, unavailable, cancelled

        var detail: String {
            switch self {
            case .notChecked: L10n.tr("无线续签需要本地网络权限，请先在这里完成检查。")
            case .checking: L10n.tr("正在检查本地网络访问。如果系统弹出 AutoSign 权限提示，请选择“允许”。")
            case .ready: L10n.tr("本地网络访问检查通过，可以设置后台自动续签。")
            case .needsPermission: L10n.tr("尚未获得本地网络访问权限。请在系统设置 → 隐私与安全性 → 本地网络中允许 AutoSign，然后重新检查。")
            case .unavailable: L10n.tr("暂时无法确认本地网络访问，请连接 Wi-Fi 或有线局域网后重新检查。")
            case .cancelled: L10n.tr("检查已取消。开启后台自动续签前需要完成本地网络检查。")
            }
        }
    }

    static let shared = LocalNetworkAccess()
    @Published private(set) var state: State = .notChecked
    var isChecking: Bool { state == .checking }
    private let preferences: UserDefaults
    private let identity: () -> String?
    private let required: Bool
    private let probe: @MainActor () async -> State
    private var task: Task<State, Never>?
    private var generation = UUID()

    init(preferences: UserDefaults = .standard, required: Bool = LocalNetworkPreparation.isRequired,
         identity: @escaping () -> String? = { LocalNetworkPreparation.executableIdentity() },
         probe: @escaping @MainActor () async -> State = { await LocalNetworkProbe().run() }) {
        self.preferences = preferences
        self.required = required
        self.identity = identity
        self.probe = probe
    }

    @discardableResult func check() async -> Bool {
        if let task {
            let requestID = generation
            return complete(await task.value, requestID: requestID)
        }
        guard required else { state = .ready; return true }
        let requestID = UUID()
        generation = requestID
        state = .checking
        let request = Task { await probe() }
        task = request
        let result = await request.value
        return complete(result, requestID: requestID)
    }

    private func complete(_ result: State, requestID: UUID) -> Bool {
        guard generation == requestID else { return false }
        task = nil
        if result == .ready, let identity = identity() {
            preferences.set(identity, forKey: LocalNetworkPreparation.preferenceKey)
        } else if result == .needsPermission {
            preferences.removeObject(forKey: LocalNetworkPreparation.preferenceKey)
        }
        state = result
        return result == .ready
    }

    func cancel() {
        generation = UUID()
        task?.cancel()
        task = nil
        state = .cancelled
    }

    func openSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocalNetwork") else { return }
        NSWorkspace.shared.open(url)
    }
}

/// Browse a short-lived, unique AutoSign Bonjour advertisement. A browser being
/// `ready` alone does not prove access: require our result on a non-loopback LAN.
@MainActor
private final class LocalNetworkProbe {
    private let name = "AutoSign-Setup-\(UUID().uuidString)"
    private var browser: NWBrowser?
    private var listener: NWListener?
    private var timeout: Task<Void, Never>?
    private var continuation: CheckedContinuation<LocalNetworkAccess.State, Never>?
    private var policyDenied = false

    func run() async -> LocalNetworkAccess.State {
        await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else { continuation.resume(returning: .cancelled); return }
                self.continuation = continuation
                start()
            }
        }, onCancel: { Task { @MainActor in self.finish(.cancelled) } })
    }

    private func start() {
        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = false
        let browser = NWBrowser(for: .bonjour(type: "_autosign._tcp", domain: "local."), using: parameters)
        browser.stateUpdateHandler = { [weak self] state in
            Task { @MainActor [weak self] in
                guard let self, self.continuation != nil else { return }
                switch state {
                case .ready: self.startListener()
                case .waiting(let error):
                    if Self.isPolicyDenied(error) { self.policyDenied = true }
                case .failed(let error): self.finish(Self.isPolicyDenied(error) ? .needsPermission : .unavailable)
                default: break
                }
            }
        }
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            Task { @MainActor [weak self] in
                guard let self, self.continuation != nil else { return }
                for result in results {
                    guard case .service(let name, let type, _, _) = result.endpoint,
                          name == self.name, type == "_autosign._tcp",
                          result.interfaces.contains(where: { $0.type == .wifi || $0.type == .wiredEthernet }) else { continue }
                    self.finish(.ready)
                    return
                }
            }
        }
        self.browser = browser
        startListener()
        guard continuation != nil else { return }
        browser.start(queue: .main)
        timeout = Task {
            do { try await Task.sleep(for: .seconds(60)) } catch { return }
            finish(policyDenied ? .needsPermission : .unavailable)
        }
    }

    private func startListener() {
        guard listener == nil, continuation != nil else { return }
        do {
            let parameters = NWParameters.tcp
            parameters.includePeerToPeer = false
            let listener = try NWListener(using: parameters, on: .any)
            listener.service = NWListener.Service(name: name, type: "_autosign._tcp", domain: "local.")
            listener.newConnectionHandler = { $0.cancel() }
            listener.stateUpdateHandler = { [weak self, weak listener] state in
                Task { @MainActor [weak self] in
                    guard let self, let listener, self.listener === listener, self.continuation != nil else { return }
                    if case .failed(let error) = state {
                        if Self.isPolicyDenied(error) {
                            self.policyDenied = true
                            self.listener?.cancel()
                            self.listener = nil
                        } else { self.finish(.unavailable) }
                    }
                }
            }
            self.listener = listener
            listener.start(queue: .main)
        } catch { finish(.unavailable) }
    }

    private static func isPolicyDenied(_ error: NWError) -> Bool {
        if case .dns(let code) = error { return code == -65570 } // kDNSServiceErr_PolicyDenied
        return false
    }

    private func finish(_ state: LocalNetworkAccess.State) {
        guard let continuation else { return }
        self.continuation = nil
        browser?.cancel(); browser = nil
        listener?.cancel(); listener = nil
        timeout?.cancel(); timeout = nil
        continuation.resume(returning: state)
    }
}
