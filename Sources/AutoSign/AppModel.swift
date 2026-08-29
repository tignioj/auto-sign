import AppKit
import Foundation

@MainActor
final class AppModel: ObservableObject {
    @Published var deviceKind: DeviceKind = .iPhone
    @Published var devices: [AppleDevice] = []
    @Published var selectedDeviceID: String?
    @Published var ipaURL: URL?
    @Published var profileURL: URL?
    @Published var identities: [SigningIdentity] = []
    @Published var selectedIdentityID: String?
    @Published var stage: InstallStage = .idle
    @Published var detail = "连接设备，然后拖入一个 IPA 文件"
    @Published var isRefreshing = false
    @Published var pairingDeviceID: String?
    @Published var isDropTargeted = false
    @Published var autoRefreshEnabled = BackgroundRefreshManager.isInstalled
    @Published var lastBackgroundStatus = BackgroundRefreshManager.lastStatus

    var filteredDevices: [AppleDevice] { devices.filter { $0.kind == deviceKind } }
    var selectedDevice: AppleDevice? { devices.first { $0.id == selectedDeviceID } }
    var selectedIdentity: SigningIdentity? { identities.first { $0.id == selectedIdentityID } }
    var canInstall: Bool {
        ipaURL != nil && profileURL != nil && selectedDevice?.isReadyForInstallation == true && !stage.isRunning
    }

    init(performInitialRefresh: Bool = true) {
        if let path = UserDefaults.standard.string(forKey: "profilePath"), FileManager.default.fileExists(atPath: path) {
            profileURL = URL(fileURLWithPath: path)
        }
        selectedIdentityID = UserDefaults.standard.string(forKey: "identityID")
        if let path = UserDefaults.standard.string(forKey: "ipaPath"), FileManager.default.fileExists(atPath: path) {
            ipaURL = URL(fileURLWithPath: path)
        }
        if performInitialRefresh { Task { await refresh() } }
    }

    func refresh() async {
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            async let foundDevices = DeviceService.connectedDevices()
            async let foundIdentities = SigningService.identities()
            devices = try await foundDevices
            identities = try await foundIdentities

            if let selectedDevice, !devices.contains(selectedDevice) { selectedDeviceID = nil }
            if selectedDeviceID == nil {
                let savedUDID = UserDefaults.standard.string(forKey: "deviceUDID")
                if let saved = devices.first(where: { $0.udid == savedUDID }) {
                    deviceKind = saved.kind
                    selectedDeviceID = saved.id
                } else if let first = filteredDevices.first(where: \.isConnected) {
                    selectedDeviceID = first.id
                } else if let first = devices.first(where: \.isConnected) {
                    deviceKind = first.kind
                    selectedDeviceID = first.id
                } else if let first = filteredDevices.first ?? devices.first {
                    deviceKind = first.kind
                    selectedDeviceID = first.id
                }
            }
            if !identities.contains(where: { $0.id == selectedIdentityID }) { selectedIdentityID = identities.first?.id }
            if profileURL == nil || !FileManager.default.fileExists(atPath: profileURL?.path ?? "") {
                profileURL = await SigningService.bestInstalledProfileURL(for: selectedDevice)
                if let profileURL { UserDefaults.standard.set(profileURL.path, forKey: "profilePath") }
            }
            detail = devices.isEmpty ? "未发现设备，请通过 USB 连接并在设备上点“信任”" : "已刷新设备和签名证书"
        } catch {
            stage = .failed(error.localizedDescription)
            detail = error.localizedDescription
        }
    }

    func changeKind(_ kind: DeviceKind) {
        deviceKind = kind
        if selectedDevice?.kind != kind {
            selectedDeviceID = filteredDevices.first(where: \.isConnected)?.id ?? filteredDevices.first?.id
        }
    }

    func pair(_ device: AppleDevice) {
        guard pairingDeviceID == nil else { return }
        pairingDeviceID = device.id
        selectedDeviceID = device.id
        stage = .idle
        detail = "正在发起配对，请保持 \(device.name) 解锁并留意设备上的确认提示…"
        Task {
            defer { pairingDeviceID = nil }
            do {
                try await DeviceService.pair(device)
                detail = "配对成功，正在刷新设备状态…"
                await refresh()
                if let refreshed = devices.first(where: { $0.udid == device.udid }),
                   !refreshed.developerModeEnabled {
                    detail = "配对成功；请在设备的“设置 → 隐私与安全性 → 开发者模式”中开启开发者模式"
                }
            } catch {
                stage = .failed(error.localizedDescription)
                detail = error.localizedDescription
            }
        }
    }

    func chooseIPA() {
        let panel = NSOpenPanel()
        panel.title = "选择 IPA 安装包"
        panel.allowedContentTypes = [.init(filenameExtension: "ipa")!]
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { acceptIPA(url) }
    }

    func acceptIPA(_ url: URL) {
        guard url.pathExtension.lowercased() == "ipa" else {
            stage = .failed("只支持 `.ipa` 安装包；你提到的 `.ipk` 不是 iOS 应用格式。")
            detail = "请重新选择 IPA 文件"
            return
        }
        ipaURL = url
        UserDefaults.standard.set(url.path, forKey: "ipaPath")
        stage = .idle
        detail = "已选择 \(url.lastPathComponent)"
    }

    func chooseProfile() {
        let panel = NSOpenPanel()
        panel.title = "选择描述文件"
        panel.allowedContentTypes = [.init(filenameExtension: "mobileprovision")!]
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            profileURL = url
            UserDefaults.standard.set(url.path, forKey: "profilePath")
            detail = "已选择描述文件 \(url.lastPathComponent)"
        }
    }

    func rememberIdentity(_ id: String?) {
        selectedIdentityID = id
        UserDefaults.standard.set(id, forKey: "identityID")
    }

    func install() {
        guard let ipaURL, let profileURL, let selectedDevice else {
            stage = .failed("请先完成设备、IPA 和描述文件选择。")
            return
        }
        Task {
            do {
                let activeProfile = try await SigningService.ensureUsableProfile(
                    at: profileURL,
                    for: selectedDevice,
                    forceRefresh: identities.isEmpty
                ) { [weak self] message in
                    self?.stage = .preparing
                    self?.detail = message
                }
                self.profileURL = activeProfile
                UserDefaults.standard.set(activeProfile.path, forKey: "profilePath")
                UserDefaults.standard.set(selectedDevice.udid, forKey: "deviceUDID")
                identities = try await SigningService.identities()
                guard let identity = identities.first(where: { $0.id == selectedIdentityID }) ?? identities.first else {
                    throw AutoSignError.missingSelection("Xcode 未能创建 Apple Development 签名证书。")
                }
                rememberIdentity(identity.id)
                let output = try await SigningService.signAndInstall(
                    ipa: ipaURL, profileURL: activeProfile, identity: identity, device: selectedDevice
                ) { [weak self] stage, message in
                    self?.stage = stage
                    self?.detail = message
                }
                stage = .finished(output)
                detail = "已安装到 \(selectedDevice.name)，并保存 \(output.lastPathComponent)"
            } catch {
                stage = .failed(error.localizedDescription)
                detail = error.localizedDescription
            }
        }
    }

    func setAutoRefreshEnabled(_ enabled: Bool) {
        autoRefreshEnabled = enabled
        Task {
            do {
                if enabled {
                    await BackgroundRefreshManager.authorizeNotifications()
                    try await BackgroundRefreshManager.install()
                    lastBackgroundStatus = "后台自动续签已开启"
                } else {
                    try await BackgroundRefreshManager.uninstall()
                    lastBackgroundStatus = "后台自动续签已关闭"
                }
                autoRefreshEnabled = BackgroundRefreshManager.isInstalled
            } catch {
                autoRefreshEnabled = BackgroundRefreshManager.isInstalled
                lastBackgroundStatus = error.localizedDescription
                stage = .failed(error.localizedDescription)
            }
        }
    }

    func revealOutput() {
        guard case .finished(let url) = stage else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}
