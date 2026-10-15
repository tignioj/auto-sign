import AppKit
import Foundation

@MainActor
final class AppModel: ObservableObject {
    @Published var deviceKind: DeviceKind = .iPhone
    @Published var devices: [AppleDevice] = []
    @Published private(set) var selectedDeviceID: String?
    @Published private(set) var selectedApps: [SourceAppSelection] = []
    @Published private(set) var managedApps: [String: StoreRecord] = [:]
    @Published private(set) var availableUpdates: [StoreAppUpdate] = []
    @Published private(set) var operationItems: [RefreshItem] = []
    @Published var profileURL: URL?
    @Published var identities: [SigningIdentity] = []
    @Published var selectedIdentityID: String?
    @Published var stage: InstallStage = .idle
    @Published var detail = "选择一台设备，再选择源中的应用"
    @Published var isRefreshing = false
    @Published var pairingDeviceID: String?
    @Published private(set) var profileOnlyRefresh = false
    @Published var autoRefreshEnabled = BackgroundRefreshManager.isInstalled
    @Published private(set) var isChangingAutoRefresh = false
    @Published var lastBackgroundStatus = BackgroundRefreshManager.lastStatus
    let sourceLibrary: SourceLibraryModel
    private let preferences: UserDefaults
    private let dependencies: DeviceAppBatch.Dependencies
    static let selectedDevicePreferenceKey = "installationDeviceUDID"

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
        nextBackgroundCheck = (preferences.object(forKey: "backgroundCheckStarted") as? Date)?.addingTimeInterval(RefreshStatusStore.interval)
        let targets = DeviceSelectionStore.load(from: preferences)
        do {
            let records = try dependencies.records().filter { targets.contains($0.app.deviceUDID) }
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
            var status = RefreshStatusStore.load(udid, preferences: preferences) ?? RefreshStatus(id: udid, name: udid)
            if let device = devices.first(where: { $0.udid == udid }) { status.name = device.name }
            let apps = appRenewalStatuses[udid] ?? []
            status.expiration = apps.map(\.app.expiration).min()
            status.nextEligible = status.expiration?.addingTimeInterval(-BackgroundRefreshCoordinator.renewalWindow)
            return status
        }
        if let device = selectedDevice {
            do {
                let apps = try await DeviceAppBatch.managedApps(on: device, dependencies: dependencies)
                if selectedDevice?.udid == device.udid { managedApps = apps }
            } catch {
                if selectedDevice?.udid == device.udid {
                    managedApps = [:]
                    renewalLibraryError = error.localizedDescription
                }
            }
        } else { managedApps = [:] }
        await refreshAvailableUpdates()
        if autoRefreshEnabled {
            let result = try? await ProcessRunner.run("/bin/launchctl", ["print", "gui/\(getuid())/\(BackgroundRefreshManager.label)"])
            schedulerStatus = result?.status == 0 ? "后台任务已加载 · 每 30 分钟检查" : "后台任务未加载，请关闭再开启自动续签"
        } else { schedulerStatus = "后台自动续签已关闭" }
    }

    private var didInitializeDeviceSelection = false
    private var updateCheckGeneration = UUID()

    func refreshAvailableUpdates() async {
        let generation = UUID()
        updateCheckGeneration = generation
        guard let device = selectedDevice else { availableUpdates = []; return }
        do {
            let records = try dependencies.records().filter { $0.app.deviceUDID == device.udid }
            let updates = await StoreUpdateDetector.updates(records: records, sources: sourceLibrary.sources)
            guard updateCheckGeneration == generation, selectedDevice?.udid == device.udid else { return }
            availableUpdates = updates
        } catch {
            if updateCheckGeneration == generation { availableUpdates = [] }
        }
    }

    var filteredDevices: [AppleDevice] { devices.filter { $0.kind == deviceKind } }
    var selectedDevice: AppleDevice? { devices.first { $0.id == selectedDeviceID } }
    var isBusy: Bool { stage.isRunning || pairingDeviceID != nil || isRefreshing }
    var completedAppCount: Int { operationItems.filter { $0.state == .completed }.count }
    var canInstall: Bool {
        selectedDevice?.isReadyForInstallation == true && !selectedApps.isEmpty
            && selectedApps.allSatisfy { selection in
                sourceLibrary.sources.contains { source in
                    source.id == selection.sourceURL
                        && source.catalog.apps.contains { $0.id == selection.id && $0.latestVersion != nil }
                }
            }
            && (profileURL != nil || !managedApps.isEmpty)
            && !isBusy && !sourceLibrary.isBusy
    }
    var canRefreshApps: Bool {
        selectedDevice?.isReadyForInstallation == true && !selectedApps.isEmpty
            && selectedApps.allSatisfy { managedApps[$0.id] != nil }
            && !isBusy && !sourceLibrary.isBusy
    }

    init(performInitialRefresh: Bool = true, preferences: UserDefaults = .standard,
         sourceLibrary: SourceLibraryModel? = nil, dependencies: DeviceAppBatch.Dependencies = .init()) {
        self.preferences = preferences
        self.sourceLibrary = sourceLibrary ?? .shared
        self.dependencies = dependencies
        if let path = preferences.string(forKey: "profilePath"), FileManager.default.fileExists(atPath: path) {
            profileURL = URL(fileURLWithPath: path)
        }
        selectedIdentityID = preferences.string(forKey: "identityID")
        if performInitialRefresh { Task { await refresh() } }
    }

    func updateDevices(_ available: [AppleDevice]) {
        guard !stage.isRunning else { return }
        let previousUDID = selectedDevice?.udid
        let desiredUDID = previousUDID ?? preferences.string(forKey: Self.selectedDevicePreferenceKey)
            ?? (didInitializeDeviceSelection ? nil : DeviceSelectionStore.load(from: preferences).first)
        devices = available
        var target = available.first { $0.udid == desiredUDID }
        if target == nil && !didInitializeDeviceSelection && desiredUDID == nil {
            target = available.first(where: \.isReadyForInstallation) ?? available.first
        }
        didInitializeDeviceSelection = true
        selectedDeviceID = target?.id
        profileOnlyRefresh = target.map { ProfileRefreshPolicy.profileOnly(on: $0.udid, preferences: preferences) } ?? false
        if previousUDID != target?.udid {
            selectedApps = []
            operationItems = []
            managedApps = [:]
            availableUpdates = []
        }
        if let target {
            deviceKind = target.kind
            preferences.set(target.udid, forKey: Self.selectedDevicePreferenceKey)
        }
    }

    func refresh() async {
        guard !isRefreshing, !stage.isRunning else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            async let foundDevices = DeviceService.connectedDevices()
            async let foundIdentities = SigningService.identities()
            let available = try await foundDevices
            identities = try await foundIdentities
            updateDevices(available)
            if !identities.contains(where: { $0.id == selectedIdentityID }) { selectedIdentityID = identities.first?.id }
            if profileURL == nil || !FileManager.default.fileExists(atPath: profileURL?.path ?? "") {
                profileURL = await SigningService.bestInstalledProfileURL(for: selectedDevice)
                if let profileURL { preferences.set(profileURL.path, forKey: "profilePath") }
            }
            await refreshDashboard()
            detail = devices.isEmpty ? "未发现设备，请通过 USB 连接并在设备上点“信任”" : "已刷新设备和签名证书"
        } catch {
            stage = .failed(error.localizedDescription)
            detail = error.localizedDescription
        }
    }

    func changeKind(_ kind: DeviceKind) {
        guard !isBusy else { return }
        deviceKind = kind
        if selectedDevice?.kind != kind {
            selectedDeviceID = nil
            profileOnlyRefresh = false
            preferences.removeObject(forKey: Self.selectedDevicePreferenceKey)
            managedApps = [:]
            availableUpdates = []
            clearAppSelection()
            detail = "请选择一台 \(kind.title)"
        }
    }

    func selectDevice(_ device: AppleDevice) {
        guard !isBusy, devices.contains(where: { $0.id == device.id }) else { return }
        if selectedDevice?.udid != device.udid {
            clearAppSelection()
            managedApps = [:]
            availableUpdates = []
        }
        selectedDeviceID = device.id
        profileOnlyRefresh = ProfileRefreshPolicy.profileOnly(on: device.udid, preferences: preferences)
        deviceKind = device.kind
        preferences.set(device.udid, forKey: Self.selectedDevicePreferenceKey)
        stage = .idle
        detail = device.isReadyForInstallation
            ? "已选择 \(device.name)，请选择要安装或续签的应用"
            : "已选择 \(device.name)：\(device.statusText)"
        Task { await refreshDashboard() }
    }

    func isAppSelected(_ app: SourceApp, in source: SavedAppSource) -> Bool {
        selectedApps.contains { $0.id == app.id && $0.sourceURL == source.id }
    }

    func setProfileOnlyRefresh(_ enabled: Bool) {
        guard !isBusy, let device = selectedDevice else { return }
        ProfileRefreshPolicy.setProfileOnly(enabled, on: device.udid, preferences: preferences)
        profileOnlyRefresh = enabled
    }

    func toggleApp(_ app: SourceApp, in source: SavedAppSource) {
        guard !isBusy, !sourceLibrary.isBusy, selectedDevice != nil else { return }
        if isAppSelected(app, in: source) { selectedApps.removeAll { $0.id == app.id } }
        else {
            // The same application from two sources must never be installed twice in one batch.
            selectedApps.removeAll { $0.id == app.id }
            selectedApps.append(SourceAppSelection(sourceURL: source.id, app: app))
        }
        operationItems = []
        stage = .idle
        detail = "已为 \(selectedDevice?.name ?? "当前设备") 选择 \(selectedApps.count) 个应用"
    }

    func removeSelectedApp(_ id: String) {
        guard !isBusy else { return }
        selectedApps.removeAll { $0.id == id }
        operationItems = []
        stage = .idle
    }

    func reconcileSelectedApps() {
        guard !isBusy else { return }
        selectedApps.removeAll { selection in
            !sourceLibrary.sources.contains { source in
                source.id == selection.sourceURL && source.catalog.apps.contains { $0.id == selection.id }
            }
        }
    }

    func clearAppSelection() {
        guard !isBusy else { return }
        selectedApps = []
        operationItems = []
        stage = .idle
    }

    func pair(_ device: AppleDevice) {
        guard !isBusy else { return }
        selectDevice(device)
        pairingDeviceID = device.id
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

    func chooseProfile() {
        guard !isBusy else { return }
        let panel = NSOpenPanel()
        panel.title = "选择描述文件"
        panel.allowedContentTypes = [.init(filenameExtension: "mobileprovision")!]
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            profileURL = url
            preferences.set(url.path, forKey: "profilePath")
            detail = "已选择描述文件 \(url.lastPathComponent)"
        }
    }

    func rememberIdentity(_ id: String?) {
        guard !isBusy else { return }
        selectedIdentityID = id
        preferences.set(id, forKey: "identityID")
    }

    @discardableResult
    func perform(_ operation: DeviceAppOperation) -> Task<Void, Never>? {
        guard operation == .install ? canInstall : canRefreshApps,
              let device = selectedDevice, sourceLibrary.beginDeviceOperation() else { return nil }
        let selections = selectedApps
        operationItems = selections.map {
            RefreshItem(id: $0.id, name: $0.app.name, state: .queued, message: "等待\(operation.title)")
        }
        // Reserve the interface synchronously so a second click cannot start another batch.
        stage = .preparing
        detail = "正在为 \(device.name) \(operation.title) \(selections.count) 个应用…"
        return Task { [self] in
            defer {
                sourceLibrary.endDeviceOperation()
                reconcileSelectedApps()
            }
            let results = await DeviceAppBatch.run(selections, operation: operation, on: device,
                library: sourceLibrary, preferences: preferences, dependencies: dependencies) { [weak self] item in
                guard let self, let index = self.operationItems.firstIndex(where: { $0.id == item.id }) else { return }
                self.operationItems[index] = item
                self.detail = "\(device.name) · \(item.name)：\(item.message)"
            }
            let completed = results.filter { $0.state == .completed }.count
            let failures = results.filter { $0.state == .failed }
            if completed > 0 {
                // Changing the current device must not remove earlier installations from automatic renewal.
                var targets = DeviceSelectionStore.load(from: preferences)
                if !targets.contains(device.udid) { targets.append(device.udid) }
                DeviceSelectionStore.save(targets, to: preferences)
                let pending = DeviceSelectionStore.loadPending(from: preferences).filter { $0 != device.udid }
                DeviceSelectionStore.savePending(pending, to: preferences)
            }
            RefreshStatusStore.record(device.udid, name: device.name,
                state: "手动\(operation.title)：成功 \(completed)，失败 \(failures.count)",
                failure: failures.isEmpty ? nil : failures.map { "\($0.name)：\($0.message)" }.joined(separator: "；"),
                success: completed > 0, preferences: preferences)
            await refreshDashboard()
            stage = failures.isEmpty ? .finished : .failed(failures.map(\.message).joined(separator: "；"))
            detail = "\(device.name)：\(operation.title)完成 \(completed)/\(selections.count) 个应用"
                + (failures.isEmpty ? "" : "，\(failures.count) 个失败，详见处理结果")
        }
    }

    func setAutoRefreshEnabled(_ enabled: Bool) {
        guard !isBusy, !isChangingAutoRefresh else { return }
        isChangingAutoRefresh = true
        Task {
            defer { isChangingAutoRefresh = false }
            do {
                if enabled {
                    guard await LocalNetworkAccess.shared.check() else {
                        throw AutoSignError.command("请先在前台完成本地网络授权与检查，再开启自动续签。")
                    }
                    await BackgroundRefreshManager.authorizeNotifications()
                    try await BackgroundRefreshManager.install()
                    lastBackgroundStatus = "后台自动续签已开启"
                } else {
                    try await BackgroundRefreshManager.uninstall()
                    lastBackgroundStatus = "后台自动续签已关闭"
                }
                autoRefreshEnabled = BackgroundRefreshManager.isInstalled
                await refreshDashboard()
            } catch {
                autoRefreshEnabled = BackgroundRefreshManager.isInstalled
                lastBackgroundStatus = error.localizedDescription
                stage = .failed(error.localizedDescription)
            }
        }
    }

}
