import Foundation

enum ProfileRenewalPolicy {
    /// Network/build time and small clock differences are allowed; the expiry still comes from Apple's signed profile.
    static let freshnessTolerance: TimeInterval = 5 * 60

    static func validate(original: ProvisioningProfile, renewed: ProvisioningProfile,
                         bundleID: String, deviceUDID: String, requestedAt: Date, now: Date = Date(),
                         requireExtendedExpiry: Bool = false) throws {
        guard renewed.teamIdentifier == original.teamIdentifier,
              SigningService.profileSupports(renewed.applicationIdentifier, bundleID: bundleID) else {
            throw AutoSignError.invalidProfile("新描述文件的签名团队或应用标识不匹配，已停止覆盖安装。")
        }
        guard renewed.provisionsAllDevices || renewed.provisionedDevices.contains(deviceUDID) else {
            throw AutoSignError.invalidProfile("新描述文件仍未包含目标设备，请检查签名账号的设备注册状态。")
        }
        guard renewed.uuid != original.uuid,
              let created = renewed.creationDate,
              created >= requestedAt.addingTimeInterval(-120),
              created <= now.addingTimeInterval(120),
              renewed.expirationDate > now else {
            throw AutoSignError.invalidProfile("Apple 未签发新的描述文件，已停止安装并保留原签名。请检查签名账号后重试。")
        }
        if requireExtendedExpiry, SigningService.profileSupports(original.applicationIdentifier, bundleID: bundleID),
           renewed.expirationDate <= original.expirationDate {
            throw AutoSignError.invalidProfile("Apple 签发的描述文件没有延长有效期，已停止续签并保留原签名。")
        }
        if original.timeToLiveDays == 7 || renewed.timeToLiveDays == 7 {
            guard renewed.timeToLiveDays == 7,
                  abs(renewed.expirationDate.timeIntervalSince(created) - 7 * 86_400) < 60,
                  renewed.expirationDate.timeIntervalSince(now) >= 7 * 86_400 - freshnessTolerance else {
                throw AutoSignError.invalidProfile("Apple 返回的免费签名不足新的 7 天有效期，已停止安装并保留原签名。")
            }
        }
    }
}
