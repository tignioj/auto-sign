import Foundation
import Testing
@testable import AutoSign

private func storeInfo(at bundle: URL) throws -> [String: Any] {
    try #require(PropertyListSerialization.propertyList(
        from: Data(contentsOf: bundle.appendingPathComponent("Info.plist")), format: nil) as? [String: Any])
}

@Test func storeInstallationBindsEachSignedCopyWithoutChangingTheOriginalPackage() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let original = folder.appendingPathComponent("Original.app")
    try FileManager.default.createDirectory(at: original, withIntermediateDirectories: true)
    let info: [String: Any] = ["AutoSignStoreClient": true, "CFBundleIdentifier": "local.autosign.store",
                               "CFBundleVersion": "8", "NSBonjourServices": ["_autosign._tcp"]]
    let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
    try data.write(to: original.appendingPathComponent("Info.plist"))
    for device in ["00008101-000111222333444A", "00008101-000111222333444B"] {
        let copy = folder.appendingPathComponent("\(device).app")
        try FileManager.default.copyItem(at: original, to: copy)
        try SigningService.writeStoreDeviceBinding(at: copy, deviceUDID: device)
        let signedInfo = try storeInfo(at: copy)
        #expect(signedInfo["AutoSignStoreDeviceUDID"] as? String == device)
        #expect(signedInfo["CFBundleIdentifier"] as? String == info["CFBundleIdentifier"] as? String)
        #expect(signedInfo["CFBundleVersion"] as? String == "8")
        #expect(signedInfo["NSBonjourServices"] as? [String] == ["_autosign._tcp"])
        // Refreshes reuse the original IPA. Reused signed IPAs must also replace
        // stale bindings with the current installation target before signing.
        try SigningService.writeStoreDeviceBinding(at: copy, deviceUDID: device)
        #expect(try storeInfo(at: copy)["AutoSignStoreDeviceUDID"] as? String == device)
        try SigningService.writeStoreDeviceBinding(at: copy, deviceUDID: "another-device")
        #expect(try storeInfo(at: copy)["AutoSignStoreDeviceUDID"] as? String == "another-device")
    }
    #expect(try Data(contentsOf: original.appendingPathComponent("Info.plist")) == data)
}

@Test func installationDoesNotAddBindingsToOtherApplications() throws {
    let bundle = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).app")
    defer { try? FileManager.default.removeItem(at: bundle) }
    try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
    for marker in [false, true] {
        var info: [String: Any] = ["CFBundleIdentifier": "com.example.other"]
        if marker { info["AutoSignStoreClient"] = false }
        let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try data.write(to: bundle.appendingPathComponent("Info.plist"))
        try SigningService.writeStoreDeviceBinding(at: bundle, deviceUDID: "phone")
        #expect(try Data(contentsOf: bundle.appendingPathComponent("Info.plist")) == data)
    }
}
