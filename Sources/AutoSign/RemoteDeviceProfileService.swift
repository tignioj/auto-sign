import Foundation
import Darwin

enum RemoteDeviceProfileService {
    struct Connection {
        let address: String
        let ports: [UInt16]
        let hostID: UUID
    }

    static func run(_ arguments: [String], on device: AppleDevice) async throws -> DeviceProfileService.Response {
        let sibling = Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("AutoSignRemoteHelper")
        let development = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/debug/AutoSignRemoteHelper")
        guard let helper = [sibling, development].compactMap({ $0 }).first(where: {
            FileManager.default.isExecutableFile(atPath: $0.path)
        }) else { throw ProfileRefreshError.deviceNotFound("缺少 CoreDevice 描述文件组件，请重新构建完整应用。") }
        for attempt in 0..<2 {
            try Task.checkCancellation()
            let connection = try await prepare(on: device)
            var lastError: Error = ProfileRefreshError.unavailable("CoreDevice 描述文件连接尚未就绪。")
            for port in connection.ports {
                let command = [arguments[0], device.udid, connection.address, String(port), connection.hostID.uuidString]
                    + arguments.dropFirst(2)
                do {
                    let result = try await ProcessRunner.run(helper.path, command)
                    try Task.checkCancellation()
                    return try DeviceProfileService.decodeResponse(result)
                } catch ProfileRefreshError.unavailable(let message) {
                    lastError = ProfileRefreshError.unavailable(message)
                }
            }
            if attempt == 1 { throw lastError }
            // remoted can redial after a tunnel reset; discover its current port
            // again rather than reusing a stale endpoint or reinstalling an app.
            try await Task.sleep(for: .milliseconds(500))
        }
        throw ProfileRefreshError.unavailable("CoreDevice 描述文件连接失败。")
    }

    private static func prepare(on device: AppleDevice) async throws -> Connection {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("autosign-remote-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        _ = try await ProcessRunner.checked("/usr/bin/xcrun", ["devicectl", "device", "info", "details", "--device", device.udid,
            "--timeout", "15", "--json-output", url.path, "--quiet"], context: "无法准备 CoreDevice 描述文件连接。")
        let address = try tunnelAddress(from: Data(contentsOf: url), expectedUDID: device.udid)
        async let sockets = ProcessRunner.run("/usr/bin/nettop", ["-n", "-x", "-L", "1", "-m", "tcp", "-J", "interface,state"])
        async let identity = ProcessRunner.run("/usr/libexec/remotectl", ["dumpstate"])
        let (socketResult, identityResult) = try await (sockets, identity)
        let ports = parsePorts(socketResult.output, address: address)
        guard socketResult.status == 0, identityResult.status == 0, !ports.isEmpty,
              let hostID = parseHostID(identityResult.output) else {
            throw ProfileRefreshError.unavailable("未找到此设备已配对的 CoreDevice 描述文件通道，请解锁设备后重试。")
        }
        return Connection(address: address, ports: ports, hostID: hostID)
    }

    static func tunnelAddress(from data: Data, expectedUDID: String) throws -> String {
        guard let device = try DeviceService.parseDeviceDetails(from: data), device.udid == expectedUDID,
              device.isReadyForInstallation,
              let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = root["result"] as? [String: Any], let connection = result["connectionProperties"] as? [String: Any],
              connection["pairingState"] as? String == "paired",
              let address = connection["tunnelIPAddress"] as? String, ipv6(address) != nil else {
            throw ProfileRefreshError.unavailable("CoreDevice 目标设备、配对状态或隧道地址无效，已停止操作。")
        }
        return address
    }

    static func parseHostID(_ text: String) -> UUID? {
        let lines = text.components(separatedBy: .newlines)
        guard let index = lines.firstIndex(of: "Local device"), index + 1 < lines.count else { return nil }
        let line = lines[index + 1].trimmingCharacters(in: .whitespaces)
        guard line.hasPrefix("UUID: ") else { return nil }
        return UUID(uuidString: String(line.dropFirst(6)))
    }

    static func parsePorts(_ text: String, address: String) -> [UInt16] {
        guard let target = ipv6(address) else { return [] }
        var remoted = false, ports: [UInt16] = []
        for line in text.components(separatedBy: .newlines) {
            let fields = line.components(separatedBy: ",")
            guard let first = fields.first else { continue }
            if !first.hasPrefix("tcp") {
                let parts = first.split(separator: ".")
                remoted = parts.count == 2 && parts[0] == "remoted" && Int(parts[1]) != nil
                continue
            }
            guard remoted, fields.count >= 3, fields[2] == "Established",
                  let endpoint = first.components(separatedBy: "<->").last,
                  let separator = endpoint.lastIndex(of: "."),
                  let port = UInt16(endpoint[endpoint.index(after: separator)...]), port > 0 else { continue }
            let foreign = String(endpoint[..<separator]).components(separatedBy: "%")[0]
            if ipv6(foreign) == target, !ports.contains(port) { ports.append(port) }
        }
        return ports
    }

    private static func ipv6(_ value: String) -> Data? {
        var address = in6_addr()
        guard inet_pton(AF_INET6, value, &address) == 1 else { return nil }
        return withUnsafeBytes(of: &address) { Data($0) }
    }
}
