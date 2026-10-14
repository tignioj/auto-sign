import AppKit
import Foundation
import Network
import Security
import SystemConfiguration

@MainActor
final class StoreServer: ObservableObject {
    static let shared = StoreServer(sourceLibrary: .shared)
    static let port: UInt16 = 8091
    @Published private(set) var isEnabled = false
    @Published private(set) var status = "局域网服务已关闭"
    @Published private(set) var isBusy = false
    @Published private(set) var token = ""
    private var listener: NWListener?
    private var connections: [UUID: StoreHTTPConnection] = [:]
    private var jobs: [RefreshJob] = []
    private var worker: Task<Void, Never>?
    private var devices: [AppleDevice] = []
    private var lastDeviceCheck = Date.distantPast
    private let devicesProvider: @Sendable () async throws -> [AppleDevice]
    private let sourceLibrary: SourceLibraryModel
    private let installExecutor: (@MainActor @Sendable (StoreInstallRequest, SourceAppVersion, @escaping @MainActor @Sendable (String) -> Void) async throws -> Date)?
    private let preferences: UserDefaults
    private let jobsDirectory: URL?

    init(preferences: UserDefaults = .standard, jobsDirectory: URL? = nil, sourceLibrary: SourceLibraryModel? = nil,
         devicesProvider: @escaping @Sendable () async throws -> [AppleDevice] = { try await DeviceService.connectedDevices() },
         installExecutor: (@MainActor @Sendable (StoreInstallRequest, SourceAppVersion, @escaping @MainActor @Sendable (String) -> Void) async throws -> Date)? = nil) {
        self.sourceLibrary = sourceLibrary ?? SourceLibraryModel(preferences: preferences)
        self.installExecutor = installExecutor
        self.devicesProvider = devicesProvider
        self.preferences = preferences
        self.jobsDirectory = jobsDirectory
        isEnabled = preferences.bool(forKey: "storeServerEnabled")
        token = preferences.string(forKey: "storeServerToken") ?? ""
        do {
            if token.isEmpty { try replaceToken() }
            let file = try jobFile()
            if FileManager.default.fileExists(atPath: file.path) {
                jobs = StoreJobPlanner.recoverInterrupted(try StoreJSON.decoder().decode([RefreshJob].self, from: Data(contentsOf: file)))
                try persistJobs()
            }
        } catch { status = "读取服务配置失败：\(error.localizedDescription)"; isEnabled = false }
    }

    var address: String {
        let hostname = SCDynamicStoreCopyLocalHostName(nil) as String? ?? "Mac"
        return "http://\(hostname).local:\(Self.port)"
    }

    func startIfEnabled() { if isEnabled { start() } }

    func setEnabled(_ enabled: Bool) {
        guard !isBusy else { return }
        isEnabled = enabled
        preferences.set(enabled, forKey: "storeServerEnabled")
        if enabled { start() }
        else {
            listener?.cancel(); listener = nil
            for connection in Array(connections.values) { connection.close() }
            status = "局域网服务已关闭"
        }
    }

    func rotateToken() {
        do { try replaceToken() } catch { status = error.localizedDescription }
    }

    private func replaceToken() throws {
        var bytes = [UInt8](repeating: 0, count: 24)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw AutoSignError.command("无法生成配对密钥。")
        }
        token = bytes.map { String(format: "%02x", $0) }.joined()
        preferences.set(token, forKey: "storeServerToken")
    }

    private func start() {
        guard listener == nil, !token.isEmpty else { return }
        do {
            let parameters = NWParameters.tcp
            parameters.includePeerToPeer = false
            let listener = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: Self.port)!)
            listener.service = NWListener.Service(name: "AutoSign · \(Host.current().localizedName ?? "Mac")", type: "_autosign._tcp")
            listener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    switch state {
                    case .ready: self.status = "局域网服务运行中 · 端口 \(Self.port)"
                    case .failed(let error):
                        self.status = "局域网服务启动失败：\(error.localizedDescription)"
                        self.listener?.cancel(); self.listener = nil
                    default: break
                    }
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor [weak self] in self?.accept(connection) }
            }
            self.listener = listener
            status = "正在启动局域网服务…"
            listener.start(queue: .main)
        } catch { status = "局域网服务启动失败：\(error.localizedDescription)" }
    }

    private func accept(_ connection: NWConnection) {
        guard connections.count < 16 else { connection.cancel(); return }
        let id = UUID()
        let client = StoreHTTPConnection(connection: connection, handler: { [weak self] request in
            guard let self else { return .error(503, "服务已停止。") }
            return await self.handle(request)
        }, onClose: { [weak self] in self?.connections.removeValue(forKey: id) })
        connections[id] = client
        client.start()
    }

    func handle(_ request: StoreHTTPRequest) async -> StoreHTTPResponse {
        guard request.headers["authorization"] == "Bearer \(token)", !token.isEmpty else { return .error(401, "配对密钥无效。") }
        do {
            if request.method == "GET", request.path == "/v1/status" {
                if Date().timeIntervalSince(lastDeviceCheck) > 10 {
                    devices = try await devicesProvider()
                    lastDeviceCheck = Date()
                }
                let snapshot = StoreSnapshot(protocolVersion: 1, serverName: Host.current().localizedName ?? "AutoSign Mac",
                    devices: devices.filter(\.isPaired).map {
                        StoreDevice(id: $0.udid, name: $0.name, model: $0.marketingName, isConnected: $0.isConnected, isReady: $0.isReadyForInstallation)
                    }, apps: try StoreLibrary.records().map(\.app), recentJobs: jobs, capabilities: ["sources", "install"])
                return try .json(snapshot)
            }
            if request.method == "GET", request.path == "/v1/sources" {
                return try .json(sourceLibrary.sources)
            }
            if request.method == "POST", ["/v1/sources", "/v1/sources/refresh", "/v1/sources/remove", "/v1/install"].contains(request.path) {
                guard request.headers["content-type"]?.lowercased().hasPrefix("application/json") == true else {
                    return .error(415, "请使用 JSON 请求。")
                }
                if request.path == "/v1/install" {
                    let input = try StoreJSON.decoder().decode(StoreInstallRequest.self, from: request.body)
                    return try .json(await submitInstall(input), status: 202)
                }
                guard !isBusy, !sourceLibrary.isBusy else { return .error(409, "Mac 正在处理应用任务，请稍后重试。") }
                let input = try StoreJSON.decoder().decode(StoreSourceRequest.self, from: request.body)
                if request.path == "/v1/sources/remove" { try sourceLibrary.removeSource(input.url) }
                else { _ = try await sourceLibrary.fetchAndSaveSource(input.url) }
                return try .json(sourceLibrary.sources)
            }
            if request.method == "POST", request.path == "/v1/refresh" {
                guard request.headers["content-type"]?.lowercased().hasPrefix("application/json") == true else {
                    return .error(415, "请使用 JSON 请求。")
                }
                let input = try StoreJSON.decoder().decode(RefreshRequest.self, from: request.body)
                return try .json(submit(input), status: 202)
            }
            if request.method == "GET", request.path.hasPrefix("/v1/jobs/") {
                let id = String(request.path.dropFirst("/v1/jobs/".count))
                guard let job = jobs.first(where: { $0.id == id }) else { return .error(404, "任务不存在或已被清理。") }
                return try .json(job)
            }
            return .error(404, "接口不存在。")
        } catch let error as StoreHTTPError { return .error(error.status, error.message) }
        catch let error as AppSourceError { return .error(400, error.localizedDescription) }
        catch is DecodingError { return .error(400, "请求内容不完整。") }
        catch { return .error(500, error.localizedDescription) }
    }

    func submit(_ input: RefreshRequest) throws -> RefreshJob {
        let plan = try StoreJobPlanner.plan(input, records: StoreLibrary.records(), jobs: jobs, isBusy: isBusy)
        if plan.isExisting { return plan.job }
        let job = plan.job
        let previous = jobs
        jobs.insert(job, at: 0)
        jobs = Array(jobs.prefix(30))
        do { try persistJobs() } catch { jobs = previous; throw error }
        isBusy = true
        worker = Task { [self] in
            // Deliver and persist the job ID on the phone before installing the client itself.
            try? await Task.sleep(for: .seconds(2))
            await execute(jobID: job.id, records: plan.records)
            isBusy = false
            worker = nil
        }
        return job
    }

    func submitInstall(_ input: StoreInstallRequest) async throws -> RefreshJob {
        if let existing = try StoreJobPlanner.existingInstall(input, jobs: jobs) { return existing }
        guard !sourceLibrary.isBusy else { throw StoreHTTPError(status: 409, message: "Mac 正在更新源或下载，请稍后重试。") }
        let available = try await devicesProvider()
        let job = try StoreJobPlanner.planInstall(input, sources: sourceLibrary.sources, devices: available, jobs: jobs, isBusy: isBusy)
        // Device discovery yields; a concurrent request may have persisted this request in the meantime.
        if jobs.contains(where: { $0.id == job.id }) { return job }
        let previous = jobs
        jobs.insert(job, at: 0)
        jobs = Array(jobs.prefix(30))
        do { try persistJobs() } catch { jobs = previous; throw error }
        isBusy = true
        worker = Task { [self] in
            try? await Task.sleep(for: .seconds(2))
            await executeInstall(jobID: job.id, input: input)
            isBusy = false
            worker = nil
        }
        return job
    }

    private func executeInstall(jobID: String, input: StoreInstallRequest) async {
        do {
            try update(jobID, index: 0, state: .running, message: "正在检查源中的最新版本…")
            let source = try await sourceLibrary.fetchAndSaveSource(input.sourceURL)
            guard let version = source.catalog.apps.first(where: { $0.id == input.bundleIdentifier })?.latestVersion else {
                throw AppSourceError.invalid("源中已没有这个应用的可下载版本，请刷新列表。")
            }
            let progress: @MainActor @Sendable (String) -> Void = { [weak self] message in
                self?.updateProgress(jobID, index: 0, message: message)
            }
            let expiration: Date
            if let installExecutor { expiration = try await installExecutor(input, version, progress) }
            else { expiration = try await StoreInstallService.install(input, version: version, preferences: preferences, statusChanged: progress) }
            try update(jobID, index: 0, state: .completed, message: "已安装 \(version.displayVersion)，可在“我的应用”续签", expiration: expiration)
        } catch {
            do { try update(jobID, index: 0, state: .failed, message: error.localizedDescription) }
            catch { abortJob(jobID, message: "任务记录写入失败：\(error.localizedDescription)") }
        }
        lastDeviceCheck = .distantPast
    }

    private func execute(jobID: String, records: [StoreRecord]) async {
        for (index, record) in records.enumerated() {
            do {
                try update(jobID, index: index, state: .running, message: "正在连接设备…")
                let available = try await devicesProvider()
                guard let device = available.first(where: { $0.udid == record.app.deviceUDID && $0.isReadyForInstallation }) else {
                    throw AutoSignError.command("设备不可用。请解锁设备，检查 Wi-Fi、USB 配对及开发者模式。")
                }
                let profileURL = try await SigningService.ensureUsableProfile(
                    at: URL(fileURLWithPath: record.profilePath), for: device, forceRefresh: true,
                    bundleIdentifier: record.app.bundleIdentifier
                ) { [weak self] message in self?.updateProgress(jobID, index: index, message: message) }
                let identities = try await SigningService.identities()
                let profile = try await SigningService.readProfile(at: profileURL)
                guard SigningService.profileSupports(profile.applicationIdentifier, bundleID: record.app.bundleIdentifier) else {
                    throw AutoSignError.command("续期后的描述文件与原应用标识不匹配，已停止安装以保护原应用数据。")
                }
                guard record.teamIdentifier == nil || record.teamIdentifier == profile.teamIdentifier else {
                    throw AutoSignError.command("续期后的签名团队与原应用不一致，已停止覆盖安装。")
                }
                guard let identity = SigningService.identity(for: profile, available: identities, preferredID: record.identityID) else {
                    throw AutoSignError.command("找不到此应用所属团队的签名证书，请在 Mac 检查 Xcode 账号。")
                }
                let output = try StoreLibrary.directory().appendingPathComponent("Packages/\(record.app.id)/signed.ipa")
                _ = try await SigningService.signAndInstall(ipa: URL(fileURLWithPath: record.ipaPath),
                    profileURL: profileURL, identity: identity, device: device, outputIPA: output
                ) { [weak self] _, message in self?.updateProgress(jobID, index: index, message: message) }
                try update(jobID, index: index, state: .completed,
                    message: profile.timeToLiveDays == 7 ? "已重新签发 7 天签名并覆盖安装" : "已重新签发签名并覆盖安装",
                    expiration: profile.expirationDate)
            } catch {
                do { try update(jobID, index: index, state: .failed, message: error.localizedDescription) }
                catch {
                    abortJob(jobID, message: "任务记录写入失败：\(error.localizedDescription)")
                    return
                }
            }
        }
        lastDeviceCheck = .distantPast
    }

    private func updateProgress(_ jobID: String, index: Int, message: String) {
        do { try update(jobID, index: index, state: .running, message: message) }
        catch { status = "进度写入失败：\(error.localizedDescription)" }
    }

    private func abortJob(_ id: String, message: String) {
        status = message
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        jobs[index].state = .failed
        jobs[index].updatedAt = Date()
        for item in jobs[index].items.indices where !jobs[index].items[item].state.isTerminal {
            jobs[index].items[item].state = .failed
            jobs[index].items[item].message = message
        }
        try? persistJobs()
    }

    private func update(_ id: String, index: Int, state: RefreshState, message: String, expiration: Date? = nil) throws {
        guard let job = jobs.firstIndex(where: { $0.id == id }) else { throw AutoSignError.command("任务记录丢失。") }
        jobs[job].items[index].state = state
        jobs[job].items[index].message = message
        jobs[job].items[index].expiration = expiration
        let complete = jobs[job].items.allSatisfy { $0.state.isTerminal }
        jobs[job].state = complete ? (jobs[job].items.contains { $0.state == .failed } ? .failed : .completed) : .running
        jobs[job].updatedAt = Date()
        try persistJobs()
    }

    private func persistJobs() throws {
        try StoreJSON.encoder().encode(jobs).write(to: jobFile(), options: .atomic)
    }

    private func jobFile() throws -> URL {
        try (jobsDirectory ?? StoreLibrary.directory()).appendingPathComponent("jobs.json")
    }
}
