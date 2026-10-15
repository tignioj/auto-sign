import Foundation
import Testing
@testable import AutoSign

@Test(arguments: [
    "Failed to allocate RSD device. (com.apple.mobiledevice error -402653181)",
    "The device disconnected immediately after connecting. (com.apple.dt.CoreDeviceError error 4000)",
    "无法连接目标设备。\nkAMDMuxConnectError",
    "CoreDevice 连接中断或读取超时，请重试。"
])
func transientDeviceReadRecoversAfterReconnecting(message: String) async throws {
    var reads = 0
    var reconnects = 0
    let value = try await DeviceConnectionRetry.run(operation: {
        reads += 1
        if reads < 3 { throw ProfileRefreshError.unavailable(message) }
        return "original-app-location"
    }, beforeRetry: { reconnects += 1 })
    #expect(value == "original-app-location")
    #expect(reads == 3 && reconnects == 2)
}

@Test func persistentDeviceReadFailureStopsAfterThreeAttempts() async {
    var reads = 0
    var reconnects = 0
    do {
        _ = try await DeviceConnectionRetry.run(operation: {
            reads += 1
            throw ProfileRefreshError.unavailable("Failed to allocate RSD device")
        }, beforeRetry: { reconnects += 1 })
        Issue.record("Expected exhausted transport retries")
    } catch {
        #expect(reads == 3 && reconnects == 2)
    }
}

@Test func recoveryNeverRetriesLockPairingProfileOrUnclassifiedErrors() async {
    let errors: [Error] = [
        ProfileRefreshError.unavailable("Device is locked; kAMDMuxConnectError"),
        ProfileRefreshError.unavailable("kAMDPasswordProtectedError; connection reset by peer"),
        ProfileRefreshError.unavailable("InvalidHostID; kAMDConnectionFailedError"),
        ProfileRefreshError.unavailable("unknown error"),
        ProfileRefreshError.verification("kAMDMuxConnectError"),
        ProfileRefreshError.incompatible("kAMDMuxConnectError"),
        ProfileRefreshError.unsupported("connection refused"),
        CancellationError()
    ]
    for error in errors {
        var attempts = 0
        do {
            _ = try await DeviceConnectionRetry.run(operation: { attempts += 1; throw error },
                beforeRetry: { Issue.record("Must not reconnect for \(error)") })
            Issue.record("Expected original failure")
        } catch { #expect(attempts == 1) }
    }
}

@Test func cancellationDuringReconnectStopsBeforeNextRead() async {
    let task = Task {
        var attempts = 0
        do {
            try await DeviceConnectionRetry.run(operation: {
                attempts += 1
                throw ProfileRefreshError.unavailable("Failed to allocate RSD device")
            }, beforeRetry: { withUnsafeCurrentTask { $0?.cancel() } })
            return (false, attempts)
        } catch { return (error is CancellationError, attempts) }
    }
    let (cancelled, attempts) = await task.value
    #expect(cancelled && attempts == 1)
}

@Test func exhaustedLegacyMuxFailureUsesCoreDeviceAndKeepsItsResult() async throws {
    var legacyAttempts = 0
    var remoteAttempts = 0
    let result: String = try await DeviceProfileService.withTransportRecovery(legacy: {
        try await DeviceConnectionRetry.run(operation: { () async throws -> String in
            legacyAttempts += 1
            throw ProfileRefreshError.unavailable("kAMDMuxConnectError")
        }, beforeRetry: {})
    }, remote: {
        remoteAttempts += 1
        return "verified-coredevice-profile"
    }, missingDevice: { _ in
        Issue.record("A transient Mux failure must not be treated as a capability failure")
        return .unsupported("unexpected")
    })
    #expect(result == "verified-coredevice-profile")
    #expect(legacyAttempts == 3 && remoteAttempts == 1)
}

@Test func failedAlternativeForTransientMuxNeverPermitsReinstallation() async {
    do {
        let _: String = try await DeviceProfileService.withTransportRecovery(legacy: {
            throw ProfileRefreshError.unavailable("kAMDMuxConnectError")
        }, remote: {
            throw ProfileRefreshError.deviceNotFound("CoreDevice helper missing")
        }, missingDevice: { _ in
            Issue.record("Transient failure must not enter the reinstallation policy")
            return .unsupported("unexpected")
        })
        Issue.record("Expected unavailable transport")
    } catch {
        guard case ProfileRefreshError.unavailable(let message) = error else {
            Issue.record("Must remain a connection error: \(error)")
            return
        }
        #expect(message.contains("kAMDMuxConnectError") && message.contains("CoreDevice helper missing"))
    }
}

@Test func transportSwitchNeverHidesDeviceLockOrProfileRejection() async {
    for error in [ProfileRefreshError.unavailable("Device is locked"), .verification("banned profile"),
                  .incompatible("device rejected profile"), .unsupported("invalid service"), .unavailable("unknown error")] {
        do {
            let _: String = try await DeviceProfileService.withTransportRecovery(legacy: { throw error }, remote: {
                Issue.record("Must preserve the original failure")
                return "unexpected"
            }, missingDevice: { _ in .unsupported("unexpected") })
            Issue.record("Expected original failure")
        } catch {}
    }
}

@Test func legacyDiscoveryFailureStillUsesValidatedMissingDevicePolicy() async {
    var missingChecks = 0
    do {
        let _: String = try await DeviceProfileService.withTransportRecovery(legacy: {
            throw ProfileRefreshError.deviceNotFound("legacy missing")
        }, remote: {
            throw ProfileRefreshError.deviceNotFound("remote missing")
        }, missingDevice: { message in
            missingChecks += 1
            #expect(message == "legacy missing")
            return .unavailable("locked target")
        })
        Issue.record("Expected the validated missing-device failure")
    } catch {
        #expect(missingChecks == 1)
        #expect(error.localizedDescription == "locked target")
    }
}
