import AutoSignLocalization
import CryptoKit
import Foundation
import Network
import Testing
@testable import AutoSign

@Test @MainActor func parsesFragmentedAuthenticatedRequests() throws {
    let body = Data(#"{"appIDs":["app"]}"#.utf8)
    let header = Data("POST /v1/refresh HTTP/1.1\r\nHost: Mac.local\r\nAuthorization: Bearer abc\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\n\r\n".utf8)
    let reader = StoreHTTPRequestReader()
    let authorize: (StoreHTTPRequest) -> Void = { _ in Issue.record("Ordinary requests never create upload files") }
    #expect(try reader.append(header.prefix(20), authorizeUpload: authorize) == nil)
    #expect(try reader.append(header.dropFirst(20) + body.prefix(2), authorizeUpload: authorize) == nil)
    let request = try #require(try reader.append(body.dropFirst(2), authorizeUpload: authorize))
    #expect(request.method == "POST")
    #expect(request.headers["authorization"] == "Bearer abc")
    #expect(request.body == body)
}

@Test @MainActor func rejectsAmbiguousOrOversizedHTTPRequestFraming() {
    let invalid = [
        "POST / HTTP/1.1\r\nContent-Length: -1\r\n\r\n",
        "POST /v1/refresh HTTP/1.1\r\nContent-Length: 65536\r\n\r\n",
        "POST /v1/install/ipa HTTP/1.1\r\nContent-Length: 4294967297\r\n\r\n",
        "POST /v1/install/ipa HTTP/1.1\r\nContent-Type: application/octet-stream\r\n\r\n",
        "POST /v1/install/ipa HTTP/1.1\r\nContent-Length: 5\r\nContent-Type: application/json\r\n\r\n",
        "POST / HTTP/1.1\r\nContent-Length: 1\r\nContent-Length: 2\r\n\r\na",
        "GET / HTTP/1.1\r\nAuthorization: a\r\nAuthorization: b\r\n\r\n",
        "POST / HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n",
        "POST / HTTP/1.1\r\nContent-Length: 99999999999999999999999999\r\n\r\n",
        "GET / HTTP/1.1\r\nBad header\r\n\r\n",
        "GET / HTTP/1.1\r\n\r\nGET / HTTP/1.1\r\n\r\n"
    ]
    for value in invalid {
        #expect(throws: StoreHTTPError.self) { try StoreHTTPRequestReader().append(Data(value.utf8)) { _ in } }
    }
    #expect(throws: StoreHTTPError.self) { try StoreHTTPRequestReader().append(Data(repeating: 65, count: StoreHTTPRequest.maximumBytes + 1)) { _ in } }
}

@Test @MainActor func incompleteUploadsAreRemovedAndRequireAuthenticationBeforeCreatingFiles() throws {
    let header = Data("POST /v1/install/ipa HTTP/1.1\r\nContent-Type: application/octet-stream\r\nContent-Length: 8\r\n\r\n".utf8)
    let denied = StoreHTTPRequestReader()
    #expect(throws: StoreHTTPError.self) {
        try denied.append(header) { _ in throw StoreHTTPError(status: 401, message: "denied") }
    }
    #expect(denied.upload == nil)
    let path: URL
    do {
        let reader = StoreHTTPRequestReader()
        #expect(try reader.append(header + Data([1, 2])) { _ in } == nil)
        path = try #require(reader.upload?.fileURL)
        #expect(try Data(contentsOf: path) == Data([1, 2]))
        #expect(throws: StoreHTTPError.self) { try reader.append(Data(repeating: 3, count: 7)) { _ in } }
    }
    #expect(!FileManager.default.fileExists(atPath: path.path))
}

private func storeRecord(_ id: String, device: String = "phone", isStore: Bool = false) -> StoreRecord {
    StoreRecord(app: StoreApp(id: id, deviceUDID: device, name: id, bundleIdentifier: "app.\(id)", version: "1",
        expiration: Date().addingTimeInterval(3600), refreshedAt: Date(), isStore: isStore),
        ipaPath: "/unused.ipa", profilePath: "/unused.mobileprovision", identityID: "unused")
}

@Test func selfRefreshRunsLastAndRetryIsIdempotentEvenWhileBusy() throws {
    let records = [storeRecord("store", isStore: true), storeRecord("a"), storeRecord("b")]
    let request = RefreshRequest(requestID: UUID().uuidString, deviceUDID: "phone", appIDs: ["store", "b", "a"])
    let plan = try StoreJobPlanner.plan(request, records: records, jobs: [], isBusy: false)
    #expect(plan.records.map(\.app.id) == ["b", "a", "store"])
    #expect(plan.job.items.map(\.id) == ["b", "a", "store"])
    let retry = try StoreJobPlanner.plan(request, records: records, jobs: [plan.job], isBusy: true)
    #expect(retry.isExisting)
    #expect(retry.job.id == plan.job.id)
    #expect(retry.records.isEmpty)
}

@Test func refreshRejectsOtherDevicesDuplicatesAndRequestIDCollisions() throws {
    let records = [storeRecord("a"), storeRecord("b", device: "ipad")]
    let id = UUID().uuidString
    let original = RefreshRequest(requestID: id, deviceUDID: "phone", appIDs: ["a"])
    let plan = try StoreJobPlanner.plan(original, records: records, jobs: [], isBusy: false)
    let invalid = [
        RefreshRequest(requestID: UUID().uuidString, deviceUDID: "phone", appIDs: ["b"]),
        RefreshRequest(requestID: UUID().uuidString, deviceUDID: "phone", appIDs: ["a", "a"]),
        RefreshRequest(requestID: UUID().uuidString, deviceUDID: "phone", appIDs: []),
        RefreshRequest(requestID: id, deviceUDID: "ipad", appIDs: ["a"]),
        RefreshRequest(requestID: "invalid", deviceUDID: "phone", appIDs: ["a"])
    ]
    for request in invalid {
        #expect(throws: StoreHTTPError.self) { try StoreJobPlanner.plan(request, records: records, jobs: [plan.job], isBusy: false) }
    }
    #expect(throws: StoreHTTPError.self) {
        try StoreJobPlanner.plan(RefreshRequest(requestID: UUID().uuidString, deviceUDID: "phone", appIDs: ["a"]), records: records, jobs: [], isBusy: true)
    }
}

@Test func serverRestartPreservesCompletedAppsAndFailsUnfinishedItems() throws {
    let expiry = Date(timeIntervalSince1970: 2_000_000)
    let job = RefreshJob(id: UUID().uuidString, requestID: UUID().uuidString, deviceUDID: "phone", state: .running,
        items: [RefreshItem(id: "a", name: "A", state: .completed, message: "ok", expiration: expiry),
                RefreshItem(id: "store", name: "Store", state: .running, message: "installing")],
        createdAt: Date(), updatedAt: Date())
    let recovered = try #require(StoreJobPlanner.recoverInterrupted([job]).first)
    #expect(recovered.state == .failed)
    #expect(recovered.items[0].state == .completed)
    #expect(recovered.items[0].expiration == expiry)
    #expect(recovered.items[1].state == .failed)
    #expect(recovered.items[1].expiration == nil)
    let roundTrip = try StoreJSON.decoder().decode(RefreshJob.self, from: StoreJSON.encoder().encode(recovered))
    #expect(roundTrip.items[0].expiration == expiry)
}

@MainActor
final class HTTPHarness {
    var connections: [UUID: StoreHTTPConnection] = [:]
    var upload: StoreIPAUpload?
    let listener: NWListener
    init(router: StoreServer? = nil) throws {
        listener = try NWListener(using: .tcp, on: .any)
        listener.newConnectionHandler = { [weak self] connection in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let router { router.accept(connection); return }
                let id = UUID()
                let client = StoreHTTPConnection(connection: connection, authorizeUpload: { request in
                    guard request.headers["authorization"] == "Bearer test-token" else {
                        throw StoreHTTPError(status: 401, message: "Unauthorized")
                    }
                }, handler: { [weak self] request in
                    if let upload = request.upload {
                        #expect(request.body.isEmpty)
                        self?.upload = upload
                        return try! .json(["sha256": upload.sha256], status: 202)
                    }
                    guard request.headers["authorization"] == "Bearer test-token" else { return .error(401, L10n.tr("配对密钥无效。")) }
                    return try! .json(StoreSnapshot(protocolVersion: 1, serverName: "Test Mac", devices: [], apps: [], recentJobs: []))
                }, onClose: { [weak self] in self?.connections.removeValue(forKey: id) })
                self.connections[id] = client
                client.start()
            }
        }
    }
    func start() async throws -> UInt16 {
        try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { [listener] state in
                switch state {
                case .ready: continuation.resume(returning: listener.port!.rawValue)
                case .failed(let error): continuation.resume(throwing: error)
                default: break
                }
            }
            listener.start(queue: .main)
        }
    }
    func stop() {
        listener.cancel()
        for connection in Array(connections.values) { connection.close() }
    }
}

@Test @MainActor func realTCPTransportRequiresAuthAndReturnsJSON() async throws {
    let server = try HTTPHarness()
    let port = try await server.start()
    defer { server.stop() }
    let url = try #require(URL(string: "http://127.0.0.1:\(port)/v1/status"))
    let (_, denied) = try await URLSession.shared.data(from: url)
    #expect((denied as? HTTPURLResponse)?.statusCode == 401)
    var request = URLRequest(url: url)
    request.setValue("Bearer test-token", forHTTPHeaderField: "Authorization")
    let (data, response) = try await URLSession.shared.data(for: request)
    #expect((response as? HTTPURLResponse)?.statusCode == 200)
    #expect((response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Cache-Control") == "no-store")
    #expect(try StoreJSON.decoder().decode(StoreSnapshot.self, from: data).serverName == "Test Mac")
}

@Test @MainActor func realTCPTransportStreamsAnUploadFromFileAndPreservesWorkerOwnership() async throws {
    let server = try HTTPHarness()
    let port = try await server.start()
    defer { server.stop() }
    let input = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: input) }
    let body = Data(repeating: 0x35, count: 350_031)
    try body.write(to: input)
    var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/install/ipa")!)
    request.httpMethod = "POST"
    request.setValue("Bearer test-token", forHTTPHeaderField: "Authorization")
    request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
    let (data, response) = try await URLSession.shared.upload(for: request, fromFile: input)
    #expect((response as? HTTPURLResponse)?.statusCode == 202)
    let digest = SHA256.hash(data: body).map { String(format: "%02x", $0) }.joined()
    #expect(try JSONDecoder().decode([String: String].self, from: data)["sha256"] == digest)
    server.stop()
    let parsedFile = try #require(server.upload?.fileURL)
    #expect(try Data(contentsOf: parsedFile) == body)
    #expect(server.upload?.byteCount == body.count)
    server.upload = nil
    #expect(!FileManager.default.fileExists(atPath: parsedFile.path))
}

@Test func renewalUsesCertificateActuallyIncludedInNewProfile() {
    var profile = ProvisioningProfile(name: "test", uuid: "test", expirationDate: Date().addingTimeInterval(3600),
        applicationIdentifier: "TEAM.app.test", teamIdentifier: "TEAM", provisionedDevices: ["phone"],
        provisionsAllDevices: false, entitlements: [:])
    profile.signingCertificateHashes = ["NEW-CERT"]
    let old = SigningIdentity(hash: "OLD-CERT", name: "Apple Development (TEAM)")
    let renewed = SigningIdentity(hash: "NEW-CERT", name: "Apple Development (TEAM)")
    let other = SigningIdentity(hash: "OTHER", name: "Apple Development (OTHER)")
    #expect(SigningService.identity(for: profile, available: [old, other, renewed], preferredID: old.id)?.id == renewed.id)
    #expect(SigningService.identity(for: profile, available: [old, other], preferredID: old.id) == nil)
}

@Test @MainActor func productionRouterRejectsUnauthorizedAndMalformedRequests() async throws {
    let suite = "AutoSignTests.LANAuth.\(UUID().uuidString)"
    let preferences = try #require(UserDefaults(suiteName: suite))
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer {
        preferences.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: folder)
    }
    let server = StoreServer(preferences: preferences, jobsDirectory: folder)
    let denied = await server.handle(StoreHTTPRequest(method: "GET", path: "/v1/status", headers: [:], body: Data()))
    #expect(denied.status == 401)
    let token = server.token
    let headers = ["authorization": "Bearer \(token)", "content-type": "application/json"]
    let invalid = await server.handle(StoreHTTPRequest(method: "POST", path: "/v1/refresh", headers: headers, body: Data("{}".utf8)))
    #expect(invalid.status == 400)
    let missing = await server.handle(StoreHTTPRequest(method: "GET", path: "/v1/jobs/unknown", headers: headers, body: Data()))
    #expect(missing.status == 404)
    server.rotateToken()
    #expect(server.token != token)
    let revoked = await server.handle(StoreHTTPRequest(method: "GET", path: "/v1/status", headers: headers, body: Data()))
    #expect(revoked.status == 401)
    #expect(!server.isEnabled)
}
