import Foundation
@preconcurrency import AltSign

@MainActor
final class IndependentAccountModel: ObservableObject {
    static let shared = IndependentAccountModel()
    nonisolated static let enabledKey = "independentAppleAccountEnabled"
    static let summaryKey = "independentAppleAccountSummary"
    static let teamKey = "independentAppleTeamID"

    @Published private(set) var summary: IndependentAccountSummary?
    @Published private(set) var isBusy = false
    @Published private(set) var needsVerification = false
    @Published private(set) var status = "在 AutoSign 登录 Apple 账号，可独立签发并在锁屏时续签。"
    @Published var selectedTeamID: String {
        didSet { UserDefaults.standard.set(selectedTeamID, forKey: Self.teamKey) }
    }
    private var verificationReply: ((String?) -> Void)?
    private var verificationTimeout: Task<Void, Never>?

    nonisolated static var isEnabled: Bool { UserDefaults.standard.bool(forKey: enabledKey) }

    init() {
        selectedTeamID = UserDefaults.standard.string(forKey: Self.teamKey) ?? ""
        if let data = UserDefaults.standard.data(forKey: Self.summaryKey) {
            summary = try? JSONDecoder().decode(IndependentAccountSummary.self, from: data)
        }
        if Self.isEnabled { status = "独立续签已启用；登录凭据保存在此 Mac 的系统钥匙串。" }
    }

    func signIn(email: String, password: String) async {
        guard !isBusy else { return }
        let email = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !email.isEmpty, !password.isEmpty else { status = "请输入 Apple 账号和密码。"; return }
        isBusy = true
        defer { isBusy = false; finishVerification(nil) }
        do {
            let lock = try SigningOperationLock()
            defer { withExtendedLifetime(lock) {} }
            try AppleAccountStore.checkAvailability()
            let anisette = try await LocalAnisetteProvider.fetch { self.status = $0 }
            status = "正在向 Apple 登录…"
            let (account, session) = try await authenticate(email: email, password: password,
                anisette: anisette, interactive: true)
            let teams = try await AltAppleBridge.teams(account: account, session: session)
            guard !teams.isEmpty else { throw AutoSignError.command("此 Apple 账号没有可用的开发者团队，请先在 Apple 开发者网站完成免费账号设置。") }
            let credentials = AppleAccountCredentials(email: email, password: password, dsid: session.dsid,
                authToken: session.authToken, firstName: account.firstName, lastName: account.lastName, authenticatedAt: Date(),
                authenticationProvider: LocalAnisetteProvider.providerID)
            try AppleAccountStore.save(credentials)
            let value = IndependentAccountSummary(email: email, name: account.name,
                teams: teams.map { IndependentTeam(id: $0.identifier, name: $0.name, isFree: $0.type == .free) },
                authenticatedAt: credentials.authenticatedAt)
            summary = value
            if !value.teams.contains(where: { $0.id == selectedTeamID }) { selectedTeamID = value.teams[0].id }
            UserDefaults.standard.set(try JSONEncoder().encode(value), forKey: Self.summaryKey)
            UserDefaults.standard.set(true, forKey: Self.enabledKey)
            status = "登录成功；已启用独立签发和锁屏续签。请完成一次锁屏真机验证。"
        } catch {
            if Self.appleErrorCode(error) == -80045 {
                status = WindowsAnisetteProvider.configuredURL == nil
                    ? "Apple 拒绝了当前设备认证（-80045）。本地 Android 认证受到上游已知问题影响；可在上方选择并启用 Windows 认证服务后重试。原账号和签名保留。"
                    : "Apple 拒绝了 Windows 设备认证（-80045）。上游也报告部分账号仍失败，请稍后重试；原账号和签名保留。"
            } else { status = error.localizedDescription }
        }
    }

    nonisolated static func appleErrorCode(_ error: Error) -> Int? {
        let error = error as NSError
        if error.domain == ALTUnderlyingAppleAPIErrorDomain { return error.code }
        if let underlying = error.userInfo[NSUnderlyingErrorKey] as? Error { return appleErrorCode(underlying) }
        return nil
    }

    func configureWindowsAnisette(_ input: String?) {
        guard !isBusy, summary == nil else { return }
        if let input {
            guard let url = WindowsAnisetteProvider.validatedURL(input) else {
                status = "请输入自托管 Windows Anisette v3 服务的 HTTPS 根地址；本机服务可用 http://127.0.0.1:端口。不含路径、账号、密码或查询参数。"; return
            }
            UserDefaults.standard.set(url.absoluteString, forKey: WindowsAnisetteProvider.serverKey)
            status = "已选择 \(url.host ?? "")；登录时将向此服务发送独立的设备认证资料，账号密码和验证码只发送给 Apple。"
        } else {
            UserDefaults.standard.removeObject(forKey: WindowsAnisetteProvider.serverKey)
            status = "已选择本机设备认证；当前 Apple 可能拒绝此方式并返回 -80045。"
        }
    }

    func submitVerification(_ code: String) {
        let code = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard code.count == 6, code.allSatisfy(\.isNumber) else { status = "请输入六位验证码。"; return }
        finishVerification(code)
        status = "正在验证…"
    }

    func cancelVerification() { finishVerification(nil) }

    private func finishVerification(_ code: String?) {
        verificationTimeout?.cancel(); verificationTimeout = nil
        let reply = verificationReply
        verificationReply = nil
        needsVerification = false
        reply?(code)
    }

    func signOut() {
        guard !isBusy else { return }
        do {
            let lock = try SigningOperationLock()
            defer { withExtendedLifetime(lock) {} }
            try AppleAccountStore.remove()
            UserDefaults.standard.removeObject(forKey: Self.summaryKey)
            UserDefaults.standard.set(false, forKey: Self.enabledKey)
            summary = nil
            status = "已删除 AutoSign 保存的账号密码和会话；Xcode 账号、签名证书和已安装应用保留。"
        } catch { status = error.localizedDescription }
    }

    func authenticate(email: String, password: String, anisette: ALTAnisetteData,
                      interactive: Bool) async throws -> (ALTAccount, ALTAppleAPISession) {
        ALTAppleAPI.shared.anisetteDataRefreshHandler = { reply in
            let completion = AltAppleBridge.Transfer(reply)
            Task { @MainActor in
                do { completion.value(try await LocalAnisetteProvider.fetch(), nil) }
                catch { completion.value(nil, error as NSError) }
            }
        }
        ALTAppleAPI.shared.anisetteDataResyncHandler = { sim, reply in
            let completion = AltAppleBridge.Transfer(reply)
            Task { @MainActor in
                do {
                    let remote = try await WindowsAnisetteProvider.shared.resync(sim: sim)
                    ALTAppleAPI.shared.authenticationUserAgent = remote.userAgent
                    completion.value(remote.makeAnisetteData(), nil)
                } catch { completion.value(nil, error as NSError) }
            }
        }
        let result: AltAppleBridge.Transfer<(ALTAccount, ALTAppleAPISession)> = try await withCheckedThrowingContinuation { continuation in
            ALTAppleAPI.shared.authenticate(appleID: email, password: password, anisetteData: anisette,
                verificationHandler: { reply in
                    let transferred = AltAppleBridge.Transfer(reply)
                    Task { @MainActor in
                        guard interactive else { transferred.value(nil); return }
                        self.verificationReply = transferred.value
                        self.needsVerification = true
                        self.status = "Apple 已发送验证码，请在下方输入。"
                        self.verificationTimeout = Task { @MainActor in
                            do { try await Task.sleep(for: .seconds(300)) } catch { return }
                            self.finishVerification(nil)
                        }
                    }
                }, completionHandler: { account, session, error in
                    if let error { continuation.resume(throwing: error) }
                    else if let account, let session { continuation.resume(returning: .init((account, session))) }
                    else { continuation.resume(throwing: IndependentAccountError.invalidResponse) }
                })
        }
        return result.value
    }
}

/// ObjC API callbacks transfer ownership into the main-actor signing coordinator.
enum AltAppleBridge {
    struct Transfer<Value>: @unchecked Sendable {
        let value: Value
        init(_ value: Value) { self.value = value }
    }

    @MainActor static func value<T>(_ operation: (@escaping @Sendable (T?, Error?) -> Void) -> Void) async throws -> T {
        let result: Transfer<T> = try await withCheckedThrowingContinuation { continuation in
            operation { value, error in
                if let error { continuation.resume(throwing: error) }
                else if let value { continuation.resume(returning: .init(value)) }
                else { continuation.resume(throwing: IndependentAccountError.invalidResponse) }
            }
        }
        return result.value
    }

    @MainActor static func teams(account: ALTAccount, session: ALTAppleAPISession) async throws -> [ALTTeam] {
        try await value { ALTAppleAPI.shared.fetchTeams(for: account, session: session, completionHandler: $0) }
    }
}
