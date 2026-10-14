import AppKit
import Foundation

@MainActor
final class AppModel: ObservableObject {
    @Published var deviceKind: DeviceKind = .iPhone
    @Published var devices: [AppleDevice] = []
    @Published private(set) var selectedDeviceIDs: Set<String> = []
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
    @Published private(set) var completedOutputURLs: [URL] = []

    @Published var accountStatus = AccountStatus()
    @Published var renewalStatuses: [RefreshStatus] = []
    @Published var appRenewalStatuses: [String: [AppRenewalStatus]] = [:]
    @Published var renewalLibraryError: String?
    @Published var nextBackgroundCheck: Date?
    @Published var schedulerStatus = "正在检查后台任务…"

    func refreshDashboard() async {
        accountStatus = await AccountStatus.inspect()
        autoRefreshEnabled = BackgroundRefreshManager.isInstalled
        lastBackgroundStatus = BackgroundRefreshManager.lastStatus
        let preferences = UserDefaults.standard
        nextBackgroundCheck = (preferences.object(forKey: "backgroundCheckStarted") as? Date)?.addingTimeInterval(RefreshStatusStore.interval)
        let targets = DeviceSelectionStore.load(from: preferences)
        do {
            let records = try StoreLibrary.records().filter { targets.contains($0.app.deviceUDID) }
            appRenewalStatuses = Dictionary(grouping: records, by: { $0.app.deviceUDID }).mapValues { records in
                records.sorted { $0.app.expiration < $1.app.expiration }.map {
                    AppRenewalStatus(app: $0.app, status: RefreshStatusStore.loadApp($0.app, preferences: preferences))
                }
            }
            renewalLibraryError = nil
        } catch {
            appRenewalStatuses = [:]
            renewalLibraryError = error.localizedDescription
        }
        renewalStatuses = targets.map { udid in
            var status = RefreshStatusStore.load(udid) ?? RefreshStatus(id: udid, name: udid)
            if let device = devices.first(where: { $0.udid == udid }) { status.name = device.name }
            let apps = appRenewalStatuses[udid] ?? []
            status.expiration = apps.map(\.app.expiration).min()
            status.nextEligible = status.expiration?.addingTimeInterval(-BackgroundRefreshCoordinator.renewalWindow)
            return status
        }
        if autoRefreshEnabled {
            let result = try? await ProcessRunner.run("/bin/launchctl", ["print", "gui/\(getuid())/\(BackgroundRefreshManager.label)"])
            schedulerStatus = result?.status == 0 ? "后台任务已加载 · 每 30 分钟检查" : "后台任务未加载，请关闭再开启自动续签"
        } else { schedulerStatus = "后台自动续签已关闭" }
    }

    private var didInitializeDeviceSelection = false

    var filteredDevices: [AppleDevice] { devices.filter { $0.kind == deviceKind } }
    var selectedDevices: [AppleDevice] { devices.filter { selectedDeviceIDs.contains($0.id) } }
    var selectedIdentity: SigningIdentity? { identities.first { $0.id == selectedIdentityID } }
    var canInstall: Bool {
        ipaURL != nil
            && profileURL != nil
            && !selectedDevices.isEmpty
            && selectedDevices.allSatisfy(\.isReadyForInstallation)
            && !stage.isRunning
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
        guard !isRefreshing else { return }
        await refreshDashboard()
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            let previouslySelectedUDIDs = Set(selectedDevices.map(\.udid))
            async let foundDevices = DeviceService.connectedDevices()
            async let foundIdentities = SigningService.identities()
            devices = try await foundDevices
            identities = try await foundIdentities

            let persistedUDIDs = Set(DeviceSelectionStore.load(from: .standard))
            let desiredUDIDs = previouslySelectedUDIDs.isEmpty ? persistedUDIDs : previouslySelectedUDIDs
            selectedDeviceIDs = Set(devices.filter { desiredUDIDs.contains($0.udid) }.map(\.id))
            if selectedDeviceIDs.isEmpty && !didInitializeDeviceSelection && desiredUDIDs.isEmpty {
                let readyDevices = devices.filter(\.isReadyForInstallation)
                let initialDevices = readyDevices.isEmpty ? Array(devices.prefix(1)) : readyDevices
                selectedDeviceIDs = Set(initialDevices.map(\.id))
            }
            didInitializeDeviceSelection = true
            if let firstSelected = selectedDevices.first {
                deviceKind = firstSelected.kind
            }
            if !identities.contains(where: { $0.id == selectedIdentityID }) { selectedIdentityID = identities.first?.id }
            if profileURL == nil || !FileManager.default.fileExists(atPath: profileURL?.path ?? "") {
                profileURL = await SigningService.bestInstalledProfileURL(for: selectedDevices.first)
                if let profileURL { UserDefaults.standard.set(profileURL.path, forKey: "profilePath") }
            }
            await refreshDashboard()
            detail = devices.isEmpty ? "未发现设备，请通过 USB 连接并在设备上点“信任”" : "已刷新设备和签名证书"
        } catch {
            stage = .failed(error.localizedDescription)
            detail = error.localizedDescription
        }
    }

    func changeKind(_ kind: DeviceKind) {
        deviceKind = kind
    }

    func toggleDeviceSelection(_ device: AppleDevice) {
        if selectedDeviceIDs.contains(device.id) {
            selectedDeviceIDs.remove(device.id)
        } else {
            selectedDeviceIDs.insert(device.id)
        }
        persistSelectedDevices()
        stage = .idle
        detail = selectionDetail
    }

    func toggleAllReadyFilteredDevices() {
        let readyIDs = Set(filteredDevices.filter(\.isReadyForInstallation).map(\.id))
        guard !readyIDs.isEmpty else { return }
        if readyIDs.isSubset(of: selectedDeviceIDs) {
            selectedDeviceIDs.subtract(readyIDs)
        } else {
            selectedDeviceIDs.formUnion(readyIDs)
        }
        persistSelectedDevices()
        stage = .idle
        detail = selectionDetail
    }

    var areAllReadyFilteredDevicesSelected: Bool {
        let readyIDs = Set(filteredDevices.filter(\.isReadyForInstallation).map(\.id))
        return !readyIDs.isEmpty && readyIDs.isSubset(of: selectedDeviceIDs)
    }

    var selectionDetail: String {
        guard !selectedDevices.isEmpty else { return "请选择至少一台目标设备" }
        let unavailable = selectedDevices.filter { !$0.isReadyForInstallation }.count
        if unavailable > 0 {
            return "已选择 \(selectedDevices.count) 台设备，其中 \(unavailable) 台暂不可安装"
        }
        return "已选择 \(selectedDevices.count) 台设备，可同时签名安装"
    }

    func pair(_ device: AppleDevice) {
        guard pairingDeviceID == nil else { return }
        pairingDeviceID = device.id
        selectedDeviceIDs.insert(device.id)
        persistSelectedDevices()
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
        guard let ipaURL, let profileURL, !selectedDevices.isEmpty else {
            stage = .failed("请先完成目标设备、IPA 和描述文件选择。")
            return
        }
        let targets = selectedDevices
        guard targets.allSatisfy(\.isReadyForInstallation) else {
            let names = targets.filter { !$0.isReadyForInstallation }.map(\.name).joined(separator: "、")
            stage = .failed("以下设备暂不可安装：\(names)")
            return
        }
        DeviceSelectionStore.save(targets.map(\.udid), to: .standard)
        Task {
            completedOutputURLs = []
            stage = .preparing
            detail = "正在为 \(targets.count) 台设备准备描述文件…"
            var activeProfile = profileURL
            var preparedDevices: [AppleDevice] = []
            var failures: [String] = []
            var failedUDIDs = Set<String>()
            var shouldForceRefresh = identities.isEmpty

            for (index, device) in targets.enumerated() {
                do {
                    RefreshStatusStore.record(device.udid, name: device.name, state: "正在准备手动签名")
                    activeProfile = try await SigningService.ensureUsableProfile(
                        at: activeProfile,
                        for: device,
                        forceRefresh: shouldForceRefresh
                    ) { [weak self] message in
                        self?.stage = .preparing
                        self?.detail = "[\(index + 1)/\(targets.count)] \(message)"
                    }
                    shouldForceRefresh = false
                    preparedDevices.append(device)
                } catch {
                    RefreshStatusStore.record(device.udid, name: device.name, state: "手动安装失败", failure: error.localizedDescription)
                    failures.append("\(device.name)：\(error.localizedDescription)")
                    failedUDIDs.insert(device.udid)
                }
            }

            self.profileURL = activeProfile
            UserDefaults.standard.set(activeProfile.path, forKey: "profilePath")

            do {
                identities = try await SigningService.identities()
                let activeProfileInfo = try await SigningService.readProfile(at: activeProfile)
                guard let identity = SigningService.identity(for: activeProfileInfo, available: identities, preferredID: selectedIdentityID) else {
                    throw AutoSignError.missingSelection("Xcode 未能创建 Apple Development 签名证书。")
                }
                rememberIdentity(identity.id)

                for (index, device) in preparedDevices.enumerated() {
                    do {
                        let output = try await SigningService.signAndInstall(
                            ipa: ipaURL, profileURL: activeProfile, identity: identity, device: device
                        ) { [weak self] stage, message in
                            self?.stage = stage
                            self?.detail = "[\(index + 1)/\(preparedDevices.count)] \(device.name)：\(message)"
                        }
                        let installedProfile = try await SigningService.readProfile(at: activeProfile)
                        RefreshStatusStore.record(device.udid, name: device.name, state: "手动签名安装成功", expiration: installedProfile.expirationDate, success: true)
                        completedOutputURLs.append(output)
                    } catch {
                        RefreshStatusStore.record(device.udid, name: device.name, state: "手动安装失败", failure: error.localizedDescription)
                        failures.append("\(device.name)：\(error.localizedDescription)")
                        failedUDIDs.insert(device.udid)
                    }
                }
            } catch {
                failures.append(error.localizedDescription)
                failedUDIDs.formUnion(preparedDevices.map(\.udid))
                for device in preparedDevices {
                    RefreshStatusStore.record(device.udid, name: device.name, state: "手动安装失败", failure: error.localizedDescription)
                }
            }

            DeviceSelectionStore.savePending(
                targets.map(\.udid).filter { failedUDIDs.contains($0) }, to: .standard
            )

            await refreshDashboard()
            if failures.isEmpty, let output = completedOutputURLs.last {
                stage = .finished(output)
                detail = "已完成：应用已安装到 \(targets.count) 台设备，并保存 \(completedOutputURLs.count) 个签名副本"
            } else {
                let completed = completedOutputURLs.count
                let summary = failures.joined(separator: "；")
                stage = .failed(summary)
                detail = completed > 0
                    ? "已完成 \(completed)/\(targets.count) 台；失败：\(summary)"
                    : "多设备安装失败：\(summary)"
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

    func revealOutputs() {
        guard !completedOutputURLs.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(completedOutputURLs)
    }

    private func persistSelectedDevices() {
        DeviceSelectionStore.save(selectedDevices.map(\.udid), to: .standard)
    }
}
