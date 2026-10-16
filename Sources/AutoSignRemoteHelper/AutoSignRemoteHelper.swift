import AutoSignLocalization
import Foundation
import Darwin

@main
struct AutoSignRemoteHelper {
    static func main() {
        signal(SIGALRM) { _ in _exit(11) }
        alarm(30)
        var response: [String: Any]
        do {
            let args = CommandLine.arguments
            guard args.count == (args.dropFirst().first == "install" ? 7 : 6),
                  ["list", "install"].contains(args[1]), let port = UInt16(args[4]), port > 0,
                  let hostID = UUID(uuidString: args[5]) else { throw RemoteFailure(L10n.tr("CoreDevice 组件参数无效。"), kind: "invalid") }
            let control = try RemoteSocket(address: args[3], port: port)
            let peer = try control.peerInfo(hostID: hostID)
            guard let properties = peer["Properties"] as? [String: Any],
                  properties["UniqueDeviceID"] as? String == args[2] else {
                throw RemoteFailure(L10n.tr("CoreDevice 返回的设备标识与目标设备不一致，已停止操作。"), kind: "invalid")
            }
            guard let services = peer["Services"] as? [String: Any],
                  let misagent = services["com.apple.misagent.shim.remote"] as? [String: Any],
                  let portString = misagent["Port"].map({ String(describing: $0) }),
                  let servicePort = UInt16(portString), servicePort > 0 else {
                throw RemoteFailure(L10n.tr("此设备的 CoreDevice 连接不提供独立描述文件服务。"), kind: "unsupported")
            }
            let service = try RemoteSocket(address: args[3], port: servicePort)
            let checkin = try service.plist(["Label": "AutoSign", "ProtocolVersion": "2", "Request": "RSDCheckin"])
            let started = try service.plist(nil)
            guard checkin["Request"] as? String == "RSDCheckin", started["Request"] as? String == "StartService",
                  checkin["Error"] == nil, started["Error"] == nil else {
                throw RemoteFailure(L10n.tr("CoreDevice 描述文件服务未通过会话检查。"))
            }
            var request: [String: Any] = ["MessageType": "CopyAll", "ProfileType": "Provisioning"]
            if args[1] == "install" {
                let profile = try Data(contentsOf: URL(fileURLWithPath: args[6]))
                guard !profile.isEmpty, profile.count <= 16 * 1024 * 1024 else { throw RemoteFailure(L10n.tr("描述文件大小无效。"), kind: "invalid") }
                request["MessageType"] = "Install"
                request["Profile"] = profile
            }
            let result = try service.plist(request)
            guard let status = result["Status"] as? NSNumber else { throw RemoteFailure(L10n.tr("描述文件服务响应格式不兼容。"), kind: "unsupported") }
            guard status.int64Value == 0 else {
                throw RemoteFailure(L10n.tr("设备拒绝描述文件请求，状态：\(status)。"), kind: status.uint32Value == 0xe8008024 ? "invalid" : "rejected")
            }
            response = ["kind": "success", "transport": "coreDevice"]
            if args[1] == "list" {
                guard let profiles = result["Payload"] as? [Data] else { throw RemoteFailure(L10n.tr("设备未返回有效的描述文件列表。"), kind: "unsupported") }
                response["profiles"] = profiles.map { $0.base64EncodedString() }
            }
            withExtendedLifetime(control) {}
        } catch let failure as RemoteFailure { response = ["kind": failure.kind, "message": failure.message] }
          catch { response = ["kind": "unavailable", "message": error.localizedDescription] }
        if let data = try? JSONSerialization.data(withJSONObject: response) {
            FileHandle.standardOutput.write(data + Data([10]))
        }
        exit(response["kind"] as? String == "success" ? 0 : 11)
    }
}
