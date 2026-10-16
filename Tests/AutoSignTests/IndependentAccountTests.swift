import Foundation
import Security
import Testing
@preconcurrency import AltSign
@testable import AutoSign

@Test func independentCredentialsUseNonSynchronizingLoginKeychain() {
    let query = AppleAccountStore.query()
    #expect(query[kSecUseDataProtectionKeychain as String] as? Bool == false)
    #expect(query[kSecAttrSynchronizable as String] as? Bool == false)
    #expect(query[kSecUseAuthenticationUI as String] == nil) // Legacy keychain UI is disabled around each operation.
    #expect(query[kSecAttrService as String] as? String == "local.autosign.desktop.apple-account")
    let attributes = AppleAccountStore.attributes(data: Data("test".utf8))
    #expect(attributes[kSecAttrAccessible as String] == nil) // Login-keychain locking governs availability.
    #expect(attributes[kSecAttrAccessGroup as String] == nil) // No unprovisioned Mac access-group claim.
}

@Test func publicAccountSummaryCannotPersistPasswordOrSessionToken() throws {
    let credentials = AppleAccountCredentials(email: "user@example.test", password: "fixture-password",
        dsid: "fixture-dsid", authToken: "fixture-token", firstName: "Test", lastName: "User", authenticatedAt: Date())
    let summary = IndependentAccountSummary(email: credentials.email, name: "Test User",
        teams: [.init(id: "TEAM", name: "Personal Team", isFree: true)], authenticatedAt: credentials.authenticatedAt)
    let data = try JSONEncoder().encode(summary)
    let text = String(decoding: data, as: UTF8.self)
    for secret in [credentials.password, credentials.dsid, credentials.authToken] { #expect(!text.contains(secret)) }
    let decoded = try JSONDecoder().decode(IndependentAccountSummary.self, from: data)
    #expect(decoded.teams.first?.isFree == true)
    #expect(decoded.teams.first?.id == "TEAM")
}

@MainActor @Test func onlyAppleSessionExpirationCanTriggerAutomaticReauthentication() {
    let expired = NSError(domain: "Apple.APIError", code: 1100)
    #expect(IndependentProvisioningService.sessionExpired(expired))
    let wrapped = NSError(domain: "AltStore.AppleDeveloperError", code: 3000, userInfo: [NSUnderlyingErrorKey: expired])
    #expect(IndependentProvisioningService.sessionExpired(wrapped))
    #expect(!IndependentProvisioningService.sessionExpired(NSError(domain: NSURLErrorDomain, code: 1100)))
    #expect(!IndependentProvisioningService.sessionExpired(NSError(domain: "Apple.APIError", code: 3013)))
    #expect(!IndependentProvisioningService.sessionExpired(NSError(domain: NSOSStatusErrorDomain, code: -25308)))
}

@Test func lockedKeychainFailurePreservesCredentialsAndExplainsFirstLogin() {
    let message = AppleAccountStore.failure(errSecInteractionNotAllowed).localizedDescription
    #expect(message.contains("重启后先登录一次 Mac"))
    #expect(message.contains("不会因读取失败而删除"))
    #expect(AppleAccountStore.failure(errSecMissingEntitlement).localizedDescription.contains("代码签名"))
}

@Test func windowsAnisetteRejectsInsecureOrCredentialBearingServiceURLs() {
    #expect(WindowsAnisetteProvider.validatedURL(" https://ANI.EXAMPLE.TEST:443/ ")?.absoluteString == "https://ani.example.test")
    #expect(WindowsAnisetteProvider.validatedURL("http://127.0.0.1:6969")?.absoluteString == "http://127.0.0.1:6969")
    #expect(WindowsAnisetteProvider.validatedURL("http://[::1]:6969") != nil)
    #expect(WindowsAnisetteProvider.validatedURL("https://private.example.test:8443") != nil)
    for unsafe in ["http://ani.example.test", "https://user:password@ani.example.test", "https://ani.example.test/?token=secret",
                   "https://ani.example.test/#secret", "https://ani.example.test/v3", "file:///tmp/service", "https://",
                   "http://192.168.1.2:6969", "http://127.0.0.1.attacker.test:6969", "http://localhost.attacker.test:6969"] {
        #expect(WindowsAnisetteProvider.validatedURL(unsafe) == nil)
    }
}

@Test func authenticationErrorDiagnosisRequiresApplesOwnErrorDomain() {
    #expect(IndependentAccountModel.appleErrorCode(NSError(domain: "Apple.APIError", code: -80045)) == -80045)
    #expect(IndependentAccountModel.appleErrorCode(NSError(domain: NSURLErrorDomain, code: -80045)) == nil)
    let underlying = NSError(domain: "Apple.APIError", code: -80045)
    #expect(IndependentAccountModel.appleErrorCode(NSError(domain: "wrapper", code: 0,
        userInfo: [NSUnderlyingErrorKey: underlying])) == -80045)
}

@Test func windowsProvisioningPreservesApplesStringAndNumericRoutingValues() throws {
    for (key, value) in [("X-Apple-I-MD-RINFO", "17106176" as Any), ("routing-info", 17106176 as Any)] {
        let data = try PropertyListSerialization.data(fromPropertyList: ["ptm": "fixture", "tk": "fixture", key: value], format: .xml, options: 0)
        let response = try PropertyListDecoder().decode(WindowsProvisioningFinish.self, from: data)
        #expect(response.routingInfo == "17106176")
        let body = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(response)) as? [String: String])
        #expect(body["X-Apple-I-MD-RINFO"] == "17106176")
        #expect(body["routing-info"] == nil)
    }
}

@Test func applePEMCertificatesMatchProvisioningProfilesDERFingerprints() throws {
    // Public, anonymous self-signed fixture; no signing private key is stored in the repository.
    let base64 = certificateFixtureBase64
    let der = try #require(Data(base64Encoded: base64))
    let pem = Data(("-----BEGIN CERTIFICATE-----\r\n" + base64 + "\r\n-----END CERTIFICATE-----\r\n").utf8)
    #expect(IndependentProvisioningService.certificateHash(der) == "40DF0C9779C78285CE57AE1AD19CD451AB7E028D")
    #expect(IndependentProvisioningService.certificateHash(pem) == IndependentProvisioningService.certificateHash(der))
    #expect(IndependentProvisioningService.certificateHash(Data("invalid certificate".utf8)) == nil)
}

@MainActor @Test func existingIdentityRequiresTheServersCertificateAndLocalPrivateKey() throws {
    let der = try #require(Data(base64Encoded: certificateFixtureBase64))
    let certificate = try #require(ALTCertificate(data: der))
    let matching = SigningIdentity(hash: "40df0c9779c78285ce57ae1ad19cd451ab7e028d", name: "Apple Development: Existing")
    let unrelated = SigningIdentity(hash: String(repeating: "0", count: 40), name: "Apple Development: Other")
    #expect(IndependentProvisioningService.reusableIdentity(certificates: [certificate], identities: [unrelated, matching]) == matching)
    #expect(IndependentProvisioningService.reusableIdentity(certificates: [certificate], identities: [unrelated]) == nil)
    #expect(IndependentProvisioningService.reusableIdentity(certificates: [], identities: [matching]) == nil)
    #expect(IndependentProvisioningService.reusableIdentity(certificates: [certificate], identities: []) == nil)
}

@MainActor @Test func certificateQueryIncludesUnifiedAndLegacyDevelopmentCertificates() async throws {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [DevelopmentCertificateQueryProtocol.self]
    let mockSession = URLSession(configuration: configuration)
    defer { mockSession.invalidateAndCancel() }
    let api = ALTAppleAPI()
    api.setValue(mockSession, forKey: "session")
    let anisette = ALTAnisetteData(machineID: "fixture", oneTimePassword: "fixture", localUserID: "fixture",
        routingInfo: 0, deviceUniqueIdentifier: "fixture", deviceSerialNumber: "fixture", deviceDescription: "fixture",
        date: Date(), locale: Locale(identifier: "en_US"), timeZone: TimeZone(secondsFromGMT: 0)!)
    let session = ALTAppleAPISession(dsid: "fixture", authToken: "fixture", anisetteData: anisette)
    let team = ALTTeam(name: "Fixture", identifier: "TEAM", type: .free, account: ALTAccount())
    let certificates: [ALTCertificate] = try await AltAppleBridge.value {
        api.fetchCertificates(for: team, session: session, completionHandler: $0)
    }
    #expect(certificates.count == 2)
    let identity = SigningIdentity(hash: "40DF0C9779C78285CE57AE1AD19CD451AB7E028D", name: "Apple Development: Existing")
    #expect(IndependentProvisioningService.reusableIdentity(certificates: certificates, identities: [identity]) == identity)
}

private final class DevelopmentCertificateQueryProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        do {
            var requestData = request.httpBody ?? Data()
            if let stream = request.httpBodyStream {
                stream.open()
                defer { stream.close() }
                var buffer = [UInt8](repeating: 0, count: 4096)
                while stream.hasBytesAvailable {
                    let count = stream.read(&buffer, maxLength: buffer.count)
                    guard count >= 0 else { throw URLError(.cannotDecodeRawData) }
                    if count == 0 { break }
                    requestData.append(contentsOf: buffer.prefix(count))
                }
            }
            // Fail if the request attempts certificate creation/revocation or omits
            // either development type. No request can reach Apple's real service.
            guard request.url?.path == "/services/v1/certificates",
                  request.value(forHTTPHeaderField: "X-HTTP-Method-Override") == "GET",
                  let body = try JSONSerialization.jsonObject(with: requestData) as? [String: String],
                  let query = body["urlEncodedQueryParams"],
                  let items = URLComponents(string: "https://fixture.test/?" + query)?.queryItems,
                  items.contains(where: { $0.name == "teamId" && $0.value == "TEAM" }),
                  let filter = items.first(where: { $0.name == "filter[certificateType]" })?.value,
                  Set(filter.split(separator: ",")) == ["IOS_DEVELOPMENT", "DEVELOPMENT"] else {
                throw URLError(.badServerResponse)
            }
            let certificates = ["IOS_DEVELOPMENT", "DEVELOPMENT"].enumerated().map { index, type in
                ["id": "fixture-\(index)", "type": "certificates", "attributes": [
                    "certificateType": type, "certificateContent": certificateFixtureBase64
                ]] as [String: Any]
            }
            let responseData = try JSONSerialization.data(withJSONObject: ["data": certificates])
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200,
                httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: responseData)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
}

private let certificateFixtureBase64 = "MIIBujCCAV+gAwIBAgIUHATZuFqdYmKBKJrtIoOCIwHjIaswCgYIKoZIzj0EAwIwMjEeMBwGA1UEAwwVQXV0b1NpZ24gVGVzdCBGaXh0dXJlMRAwDgYDVQQLDAdGSVhUVVJFMB4XDTI2MTAxNjAwMjMxNFoXDTM2MTAxMzAwMjMxNFowMjEeMBwGA1UEAwwVQXV0b1NpZ24gVGVzdCBGaXh0dXJlMRAwDgYDVQQLDAdGSVhUVVJFMFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEnKomyk6VyIedJin6psDn1W61mxh4B3zc5g1Wv3abYmh0e/LwGqz4KuC1x5Kj93Hcl/riLxTkRoJl5/yFsd+wmaNTMFEwHQYDVR0OBBYEFCueyvxuP2Aem2SbsSMFASA2wtJJMB8GA1UdIwQYMBaAFCueyvxuP2Aem2SbsSMFASA2wtJJMA8GA1UdEwEB/wQFMAMBAf8wCgYIKoZIzj0EAwIDSQAwRgIhAIUUDNTwV07WrRuEIvvMh25ZRu1RZtM5K3PmmsZ+EKI3AiEAltqX0uUQWcpXmspAEfr2gmojfnNon9MjZudLgNKrDd4="
