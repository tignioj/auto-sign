import Foundation
import Darwin

struct RemoteFailure: Error {
    let kind: String
    let message: String
    init(_ message: String, kind: String = "unavailable") { self.kind = kind; self.message = message }
}

// The RSD control channel uses HTTP/2 frames containing little-endian XPC
// objects. This codec deliberately supports data values, never Mach handles.
enum XPCWire {
    static let limit = 4 * 1024 * 1024

    static func integer(_ value: UInt64, bytes: Int) -> Data {
        Data((0..<bytes).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) })
    }

    static func padded(_ data: Data) -> Data {
        data + Data(repeating: 0, count: (4 - data.count % 4) % 4)
    }

    static func encode(_ value: Any, depth: Int = 0) throws -> Data {
        guard depth < 32 else { throw RemoteFailure("RemoteXPC 数据嵌套过深。") }
        func tag(_ type: UInt64, _ body: Data = Data()) -> Data { integer(type, bytes: 4) + body }
        if let value = value as? String {
            let bytes = Data(value.utf8) + Data([0])
            return tag(0x9000, padded(integer(UInt64(bytes.count), bytes: 4) + bytes))
        }
        if let value = value as? UUID {
            var bytes = value.uuid
            return tag(0xa000, withUnsafeBytes(of: &bytes) { Data($0) })
        }
        if let value = value as? NSNumber {
            if CFGetTypeID(value) == CFBooleanGetTypeID() {
                return tag(0x2000, integer(value.boolValue ? 1 : 0, bytes: 4))
            }
            return tag(0x4000, integer(value.uint64Value, bytes: 8))
        }
        if let value = value as? [String: Any] {
            var body = integer(UInt64(value.count), bytes: 4)
            for key in value.keys.sorted() {
                guard !key.utf8.contains(0) else { throw RemoteFailure("RemoteXPC 字段名称无效。") }
                body += padded(Data(key.utf8) + Data([0]))
                body += try encode(value[key]!, depth: depth + 1)
            }
            return tag(0xf000, integer(UInt64(body.count), bytes: 4) + body)
        }
        throw RemoteFailure("不支持的 RemoteXPC 请求数据类型。")
    }

    static func message(_ dictionary: [String: Any]?, flags: UInt64, id: UInt64 = 0) throws -> Data {
        var payload = Data()
        if let dictionary {
            payload = integer(0x42133742, bytes: 4) + integer(5, bytes: 4) + (try encode(dictionary))
        }
        return integer(0x29b00b92, bytes: 4) + integer(flags, bytes: 4)
            + integer(UInt64(payload.count), bytes: 8) + integer(id, bytes: 8) + payload
    }

    struct Reader {
        let data: Data
        var offset = 0

        mutating func take(_ count: Int) throws -> Data {
            guard count >= 0, count <= data.count - offset else { throw RemoteFailure("RemoteXPC 响应被截断。") }
            defer { offset += count }
            return data.subdata(in: offset..<(offset + count))
        }

        mutating func number(_ count: Int) throws -> UInt64 {
            try take(count).enumerated().reduce(0) { $0 | UInt64($1.element) << ($1.offset * 8) }
        }

        mutating func align() throws { _ = try take((4 - offset % 4) % 4) }

        mutating func string() throws -> String {
            guard let end = data[offset...].firstIndex(of: 0),
                  let value = String(data: data.subdata(in: offset..<end), encoding: .utf8) else {
                throw RemoteFailure("RemoteXPC 字符串格式无效。")
            }
            offset = end + 1
            try align()
            return value
        }

        mutating func object(depth: Int = 0) throws -> Any {
            guard depth < 32 else { throw RemoteFailure("RemoteXPC 响应嵌套过深。") }
            let type = try number(4)
            switch type {
            case 0x1000: return NSNull()
            case 0x2000: return try number(4) != 0
            case 0x3000: return NSNumber(value: Int64(bitPattern: try number(8)))
            case 0x4000, 0x7000: return NSNumber(value: try number(8))
            case 0x5000: return NSNumber(value: Double(bitPattern: try number(8)))
            case 0x8000, 0x9000:
                let length = try number(4)
                guard length <= UInt64(Self.maximumLength) else { throw RemoteFailure("RemoteXPC 数据过大。") }
                let bytes = try take(Int(length)); try align()
                if type == 0x8000 { return bytes }
                guard bytes.last == 0, let value = String(data: bytes.dropLast(), encoding: .utf8) else {
                    throw RemoteFailure("RemoteXPC 字符串格式无效。")
                }
                return value
            case 0xa000: return try take(16)
            case 0xe000, 0xf000:
                let length = try number(4)
                guard length >= 4, length <= UInt64(data.count - offset) else { throw RemoteFailure("RemoteXPC 容器长度无效。") }
                let end = offset + Int(length), count = try number(4)
                guard count <= 65_536 else { throw RemoteFailure("RemoteXPC 容器过大。") }
                var dictionary: [String: Any] = [:], array: [Any] = []
                for _ in 0..<count {
                    if type == 0xf000 {
                        let key = try string()
                        guard dictionary[key] == nil else { throw RemoteFailure("RemoteXPC 响应包含重复字段。") }
                        dictionary[key] = try object(depth: depth + 1)
                    } else { array.append(try object(depth: depth + 1)) }
                    guard offset <= end else { throw RemoteFailure("RemoteXPC 容器越界。") }
                }
                guard offset == end else { throw RemoteFailure("RemoteXPC 容器长度不匹配。") }
                return type == 0xf000 ? dictionary : array
            default: throw RemoteFailure("不支持的 RemoteXPC 响应类型：\(type)。", kind: "unsupported")
            }
        }
        private static let maximumLength = XPCWire.limit
    }

    static func decodeMessage(_ data: Data) throws -> [String: Any]? {
        guard data.count <= limit else { throw RemoteFailure("RemoteXPC 响应过大。") }
        var reader = Reader(data: data)
        guard try reader.number(4) == 0x29b00b92 else { throw RemoteFailure("RemoteXPC 响应标识错误。") }
        _ = try reader.number(4)
        let length = try reader.number(8)
        _ = try reader.number(8)
        guard length == UInt64(data.count - 24) else { throw RemoteFailure("RemoteXPC 消息长度不匹配。") }
        if length == 0 { return nil }
        guard try reader.number(4) == 0x42133742, try reader.number(4) == 5,
              let result = try reader.object() as? [String: Any], reader.offset == data.count else {
            throw RemoteFailure("RemoteXPC 消息格式不兼容。", kind: "unsupported")
        }
        return result
    }
}

final class RemoteSocket {
    let fd: Int32

    init(address: String, port: UInt16) throws {
        var endpoint = sockaddr_in6()
        endpoint.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
        endpoint.sin6_family = sa_family_t(AF_INET6)
        endpoint.sin6_port = port.bigEndian
        guard inet_pton(AF_INET6, address, &endpoint.sin6_addr) == 1 else { throw RemoteFailure("CoreDevice 地址无效。", kind: "invalid") }
        let descriptor = socket(AF_INET6, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw RemoteFailure("无法创建 CoreDevice 连接。") }
        var timeout = timeval(tv_sec: 5, tv_usec: 0), enabled: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size))
        let result = withUnsafePointer(to: &endpoint) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in6>.size)) }
        }
        if result != 0 {
            let message = String(cString: strerror(errno))
            Darwin.close(descriptor)
            throw RemoteFailure("CoreDevice 连接失败：\(message)")
        }
        fd = descriptor
    }
    deinit { Darwin.close(fd) }

    func read(_ count: Int) throws -> Data {
        guard count >= 0, count <= 32 * 1024 * 1024 else { throw RemoteFailure("设备响应大小无效。") }
        var bytes = [UInt8](repeating: 0, count: count), offset = 0
        while offset < count {
            let size = bytes.withUnsafeMutableBytes { Darwin.recv(fd, $0.baseAddress!.advanced(by: offset), count - offset, 0) }
            if size < 0 && errno == EINTR { continue }
            guard size > 0 else { throw RemoteFailure("CoreDevice 连接中断或读取超时，请重试。") }
            offset += size
        }
        return Data(bytes)
    }

    func write(_ data: Data) throws {
        var offset = 0
        while offset < data.count {
            let size = data.withUnsafeBytes { Darwin.send(fd, $0.baseAddress!.advanced(by: offset), data.count - offset, 0) }
            if size < 0 && errno == EINTR { continue }
            guard size > 0 else { throw RemoteFailure("CoreDevice 连接中断或写入超时，请重试。") }
            offset += size
        }
    }

    func plist(_ request: [String: Any]?) throws -> [String: Any] {
        if let request {
            let payload = try PropertyListSerialization.data(fromPropertyList: request, format: .xml, options: 0)
            var size = UInt32(payload.count).bigEndian
            try write(withUnsafeBytes(of: &size) { Data($0) } + payload)
        }
        let length = try read(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        guard let result = try PropertyListSerialization.propertyList(from: read(Int(length)), format: nil) as? [String: Any] else {
            throw RemoteFailure("设备没有返回有效的描述文件响应。")
        }
        return result
    }

    func frame(_ type: UInt8, flags: UInt8 = 0, stream: UInt32 = 0, data: Data = Data()) throws {
        var identifier = stream.bigEndian
        let header = Data([UInt8(truncatingIfNeeded: data.count >> 16), UInt8(truncatingIfNeeded: data.count >> 8),
                           UInt8(truncatingIfNeeded: data.count), type, flags]) + withUnsafeBytes(of: &identifier) { Data($0) }
        try write(header + data)
    }

    func peerInfo(hostID: UUID) throws -> [String: Any] {
        try write(Data("PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n".utf8))
        try frame(4, data: Data([0, 3, 0, 0, 0, 100, 0, 4, 0, 16, 0, 0]))
        try frame(8, data: Data([0, 16, 0, 0]))
        try frame(1, flags: 4, stream: 1)
        try frame(0, stream: 1, data: XPCWire.message([:], flags: 1))
        try frame(1, flags: 4, stream: 3)
        try frame(0, stream: 1, data: XPCWire.message(nil, flags: 0x201))
        try frame(0, stream: 3, data: XPCWire.message(nil, flags: 0x400001))
        let handshake: [String: Any] = ["MessageType": "Handshake", "MessagingProtocolVersion": NSNumber(value: 7),
            "UUID": hostID, "Properties": ["RemoteXPCVersionFlags": NSNumber(value: UInt64(0x0100000000000006)),
                                           "SensitivePropertiesVisible": true], "Services": [String: Any]()]
        var sentHandshake = false, pending: [UInt32: Data] = [:]
        for _ in 0..<512 {
            let header = [UInt8](try read(9))
            let length = Int(header[0]) << 16 | Int(header[1]) << 8 | Int(header[2])
            guard length <= XPCWire.limit else { throw RemoteFailure("RemoteXPC 帧过大。") }
            let type = header[3], flags = header[4]
            let stream = header[5...8].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) } & 0x7fffffff
            let payload = try read(length)
            if type == 7 || type == 3 { throw RemoteFailure("CoreDevice 发现连接被重置，请重试。") }
            if type == 4 && flags & 1 == 0 {
                try frame(4, flags: 1)
                if !sentHandshake {
                    try frame(0, stream: 1, data: XPCWire.message(handshake, flags: 0x101, id: 1))
                    sentHandshake = true
                }
            } else if type == 6 && flags & 1 == 0 { try frame(6, flags: 1, data: payload) }
            else if type == 0 {
                guard flags & 8 == 0 else { throw RemoteFailure("不支持的 RemoteXPC 填充帧。", kind: "unsupported") }
                pending[stream, default: Data()] += payload
                guard pending[stream]!.count <= XPCWire.limit else { throw RemoteFailure("RemoteXPC 响应过大。") }
                while let bytes = pending[stream], bytes.count >= 24 {
                    var reader = XPCWire.Reader(data: bytes, offset: 8)
                    let size = try reader.number(8)
                    guard size <= UInt64(XPCWire.limit - 24) else { throw RemoteFailure("RemoteXPC 消息过大。") }
                    let total = Int(size) + 24
                    if bytes.count < total { break }
                    let message = try XPCWire.decodeMessage(bytes.prefix(total))
                    pending[stream] = Data(bytes.dropFirst(total))
                    if let message, message["Services"] != nil, message["Properties"] != nil { return message }
                }
            }
        }
        throw RemoteFailure("CoreDevice 没有返回描述文件服务信息。")
    }
}
