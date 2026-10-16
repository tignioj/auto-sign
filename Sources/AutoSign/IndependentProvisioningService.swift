import Foundation
import CryptoKit
import Security
@preconcurrency import AltSign

@MainActor
enum IndependentProvisioningService {
    static func profile(for device: AppleDevice, bundleID: String, original: ProvisioningProfile,
                        requireExtendedExpiry: Bool,
                        statusChanged: @escaping @MainActor @Sendable (String) -> Void) async throws -> URL {
        guard let credentials = try AppleAccountStore.load() else { throw IndependentAccountError.signInRequired }
        if let provider = credentials.authenticationProvider, provider != LocalAnisetteProvider.providerID {
            throw IndependentAccountError.providerChanged
        }
        let anisette = try await LocalAnisetteProvider.fetch(statusChanged: statusChanged)
        var session = ALTAppleAPISession(dsid: credentials.dsid, authToken: credentials.authToken, anisetteData: anisette)
        var account = makeAccount(credentials)
        let teams: [ALTTeam]
        do { teams = try await AltAppleBridge.teams(account: account, session: session) }
        catch {
            guard sessionExpired(error) else { throw error }
            statusChanged("Apple 登录会话已到期，正在使用系统钥匙串中的凭据重新登录…")
            do {
                (account, session) = try await IndependentAccountModel.shared.authenticate(email: credentials.email,
                    password: credentials.password, anisette: anisette, interactive: false)
            } catch {
                let detail = error as NSError
                if detail.domain == ALTAppleAPIErrorDomain && [3018, 3019].contains(detail.code) {
                    throw IndependentAccountError.verificationRequired
                }
                if detail.domain == ALTAppleAPIErrorDomain && detail.code == 3002 {
                    throw IndependentAccountError.signInRequired
                }
                throw error
            }
            var refreshed = credentials
            refreshed.dsid = session.dsid; refreshed.authToken = session.authToken; refreshed.authenticatedAt = Date()
            try AppleAccountStore.save(refreshed)
            teams = try await AltAppleBridge.teams(account: account, session: session)
        }
        guard let team = teams.first(where: { $0.identifier == original.teamIdentifier }) else {
            throw IndependentAccountError.teamMismatch
        }
        statusChanged("正在通过 AutoSign 独立账号为 \(bundleID) 签发描述文件…")
        let api = ALTAppleAPI.shared
        let type: ALTDeviceType = device.kind == .iPad ? .ipad : .iphone
        let registered: [ALTDevice] = try await AltAppleBridge.value {
            api.fetchDevices(for: team, types: [.iphone, .ipad], session: session, completionHandler: $0)
        }
        if !registered.contains(where: { $0.identifier.caseInsensitiveCompare(device.udid) == .orderedSame }) {
            let _: ALTDevice = try await AltAppleBridge.value {
                api.registerDevice(name: device.name, identifier: device.udid, type: type, team: team, session: session, completionHandler: $0)
            }
        }
        // Reuse all existing certificates; never revoke another tool's identity.
        let certificates: [ALTCertificate] = try await AltAppleBridge.value {
            api.fetchCertificates(for: team, session: session, completionHandler: $0)
        }
        guard certificates.contains(where: { certificate in
            guard let data = certificate.data, let hash = certificateHash(data) else { return false }
            return original.signingCertificateHashes.contains(hash)
        }) || original.signingCertificateHashes.isEmpty else {
            throw AutoSignError.command("Apple 账号中未找到此应用原有签名证书。已停止续签且未撤销其他证书，请在签名设置检查原团队的证书。")
        }
        if original.signingCertificateHashes.isEmpty {
            try await ensureCertificate(certificates, team: team, session: session, statusChanged: statusChanged)
        }
        let appIDs: [ALTAppID] = try await AltAppleBridge.value {
            api.fetchAppIDs(for: team, session: session, completionHandler: $0)
        }
        let app: ALTAppID
        if let existing = appIDs.first(where: { $0.bundleIdentifier == bundleID }) { app = existing }
        else {
            app = try await AltAppleBridge.value {
                api.addAppID(withName: "AutoSign " + String(bundleID.replacingOccurrences(of: ".", with: " ").prefix(80)), bundleIdentifier: bundleID,
                             team: team, session: session, completionHandler: $0)
            }
        }
        let requestedAt = Date()
        var profile: ALTProvisioningProfile = try await AltAppleBridge.value {
            api.fetchProvisioningProfile(for: app, deviceType: type, team: team, session: session, completionHandler: $0)
        }
        // AltStore renews the owned app's profile by deleting its server-side
        // cache and fetching a new one. Installed profiles/assets remain intact.
        if profile.uuid.uuidString == original.uuid || profile.creationDate < requestedAt.addingTimeInterval(-120)
            || (requireExtendedExpiry && profile.expirationDate <= original.expirationDate) {
            guard profile.bundleIdentifier == bundleID, profile.teamIdentifier == team.identifier,
                  profile.identifier != nil else {
                throw IndependentAccountError.invalidResponse
            }
            let deleted: Bool = try await AltAppleBridge.value { completion in
                api.delete(profile, for: team, session: session) { success, error in completion(success, error) }
            }
            guard deleted else { throw IndependentAccountError.invalidResponse }
            profile = try await AltAppleBridge.value {
                api.fetchProvisioningProfile(for: app, deviceType: type, team: team, session: session, completionHandler: $0)
            }
        }
        let directory = try BackgroundRefreshManager.applicationSupportURL().appendingPathComponent("Profiles", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let candidate = directory.appendingPathComponent("native-\(UUID().uuidString).mobileprovision")
        try profile.data.write(to: candidate, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: candidate.path)
        do {
            let renewed = try await SigningService.readProfile(at: candidate)
            try ProfileRenewalPolicy.validate(original: original, renewed: renewed, bundleID: bundleID,
                deviceUDID: device.udid, requestedAt: requestedAt, requireExtendedExpiry: requireExtendedExpiry)
            let name = SHA256.hash(data: Data((original.teamIdentifier + ":" + bundleID).utf8))
                .map { String(format: "%02x", $0) }.joined()
            let destination = directory.appendingPathComponent("native-\(name.prefix(24)).mobileprovision")
            if FileManager.default.fileExists(atPath: destination.path) {
                _ = try FileManager.default.replaceItemAt(destination, withItemAt: candidate)
            } else { try FileManager.default.moveItem(at: candidate, to: destination) }
            return destination
        } catch {
            try? FileManager.default.removeItem(at: candidate)
            throw error
        }
    }

    static func makeAccount(_ credentials: AppleAccountCredentials) -> ALTAccount {
        let account = ALTAccount()
        account.appleID = credentials.email; account.identifier = credentials.dsid
        account.firstName = credentials.firstName; account.lastName = credentials.lastName
        return account
    }

    static func seedProfile() throws -> ProvisioningProfile {
        let account = IndependentAccountModel.shared
        guard IndependentAccountModel.isEnabled,
              let team = account.summary?.teams.first(where: { $0.id == account.selectedTeamID }) else {
            throw IndependentAccountError.signInRequired
        }
        return ProvisioningProfile(name: "AutoSign 独立账号", uuid: "native-seed", expirationDate: .distantPast,
            applicationIdentifier: team.id + ".*", teamIdentifier: team.id, provisionedDevices: [],
            provisionsAllDevices: false, entitlements: [:], timeToLiveDays: team.isFree ? 7 : nil)
    }

    static func reusableIdentity(certificates: [ALTCertificate], identities: [SigningIdentity]) -> SigningIdentity? {
        let hashes = Set(certificates.compactMap { $0.data.flatMap(certificateHash) })
        return identities.first { hashes.contains($0.hash.uppercased()) }
    }

    private static func ensureCertificate(_ certificates: [ALTCertificate], team: ALTTeam,
                                          session: ALTAppleAPISession,
                                          statusChanged: @escaping @MainActor @Sendable (String) -> Void) async throws {
        let local = try await SigningService.identities()
        if reusableIdentity(certificates: certificates, identities: local) != nil {
            statusChanged("正在复用本机已有开发证书，不申请新证书…")
            return
        }
        // Recover only this app's private key. Never revoke a certificate to make room.
        let key = "signing-certificate-" + team.identifier
        if let p12 = try AppleAccountStore.loadData(account: key) {
            try importCertificate(p12)
            let recovered = try await SigningService.identities()
            if reusableIdentity(certificates: certificates, identities: recovered) != nil {
                statusChanged("已恢复并复用 AutoSign 保存的开发证书…")
                return
            }
        }
        let certificate: ALTCertificate
        do {
            certificate = try await AltAppleBridge.value {
                ALTAppleAPI.shared.addCertificate(machineName: "AutoSign", to: team, session: session, completionHandler: $0)
            }
        } catch {
            guard IndependentAccountModel.appleErrorCode(error) == 7460 else { throw error }
            throw AutoSignError.command("Apple 拒绝创建开发证书（7460）：此团队已有开发证书或待处理申请，但本机未找到匹配的可用私钥。请从原签名 Mac 导入包含私钥的 .p12 后刷新本机证书；现有证书未被撤销。")
        }
        guard let p12 = certificate.p12Data() else { throw IndependentAccountError.invalidResponse }
        // Save the issued key before import so an interrupted setup can recover it.
        try AppleAccountStore.saveData(p12, account: key)
        try importCertificate(p12)
    }

    /// AltSign exposes PEM, whereas provisioning profiles and security
    /// find-identity use the DER certificate's SHA-1 fingerprint.
    nonisolated static func certificateHash(_ data: Data) -> String? {
        var der = data
        if let text = String(data: data, encoding: .utf8),
           let start = text.range(of: "-----BEGIN CERTIFICATE-----"),
           let end = text.range(of: "-----END CERTIFICATE-----", range: start.upperBound..<text.endIndex) {
            let base64 = text[start.upperBound..<end.lowerBound].filter { !$0.isWhitespace }
            guard let decoded = Data(base64Encoded: String(base64)) else { return nil }
            der = decoded
        }
        guard let certificate = SecCertificateCreateWithData(nil, der as CFData) else { return nil }
        return Insecure.SHA1.hash(data: SecCertificateCopyData(certificate) as Data)
            .map { String(format: "%02X", $0) }.joined()
    }

    private static func importCertificate(_ data: Data) throws {
        try AppleAccountStore.requireUnlockedKeychain()
        var keychain: SecKeychain?
        let defaultStatus = SecKeychainCopyDefault(&keychain)
        guard defaultStatus == errSecSuccess, let keychain else { throw AppleAccountStore.failure(defaultStatus) }
        var trusted: [SecTrustedApplication] = []
        for path in ["/usr/bin/codesign", Bundle.main.executableURL?.path].compactMap({ $0 }) {
            var app: SecTrustedApplication?
            let status = SecTrustedApplicationCreateFromPath(path, &app)
            guard status == errSecSuccess, let app else { throw AppleAccountStore.failure(status) }
            trusted.append(app)
        }
        var access: SecAccess?
        let accessStatus = SecAccessCreate("AutoSign 签名证书" as CFString, trusted as CFArray, &access)
        guard accessStatus == errSecSuccess, let access else { throw AppleAccountStore.failure(accessStatus) }
        let options: [String: Any] = [kSecImportExportPassphrase as String: "",
                                     kSecImportExportKeychain as String: keychain,
                                     kSecImportExportAccess as String: access]
        var imported: CFArray?
        let status = SecPKCS12Import(data as CFData, options as CFDictionary, &imported)
        guard status == errSecSuccess else { throw AppleAccountStore.failure(status) }
    }

    static func sessionExpired(_ error: Error) -> Bool {
        let error = error as NSError
        if error.domain == ALTUnderlyingAppleAPIErrorDomain && error.code == 1100 { return true }
        if let underlying = error.userInfo[NSUnderlyingErrorKey] as? Error { return sessionExpired(underlying) }
        return false
    }
}
