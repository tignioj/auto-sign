import Foundation
import Testing
@testable import AutoSign

@Test @MainActor func uploadedIPARequiresAValidApplicationBeforeProvisioning() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let ipa = folder.appendingPathComponent("input.ipa")
    try Data("not an IPA".utf8).write(to: ipa)
    let suite = "AutoSignTests.UploadedIPA.\(UUID().uuidString)"
    let preferences = try #require(UserDefaults(suiteName: suite))
    defer { preferences.removePersistentDomain(forName: suite) }
    await #expect(throws: AppSourceError.self) {
        try await StoreInstallService.installUploadedIPA(at: ipa, deviceUDID: "test-phone", preferences: preferences) { _ in }
    }

    let payload = folder.appendingPathComponent("Payload")
    let app = payload.appendingPathComponent("Demo.app")
    try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
    let plist = try PropertyListSerialization.data(fromPropertyList: ["CFBundleName": "Demo"], format: .binary, options: 0)
    try plist.write(to: app.appendingPathComponent("Info.plist"))
    try FileManager.default.removeItem(at: ipa)
    _ = try await ProcessRunner.checked("/usr/bin/ditto", ["-c", "-k", "--keepParent", payload.path, ipa.path], context: "test IPA")
    await #expect(throws: AppSourceError.self) {
        try await StoreInstallService.installUploadedIPA(at: ipa, deviceUDID: "test-phone", preferences: preferences) { _ in }
    }
}
