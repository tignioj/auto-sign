import Darwin
import Foundation
import Testing
@testable import AutoSign

private func instanceTestDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("AutoSignInstanceTests-\(UUID())")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@Test func instanceLockRejectsDuplicatesWithoutChangingOwner() throws {
    let directory = try instanceTestDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = ApplicationInstanceRole.interface.lockURL(in: directory)
    let owner = try #require(try ProcessInstanceLock(url: url))
    defer { withExtendedLifetime(owner) {} }
    let metadata = try Data(contentsOf: url)
    #expect(try ProcessInstanceLock(url: url) == nil)
    #expect(ProcessInstanceLock.ownerProcessID(at: url) == getpid())
    #expect(try Data(contentsOf: url) == metadata)
}

@Test func instanceLockCanRestartAfterReleaseAndIgnoresStalePID() throws {
    let directory = try instanceTestDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = ApplicationInstanceRole.interface.lockURL(in: directory)
    try "999999\n".write(to: url, atomically: true, encoding: .utf8)
    do {
        let first = try #require(try ProcessInstanceLock(url: url))
        withExtendedLifetime(first) { #expect(ProcessInstanceLock.ownerProcessID(at: url) == getpid()) }
    }
    #expect(FileManager.default.fileExists(atPath: url.path))
    let restarted = try #require(try ProcessInstanceLock(url: url))
    withExtendedLifetime(restarted) { #expect(ProcessInstanceLock.ownerProcessID(at: url) == getpid()) }
}

@Test func interfaceAndBackgroundCanRunTogetherButEachHasOneOwner() throws {
    let directory = try instanceTestDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let interfaceURL = ApplicationInstanceRole.interface.lockURL(in: directory)
    let backgroundURL = ApplicationInstanceRole.backgroundRefresh.lockURL(in: directory)
    let interface = try #require(try ProcessInstanceLock(url: interfaceURL))
    let background = try #require(try ProcessInstanceLock(url: backgroundURL))
    defer { withExtendedLifetime((interface, background)) {} }
    #expect(try ProcessInstanceLock(url: interfaceURL) == nil)
    #expect(try ProcessInstanceLock(url: backgroundURL) == nil)
}

@Test func instanceLockFailsClosedForUnwritableLocationsAndSymlinks() throws {
    let directory = try instanceTestDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let invalidParent = directory.appendingPathComponent("file")
    try Data().write(to: invalidParent)
    #expect(throws: (any Error).self) { try ProcessInstanceLock(url: invalidParent.appendingPathComponent("interface.lock")) }
    let target = directory.appendingPathComponent("target")
    try "preserve".write(to: target, atomically: true, encoding: .utf8)
    let link = directory.appendingPathComponent("interface.lock")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
    #expect(throws: (any Error).self) { try ProcessInstanceLock(url: link) }
    #expect(try String(contentsOf: target, encoding: .utf8) == "preserve")
}

@Test func launchModesKeepScheduledRefreshSeparateAndProtectInstaller() {
    #expect(LaunchMode(arguments: ["AutoSign"]) == .interface)
    #expect(LaunchMode(arguments: ["AutoSign", "-AppleLanguages", "(en)"]) == .interface)
    #expect(LaunchMode(arguments: ["AutoSign", "--background-refresh"]) == .backgroundRefresh)
    #expect(LaunchMode(arguments: ["AutoSign", "--install-background-refresh"]) == .installBackgroundRefresh)
    #expect(LaunchMode(arguments: ["AutoSign", "--verify-independent-account"]) == .verifyIndependentAccount)
    #expect(LaunchMode.interface.instanceRole == .interface)
    #expect(LaunchMode.installBackgroundRefresh.instanceRole == .interface)
    #expect(LaunchMode.backgroundRefresh.instanceRole == .backgroundRefresh)
    #expect(LaunchMode.verifyIndependentAccount.instanceRole == nil)
}
