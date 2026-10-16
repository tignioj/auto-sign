import AutoSignLocalization
//
//  WindowsAnisetteProvider.swift
//  AltServer
//
//  Created by Nick Clyde on 9/16/26.
//  Copyright © 2026 Riley Testut. All rights reserved.
//

import Foundation
import Combine
import CryptoKit
@preconcurrency import AltSign

// Adapted from AltStore PR #1834, commit ddb4415cc6aeeb3145de33a29f7064292a45d895.
// AutoSign requires explicit server selection and stores identities in Keychain.

private extension URL
{
    static let appleGSALookup = URL(string: "https://gsa.apple.com/grandslam/GsService2/lookup")!
}

// Never forward anisette credentials or provisioning data through redirects.
private final class AnisetteSessionDelegate: NSObject, URLSessionTaskDelegate
{
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void)
    {
        completionHandler(nil)
    }
}

// Plain value returned across the actor boundary; ALTAnisetteData itself isn't Sendable.
struct RemoteAnisetteData: Sendable
{
    var machineID: String
    var oneTimePassword: String
    var localUserID: String
    var routingInfo: UInt64
    var deviceUniqueIdentifier: String
    var deviceSerialNumber: String
    var deviceDescription: String
    var userAgent: String

    func makeAnisetteData() -> ALTAnisetteData
    {
        return ALTAnisetteData(machineID: self.machineID,
                               oneTimePassword: self.oneTimePassword,
                               localUserID: self.localUserID,
                               routingInfo: self.routingInfo,
                               deviceUniqueIdentifier: self.deviceUniqueIdentifier,
                               deviceSerialNumber: self.deviceSerialNumber,
                               deviceDescription: self.deviceDescription,
                               date: Date(),
                               locale: .current,
                               timeZone: .current)
    }
}

// Stable identity for the remote anisette "device": 16 random bytes, plus the adi.pb
// provisioning blob issued for that identity. Both are persisted so Apple sees the same
// machine across launches (otherwise every install would trigger a fresh 2FA prompt).
private struct AnisetteIdentity: Codable
{
    var bytes: Data
    var adiPB: Data?
    var serverURL: URL?

    var identifier: String { self.bytes.base64EncodedString() }
    var localUserID: String { SHA256.hash(data: self.bytes).map { String(format: "%02x", $0) }.joined() }
    var deviceID: String { self.bytes.withUnsafeBytes { UUID(uuid: $0.loadUnaligned(as: uuid_t.self)) }.uuidString.lowercased() }

    static func make() -> AnisetteIdentity
    {
        let bytes = Data((0..<16).map { _ in UInt8.random(in: .min ... .max) })
        return AnisetteIdentity(bytes: bytes)
    }
}

@MainActor
private struct AnisetteIdentityStore
{
    private func key(_ server: URL) -> String {
        "windows-anisette-v1-" + SHA256.hash(data: Data(server.absoluteString.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    func load(server: URL) throws -> AnisetteIdentity? {
        guard let data = try AppleAccountStore.loadData(account: key(server)) else { return nil }
        let identity = try JSONDecoder().decode(AnisetteIdentity.self, from: data)
        guard identity.bytes.count == 16, identity.serverURL == server else { throw WindowsAnisetteError.invalidResponse }
        return identity
    }
    func save(_ identity: AnisetteIdentity) throws {
        guard let server = identity.serverURL else { throw WindowsAnisetteError.invalidResponse }
        try AppleAccountStore.saveData(JSONEncoder().encode(identity), account: key(server))
    }
}

enum WindowsAnisetteError: Error, LocalizedError {
    case invalidResponse, unavailable, provisioningFailed, notConfigured
    var errorDescription: String? {
        switch self {
        case .invalidResponse: L10n.tr("Windows 设备认证服务返回的数据无效；需要支持 Windows 身份的 Anisette v3 服务。")
        case .unavailable: L10n.tr("Windows 设备认证服务暂不可用，请检查服务地址和网络后重试。")
        case .provisioningFailed: L10n.tr("Windows 设备认证注册失败；已保留钥匙串凭据，请稍后重试。")
        case .notConfigured: L10n.tr("请先在签名设置启用所选 Windows 设备认证服务。")
        }
    }
}

struct WindowsProvisioningFinish: Codable {
    var ptm: String
    var tk: String
    var routingInfo: String?
    private enum CodingKeys: String, CodingKey {
        case ptm, tk
        case routingInfo = "X-Apple-I-MD-RINFO"
        case alternateRouting = "routing-info"
    }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        ptm = try values.decode(String.self, forKey: .ptm)
        tk = try values.decode(String.self, forKey: .tk)
        for key in [CodingKeys.routingInfo, .alternateRouting] {
            if let text = try? values.decode(String.self, forKey: key) { routingInfo = text; break }
            if let number = try? values.decode(UInt64.self, forKey: key) { routingInfo = String(number); break }
        }
    }
    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(ptm, forKey: .ptm); try values.encode(tk, forKey: .tk)
        try values.encodeIfPresent(routingInfo, forKey: .routingInfo)
    }
}

// Fetches anisette data from a remote anisette server using the v3 protocol.
//
// The local Android provider is rejected by Apple on this Mac. This optional
// provider follows AltStore's Windows workaround, without selecting a server by default.
@MainActor
final class WindowsAnisetteProvider
{
    static let shared = WindowsAnisetteProvider()
    nonisolated static let serverKey = "independentWindowsAnisetteServer"
    static var configuredURL: URL? {
        UserDefaults.standard.string(forKey: serverKey).flatMap(validatedURL)
    }
    nonisolated static func validatedURL(_ input: String) -> URL? {
        guard let components = URLComponents(string: input.trimmingCharacters(in: .whitespacesAndNewlines)),
              let host = components.host, !host.isEmpty,
              components.scheme == "https" || (components.scheme == "http" && ["127.0.0.1", "::1", "[::1]"].contains(host)),
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil,
              components.port.map({ (1...65535).contains($0) }) ?? true,
              components.percentEncodedPath.isEmpty || components.percentEncodedPath == "/" else { return nil }
        var normalized = components
        normalized.host = host.lowercased(); normalized.path = ""
        if (components.scheme == "https" && components.port == 443) || (components.scheme == "http" && components.port == 80) { normalized.port = nil }
        return normalized.url
    }

    private static let placeholderSerialNumber = "C02LKHBBFD57"

    private let session: URLSession
    private let sessionDelegate = AnisetteSessionDelegate()
    private let store = AnisetteIdentityStore()

    // Concurrent requests (e.g. several AltStore refreshes at once) share one in-flight fetch,
    // which also prevents two provisioning sessions from racing to update Keychain.
    private var currentTask: Task<RemoteAnisetteData, Error>?

    private init()
    {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 90
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false

        self.session = URLSession(configuration: configuration, delegate: self.sessionDelegate, delegateQueue: nil)
    }

    func fetchAnisetteData() async throws -> RemoteAnisetteData
    {
        if let currentTask
        {
            return try await currentTask.value
        }

        let task = Task {
            try await self.fetchAnisetteDataFromAvailableServer()
        }

        self.currentTask = task
        defer { self.currentTask = nil }

        return try await task.value
    }

    func resync(sim: String) async throws -> RemoteAnisetteData
    {
        guard let serverURL = Self.configuredURL,
              let identity = try self.store.load(server: serverURL) else {
            throw WindowsAnisetteError.provisioningFailed
        }
        let (clientInfo, userAgent) = try await self.fetchClientInfo(from: serverURL)
        let headers = try await self.fetchHeaders(from: serverURL, identity: identity, sim: sim)
        guard case .headers(let machineID, let oneTimePassword, let routingInfo) = headers else {
            throw WindowsAnisetteError.invalidResponse
        }
        return RemoteAnisetteData(machineID: machineID, oneTimePassword: oneTimePassword,
                                  localUserID: identity.localUserID, routingInfo: routingInfo,
                                  deviceUniqueIdentifier: identity.deviceID,
                                  deviceSerialNumber: Self.placeholderSerialNumber,
                                  deviceDescription: clientInfo, userAgent: userAgent)
    }
}

private extension WindowsAnisetteProvider
{
    func fetchAnisetteDataFromAvailableServer() async throws -> RemoteAnisetteData
    {
        // Only the server explicitly selected in AutoSign is contacted.
        guard let serverURL = Self.configuredURL else { throw WindowsAnisetteError.notConfigured }
        return try await self.fetchAnisetteData(from: serverURL)
    }

    func fetchAnisetteData(from serverURL: URL) async throws -> RemoteAnisetteData
    {
        // 1. Fetch client_info from the server.
        let (clientInfo, userAgent) = try await self.fetchClientInfo(from: serverURL)

        // 2. Load or generate the persisted identity.
        var identity = try self.store.load(server: serverURL) ?? .make()
        identity.serverURL = serverURL
        try self.store.save(identity)

        // 3. Provision against this server if we don't have an adi.pb from it.
        if identity.adiPB == nil
        {

            identity.adiPB = try await self.provision(against: serverURL, clientInfo: clientInfo, userAgent: userAgent, identity: identity)
            identity.serverURL = serverURL
            try self.store.save(identity)
        }

        // 4. Fetch anisette headers, re-provisioning once if the server rejects our adi.pb.
        var headers = try await self.fetchHeaders(from: serverURL, identity: identity)

        if case .rejected(let message) = headers, message?.contains("-45061") == true
        {
            identity = .make()
            identity.serverURL = serverURL
            try self.store.save(identity)

            identity.adiPB = try await self.provision(against: serverURL, clientInfo: clientInfo, userAgent: userAgent, identity: identity)
            identity.serverURL = serverURL
            try self.store.save(identity)

            headers = try await self.fetchHeaders(from: serverURL, identity: identity)
        }

        guard case .headers(let machineID, let oneTimePassword, let routingInfo) = headers else {
            throw WindowsAnisetteError.invalidResponse
        }

        // 5. Assemble the result. deviceDescription and userAgent must be the server's, so they match the client that generated the anisette data.
        let anisetteData = RemoteAnisetteData(machineID: machineID,
                                              oneTimePassword: oneTimePassword,
                                              localUserID: identity.localUserID,
                                              routingInfo: routingInfo,
                                              deviceUniqueIdentifier: identity.deviceID,
                                              deviceSerialNumber: WindowsAnisetteProvider.placeholderSerialNumber,
                                              deviceDescription: clientInfo,
                                              userAgent: userAgent)
        return anisetteData
    }

    func fetchClientInfo(from serverURL: URL) async throws -> (clientInfo: String, userAgent: String)
    {
        struct Response: Decodable
        {
            var clientInfo: String
            var userAgent: String
        }

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase

        let clientInfoURL = serverURL.appending(components: "v3", "client_info")
        let response: Response = try await self.send(URLRequest(url: clientInfoURL), decoder: decoder, anisetteServerURL: serverURL)

        guard response.clientInfo.contains("<Windows;"),
              !response.clientInfo.contains("\r"), !response.clientInfo.contains("\n"),
              !response.userAgent.isEmpty, response.userAgent.count < 1024, response.clientInfo.count < 1024, !response.userAgent.contains("\r"), !response.userAgent.contains("\n")
        else { throw WindowsAnisetteError.invalidResponse }
        return (response.clientInfo, response.userAgent)
    }

    enum HeadersResult
    {
        case headers(machineID: String, oneTimePassword: String, routingInfo: UInt64)
        case rejected(message: String?)
    }

    func fetchHeaders(from serverURL: URL, identity: AnisetteIdentity, sim: String? = nil) async throws -> HeadersResult
    {
        guard let adiPB = identity.adiPB else { throw WindowsAnisetteError.provisioningFailed }

        struct Body: Encodable
        {
            var identifier: String
            var adi_pb: String
            var sim: String?
            var device_id: String?
            var md_lu: String?
        }

        struct Response: Decodable
        {
            var result: String?
            var message: String?
            var machineID: String?
            var oneTimePassword: String?
            var routingInfo: String?
            var adiPB: String?

            private enum CodingKeys: String, CodingKey
            {
                case result
                case message
                case machineID = "X-Apple-I-MD-M"
                case oneTimePassword = "X-Apple-I-MD"
                case routingInfo = "X-Apple-I-MD-RINFO"
                case adiPB = "adi_pb"
            }
        }

        var request = URLRequest(url: serverURL.appending(components: "v3", "get_headers"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(Body(identifier: identity.identifier, adi_pb: String(decoding: adiPB, as: UTF8.self), sim: sim, device_id: sim == nil ? nil : identity.deviceID, md_lu: sim == nil ? nil : identity.localUserID))

        let response: Response = try await self.send(request, decoder: JSONDecoder(), anisetteServerURL: serverURL)

        guard response.result != "GetHeadersError" else {
            return .rejected(message: response.message)
        }

        guard let machineID = response.machineID,
              !machineID.isEmpty, machineID.count < 8192,
              let oneTimePassword = response.oneTimePassword, !oneTimePassword.isEmpty, oneTimePassword.count < 8192,
              let routingInfoString = response.routingInfo,
              let routingInfo = UInt64(routingInfoString)
        else {
            throw WindowsAnisetteError.invalidResponse
        }

        if let blob = response.adiPB {
            guard Data(base64Encoded: blob) != nil else { throw WindowsAnisetteError.invalidResponse }
            var updated = identity
            updated.adiPB = Data(blob.utf8)
            try self.store.save(updated)
        }

        return .headers(machineID: machineID, oneTimePassword: oneTimePassword, routingInfo: routingInfo)
    }

    // Drives the v3 provisioning handshake: the server tells us what to ask Apple for, we relay
    // Apple's answers back over the socket, and the server returns the resulting adi.pb.
    func provision(against serverURL: URL, clientInfo: String, userAgent: String, identity: AnisetteIdentity) async throws -> Data
    {
        let jsonEncoder = JSONEncoder()
        let plistEncoder = PropertyListEncoder()
        plistEncoder.outputFormat = .xml

        // 1. Look up Apple's start/end provisioning URLs.
        struct LookupResponse: Decodable
        {
            var urls: URLs

            struct URLs: Decodable
            {
                var midStartProvisioning: String
                var midFinishProvisioning: String
            }
        }

        let lookupRequest = self.makeAppleRequest(for: .appleGSALookup, clientInfo: "<Mac15,7> <macOS;27.0;26A5378j> <com.apple.AuthKit/1 (com.apple.akd/1.0)>", userAgent: userAgent, identity: identity)
        let lookupResponse: LookupResponse = try await self.send(lookupRequest, decoder: PropertyListDecoder(), anisetteServerURL: nil)

        guard let startProvisioningURL = URL(string: lookupResponse.urls.midStartProvisioning),
              let endProvisioningURL = URL(string: lookupResponse.urls.midFinishProvisioning),
              self.isAppleProvisioningURL(startProvisioningURL), self.isAppleProvisioningURL(endProvisioningURL)
        else {
            throw WindowsAnisetteError.provisioningFailed
        }

        // 2. Open a WebSocket session with the anisette server.
        var socketComponents = URLComponents(url: serverURL.appending(components: "v3", "provisioning_session"), resolvingAgainstBaseURL: false)!
        socketComponents.scheme = serverURL.scheme == "https" ? "wss" : "ws"
        guard let socketURL = socketComponents.url else { throw WindowsAnisetteError.invalidResponse }
        var socketRequest = URLRequest(url: socketURL)
        socketRequest.timeoutInterval = 30

        let socket = self.session.webSocketTask(with: socketRequest)
        socket.resume()

        let timeout = Task {
            do { try await Task.sleep(for: .seconds(90)) } catch { return }
            socket.cancel(with: .goingAway, reason: nil)
        }
        defer { timeout.cancel(); socket.cancel(with: .normalClosure, reason: nil) }

        struct Message: Decodable
        {
            var result: String
            var message: String?
            var cpim: String?
            var adi_pb: String?
        }

        func sendJSON<T: Encodable>(_ value: T) async throws
        {
            let data = try jsonEncoder.encode(value)
            try await socket.send(.string(String(decoding: data, as: UTF8.self)))
        }

        // 3. Respond to each server prompt until ProvisioningSuccess.
        var expected = "GiveIdentifier"
        for _ in 0..<4
        {
            let socketMessage = try await socket.receive()

            guard case .string(let text) = socketMessage else {
                throw WindowsAnisetteError.invalidResponse
            }

            guard text.utf8.count < 1_048_576 else { throw WindowsAnisetteError.invalidResponse }
            let message: Message
            do
            {
                message = try JSONDecoder().decode(Message.self, from: Data(text.utf8))
            }
            catch
            {
                throw WindowsAnisetteError.invalidResponse
            }

            guard message.result == expected else { throw WindowsAnisetteError.invalidResponse }
            switch message.result
            {
            case "GiveIdentifier":
                struct IdentifierMessage: Encodable
                {
                    var identifier: String
                }

                try await sendJSON(IdentifierMessage(identifier: identity.identifier))
                expected = "GiveStartProvisioningData"

            case "GiveStartProvisioningData":
                struct Body: Encodable
                {
                    var Header: [String: String] = [:]
                    var Request: [String: String] = [:]
                }

                struct StartMessage: Codable
                {
                    var spim: String
                }

                struct Response: Decodable
                {
                    var Response: StartMessage
                }

                var startRequest = self.makeAppleRequest(for: startProvisioningURL, clientInfo: clientInfo, userAgent: userAgent, identity: identity)
                startRequest.httpMethod = "POST"
                startRequest.httpBody = try plistEncoder.encode(Body())

                let startResponse: Response = try await self.send(startRequest, decoder: PropertyListDecoder(), anisetteServerURL: nil)
                try await sendJSON(StartMessage(spim: startResponse.Response.spim))
                expected = "GiveEndProvisioningData"

            case "GiveEndProvisioningData":
                guard let cpim = message.cpim else {
                    throw WindowsAnisetteError.invalidResponse
                }

                struct Body: Encodable
                {
                    var Header: [String: String] = [:]
                    var Request: Request

                    struct Request: Encodable
                    {
                        var cpim: String
                    }
                }

                struct Response: Decodable
                {
                    var Response: WindowsProvisioningFinish
                }

                var endRequest = self.makeAppleRequest(for: endProvisioningURL, clientInfo: clientInfo, userAgent: userAgent, identity: identity)
                endRequest.httpMethod = "POST"
                endRequest.httpBody = try plistEncoder.encode(Body(Request: .init(cpim: cpim)))

                var headerRouting: String?
                let endResponse: Response = try await self.send(endRequest, decoder: PropertyListDecoder(), anisetteServerURL: nil,
                    received: { headerRouting = $0.value(forHTTPHeaderField: "X-Apple-I-MD-RINFO") })
                var end = endResponse.Response
                if end.routingInfo == nil { end.routingInfo = headerRouting }
                try await sendJSON(end)
                expected = "ProvisioningSuccess"

            case "ProvisioningSuccess":
                guard let adiPB = message.adi_pb, Data(base64Encoded: adiPB) != nil else {
                    throw WindowsAnisetteError.invalidResponse
                }

                return Data(adiPB.utf8)

            default:
                // Unknown results are fatal: we don't know whether it's safe to keep going.
                throw WindowsAnisetteError.invalidResponse
            }
        }
        throw WindowsAnisetteError.provisioningFailed
    }
}

private extension WindowsAnisetteProvider
{
    func send<T: Decodable, Decoder: TopLevelDecoder>(_ request: URLRequest, decoder: Decoder, anisetteServerURL: URL?,
                                                    received: ((HTTPURLResponse) -> Void)? = nil) async throws -> T where Decoder.Input == Data
    {
        let data: Data
        let urlResponse: URLResponse

        do
        {
            (data, urlResponse) = try await self.session.data(for: request)
        }
        catch is URLError where anisetteServerURL != nil
        {
            throw WindowsAnisetteError.unavailable
        }

        if let httpResponse = urlResponse as? HTTPURLResponse, httpResponse.statusCode != 200
        {

            if anisetteServerURL != nil
            {
                throw WindowsAnisetteError.unavailable
            }

            throw WindowsAnisetteError.provisioningFailed
        }

        guard data.count < 1_048_576 else { throw WindowsAnisetteError.invalidResponse }
        if let response = urlResponse as? HTTPURLResponse { received?(response) }
        do
        {
            return try decoder.decode(T.self, from: data)
        }
        catch
        {
            if anisetteServerURL != nil
            {
                throw WindowsAnisetteError.invalidResponse
            }

            throw WindowsAnisetteError.provisioningFailed
        }
    }

    func makeAppleRequest(for url: URL, clientInfo: String, userAgent: String, identity: AnisetteIdentity) -> URLRequest
    {
        var request = URLRequest(url: url)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("text/x-xml-plist", forHTTPHeaderField: "Content-Type")
        request.setValue("text/x-xml-plist", forHTTPHeaderField: "Accept")
        request.setValue("27.0 (27A5218g)", forHTTPHeaderField: "X-Xcode-Version")
        request.setValue("com.apple.gs.xcode.auth", forHTTPHeaderField: "X-Apple-App-Info")
        request.setValue("close", forHTTPHeaderField: "Connection")
        request.setValue(clientInfo, forHTTPHeaderField: "X-Mme-Client-Info")
        request.setValue(identity.localUserID, forHTTPHeaderField: "X-Apple-I-MD-LU")
        request.setValue(identity.deviceID, forHTTPHeaderField: "X-Mme-Device-Id")
        request.setValue(Locale.current.identifier, forHTTPHeaderField: "X-Apple-Locale")
        request.setValue(TimeZone.current.abbreviation(), forHTTPHeaderField: "X-Apple-I-TimeZone")
        request.setValue(ISO8601DateFormatter().string(from: Date()), forHTTPHeaderField: "X-Apple-I-Client-Time")
        return request
    }

    func isAppleProvisioningURL(_ url: URL) -> Bool
    {
        return url.scheme == "https" && url.host == "gsa.apple.com" &&
               (url.port == nil || url.port == 443) && url.user == nil && url.password == nil
    }

}
