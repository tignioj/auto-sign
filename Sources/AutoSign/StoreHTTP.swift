import AutoSignLocalization
import CryptoKit
import Foundation
import Network

struct StoreHTTPRequest: Sendable {
    let method: String
    let path: String
    let headers: [String: String]
    let body: Data
    var upload: StoreIPAUpload?

    static let maximumBytes = 65_536
    static let maximumUploadBytes = 4 * 1024 * 1024 * 1024
    var isIPAUpload: Bool { method == "POST" && path == "/v1/install/ipa" }

    fileprivate static func parseHead(_ data: Data) throws -> (request: Self, offset: Int, length: Int)? {
        guard let boundary = data.range(of: Data("\r\n\r\n".utf8)) else {
            guard data.count < maximumBytes else { throw StoreHTTPError(status: 413, message: L10n.tr("请求过大。")) }
            return nil
        }
        guard boundary.upperBound <= maximumBytes else { throw StoreHTTPError(status: 413, message: L10n.tr("请求过大。")) }
        guard let text = String(data: data[..<boundary.lowerBound], encoding: .utf8) else {
            throw StoreHTTPError(status: 400, message: L10n.tr("无效请求头。"))
        }
        let lines = text.components(separatedBy: "\r\n")
        let first = (lines.first ?? "").split(separator: " ")
        guard first.count == 3, first[2] == "HTTP/1.1", first[1].hasPrefix("/") else {
            throw StoreHTTPError(status: 400, message: L10n.tr("无效 HTTP 请求。"))
        }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":"), colon != line.startIndex else {
                throw StoreHTTPError(status: 400, message: L10n.tr("无效请求头。"))
            }
            let key = line[..<colon].lowercased()
            guard headers[key] == nil else { throw StoreHTTPError(status: 400, message: L10n.tr("请求头重复。")) }
            headers[key] = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
        }
        guard headers["transfer-encoding"] == nil else { throw StoreHTTPError(status: 400, message: L10n.tr("不支持分块请求。")) }
        let request = Self(method: String(first[0]), path: String(first[1]), headers: headers, body: Data())
        let rawLength = headers["content-length"] ?? "0"
        let limit = request.isIPAUpload ? maximumUploadBytes : maximumBytes - boundary.upperBound
        guard !rawLength.isEmpty, rawLength.allSatisfy({ $0.isASCII && $0.isNumber }),
              let length = Int(rawLength), length <= limit else {
            throw StoreHTTPError(status: 413, message: L10n.tr("无效请求长度。"))
        }
        return (request, boundary.upperBound, length)
    }
}

/// The connection and then the installation worker retain this file for as long as they need it.
@MainActor
final class StoreIPAUpload {
    let fileURL: URL
    private let handle: FileHandle
    private var digest = SHA256()
    private(set) var byteCount = 0
    private(set) var sha256 = ""

    fileprivate init() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("AutoSign-upload-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        fileURL = directory.appendingPathComponent("input.ipa")
        do {
            try Data().write(to: fileURL, options: .withoutOverwriting)
            handle = try FileHandle(forWritingTo: fileURL)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    fileprivate func append(_ data: Data) throws {
        try handle.write(contentsOf: data)
        digest.update(data: data)
        byteCount += data.count
    }

    fileprivate func finish() throws {
        try handle.close()
        sha256 = digest.finalize().map { String(format: "%02x", $0) }.joined()
    }

    deinit { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }
}

@MainActor
final class StoreHTTPRequestReader {
    private var buffer = Data()
    private var head: StoreHTTPRequest?
    private var length = 0
    private(set) var upload: StoreIPAUpload?
    var expectsContinue: Bool { head?.headers["expect"]?.lowercased() == "100-continue" }

    func append(_ data: Data, authorizeUpload: (StoreHTTPRequest) throws -> Void) throws -> StoreHTTPRequest? {
        if let head { return try appendBody(data, to: head) }
        buffer.append(data)
        guard let parsed = try StoreHTTPRequest.parseHead(buffer) else { return nil }
        let request = parsed.request
        if request.isIPAUpload {
            try authorizeUpload(request)
            guard request.headers["content-type"]?.lowercased() == "application/octet-stream" else {
                throw StoreHTTPError(status: 415, message: L10n.tr("请使用二进制 IPA 请求。"))
            }
            guard parsed.length > 0 else { throw StoreHTTPError(status: 400, message: L10n.tr("无效请求长度。")) }
            upload = try StoreIPAUpload()
        }
        head = request
        length = parsed.length
        let body = buffer.suffix(from: parsed.offset)
        buffer = Data()
        return try appendBody(body, to: request)
    }

    private func appendBody(_ data: Data, to request: StoreHTTPRequest) throws -> StoreHTTPRequest? {
        let received = upload?.byteCount ?? buffer.count
        guard data.count <= length - received else {
            throw StoreHTTPError(status: 400, message: L10n.tr("不支持流水线请求。"))
        }
        if let upload {
            try upload.append(data)
            guard upload.byteCount == length else { return nil }
            try upload.finish()
            var completed = request
            completed.upload = upload
            return completed
        }
        buffer.append(data)
        guard buffer.count == length else { return nil }
        return StoreHTTPRequest(method: request.method, path: request.path, headers: request.headers, body: buffer)
    }
}

struct StoreHTTPError: LocalizedError {
    let status: Int
    let message: String
    var errorDescription: String? { message }
}

struct StoreHTTPResponse: Sendable {
    let status: Int
    let body: Data
    static func json<T: Encodable>(_ value: T, status: Int = 200) throws -> Self {
        Self(status: status, body: try StoreJSON.encoder().encode(value))
    }
    static func error(_ status: Int, _ message: String) -> Self {
        Self(status: status, body: (try? StoreJSON.encoder().encode(StoreAPIError(message: message))) ?? Data())
    }
}

@MainActor
final class StoreHTTPConnection {
    private let connection: NWConnection
    private var reader = StoreHTTPRequestReader()
    private var lastProgress = ContinuousClock.now
    private let authorizeUpload: @MainActor (StoreHTTPRequest) throws -> Void
    private var timeout: Task<Void, Never>?
    private var finished = false
    private let handler: @MainActor (StoreHTTPRequest) async -> StoreHTTPResponse
    private let onClose: @MainActor () -> Void

    init(connection: NWConnection,
         authorizeUpload: @escaping @MainActor (StoreHTTPRequest) throws -> Void = { _ in
             throw StoreHTTPError(status: 401, message: L10n.tr("配对密钥无效。"))
         },
         handler: @escaping @MainActor (StoreHTTPRequest) async -> StoreHTTPResponse,
         onClose: @escaping @MainActor () -> Void) {
        self.connection = connection
        self.authorizeUpload = authorizeUpload
        self.handler = handler
        self.onClose = onClose
    }

    func start() {
        connection.start(queue: .main)
        timeout = Task { [weak self] in
            while let progress = self?.lastProgress {
                do { try await Task.sleep(until: progress.advanced(by: .seconds(75)), clock: .continuous) }
                catch { return }
                if self?.lastProgress == progress { self?.close(); return }
            }
        }
        receive()
    }

    func close() {
        guard !finished else { return }
        finished = true
        timeout?.cancel()
        reader = StoreHTTPRequestReader()
        connection.cancel()
        onClose()
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 128 * 1024) { [weak self] data, _, complete, error in
            Task { @MainActor [weak self] in
                guard let self, !self.finished else { return }
                do {
                    let wasUploading = self.reader.upload != nil
                    let chunk = data ?? Data()
                    if let request = try self.reader.append(chunk, authorizeUpload: self.authorizeUpload) {
                        self.reader = StoreHTTPRequestReader()
                        let response = await self.handler(request)
                        self.send(response)
                    } else if complete || error != nil { self.close() }
                    else {
                        if self.reader.upload != nil, !chunk.isEmpty {
                            self.lastProgress = .now
                            if !wasUploading && self.reader.expectsContinue {
                                self.connection.send(content: Data("HTTP/1.1 100 Continue\r\n\r\n".utf8), completion: .idempotent)
                            }
                        }
                        self.receive()
                    }
                } catch let error as StoreHTTPError { self.send(.error(error.status, error.message)) }
                catch { self.send(.error(500, L10n.tr("无法保存上传的 IPA。"))) }
            }
        }
    }

    private func send(_ response: StoreHTTPResponse) {
        guard !finished else { return }
        let header = "HTTP/1.1 \(response.status) Response\r\nContent-Type: application/json; charset=utf-8\r\nContent-Length: \(response.body.count)\r\nConnection: close\r\nCache-Control: no-store\r\n\r\n"
        connection.send(content: Data(header.utf8) + response.body, completion: .contentProcessed { [weak self] _ in
            Task { @MainActor [weak self] in self?.close() }
        })
    }
}
