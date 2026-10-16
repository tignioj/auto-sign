import AutoSignLocalization
import Foundation
import Network

struct StoreHTTPRequest: Sendable {
    let method: String
    let path: String
    let headers: [String: String]
    let body: Data

    static let maximumBytes = 65_536

    static func parse(_ data: Data) throws -> StoreHTTPRequest? {
        guard data.count <= maximumBytes else { throw StoreHTTPError(status: 413, message: L10n.tr("请求过大。")) }
        guard let boundary = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
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
        let rawLength = headers["content-length"] ?? "0"
        guard !rawLength.isEmpty, rawLength.allSatisfy({ $0.isASCII && $0.isNumber }),
              let length = Int(rawLength), length <= maximumBytes - boundary.upperBound else {
            throw StoreHTTPError(status: 413, message: L10n.tr("无效请求长度。"))
        }
        guard data.count >= boundary.upperBound + length else { return nil }
        guard data.count == boundary.upperBound + length else { throw StoreHTTPError(status: 400, message: L10n.tr("不支持流水线请求。")) }
        return StoreHTTPRequest(method: String(first[0]), path: String(first[1]), headers: headers,
                                body: Data(data[boundary.upperBound...]))
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
    private var buffer = Data()
    private var timeout: Task<Void, Never>?
    private var finished = false
    private let handler: @MainActor (StoreHTTPRequest) async -> StoreHTTPResponse
    private let onClose: @MainActor () -> Void

    init(connection: NWConnection, handler: @escaping @MainActor (StoreHTTPRequest) async -> StoreHTTPResponse,
         onClose: @escaping @MainActor () -> Void) {
        self.connection = connection
        self.handler = handler
        self.onClose = onClose
    }

    func start() {
        connection.start(queue: .main)
        timeout = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(75)) } catch { return }
            self?.close()
        }
        receive()
    }

    func close() {
        guard !finished else { return }
        finished = true
        timeout?.cancel()
        connection.cancel()
        onClose()
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, complete, error in
            Task { @MainActor [weak self] in
                guard let self, !self.finished else { return }
                if let data { self.buffer.append(data) }
                do {
                    if let request = try StoreHTTPRequest.parse(self.buffer) {
                        let response = await self.handler(request)
                        self.send(response)
                    } else if complete || error != nil { self.close() }
                    else { self.receive() }
                } catch let error as StoreHTTPError { self.send(.error(error.status, error.message)) }
                catch { self.send(.error(400, L10n.tr("无效请求。"))) }
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
