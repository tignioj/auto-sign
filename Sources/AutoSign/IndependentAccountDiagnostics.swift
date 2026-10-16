import Foundation
import AnisetteKit
@preconcurrency import AltSign

@MainActor
enum IndependentAccountDiagnostics {
    /// Read-only account verification in a fresh signed app process. Outputs no
    /// password, token, DSID, anisette header, private key, or email address.
    static func run() async {
        var report: [String: Any] = ["checkedAt": ISO8601DateFormatter().string(from: Date()),
            "screenLocked": XcodeCredentialAccess.currentState() == .locked,
            "authenticationSource": WindowsAnisetteProvider.configuredURL == nil ? "local" : "windows-service",
            "independentEnabled": IndependentAccountModel.isEnabled]
        do {
            let lock = try SigningOperationLock()
            defer { withExtendedLifetime(lock) {} }
            try AppleAccountStore.checkAvailability()
            report["keychainAvailable"] = true
            let anisette = try await LocalAnisetteProvider.fetch()
            report["deviceAuthenticationAvailable"] = true
            if let credentials = try AppleAccountStore.load() {
                report["keychainReadable"] = true
                let session = ALTAppleAPISession(dsid: credentials.dsid, authToken: credentials.authToken, anisetteData: anisette)
                let teams = try await AltAppleBridge.teams(account: IndependentProvisioningService.makeAccount(credentials), session: session)
                report["appleSessionValid"] = !teams.isEmpty
                report["freeTeamAvailable"] = teams.contains { $0.type == .free }
            } else { report["signInRequired"] = true }
        } catch {
            if let local = error as? AutoSignError {
                report["localError"] = local.localizedDescription
            }
            if let anisette = error as? AnisetteKit.AnisetteError {
                switch anisette {
                case .adiError(let code, _): report["adiErrorCode"] = code
                case .loaderFailed(let reason): report["loaderError"] = String(reason.prefix(200))
                case .httpError(let code, _): report["httpErrorCode"] = code
                case .readFailure: report["anisetteReadFailure"] = true
                default: break
                }
            }
            let error = error as NSError
            report["errorDomain"] = error.domain
            report["errorCode"] = error.code
        }
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]) {
            print(String(decoding: data, as: UTF8.self))
        }
    }
}
