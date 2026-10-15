# 描述文件续签真机验证

本文保存历史实测记录及复现方法，使用说明见 [README](../README.md)。

## CoreDevice Wi-Fi 通道（2026-10-15）

本次 iPadmini7 可通过旧 MobileDevice 通道发现，iPhone18pm 通过 CoreDevice 可连接，但旧通道没有发现它。此前修复版因此走了覆盖安装回退；这不能证明该机型不支持独立更新描述文件。新增 CoreDevice 描述文件通道后，使用 `dist/CoreDeviceProfileFix/AutoSign.app`，为 iPhone18pm 启用“此设备仅更新描述文件，禁止覆盖安装”，在界面执行两项真实续签，结果为 **2/2 成功**。

| 应用 | 原到期时间（北京时间） | 续签后到期时间（北京时间） | 结果 |
| --- | --- | --- | --- |
| Kazumi 2.3.8 | 2026-10-22 01:42:25 | 2026-10-22 02:18:35 | `profileOnly`，新签发起 168 小时 |
| AutoSign Store 1.2.0 | 2026-10-22 01:43:05 | 2026-10-22 02:19:05 | `profileOnly`，新签发起 168 小时 |

连接类型为 `localNetwork`，独立描述文件服务使用 CoreDevice。两个新 UUID 均与旧文件不同，从设备读回的 CMS 原文与本地新文件逐字节一致；应用安装位置、版本、原 IPA 和已签 IPA 的 SHA-256 均未变化。界面的启动验证开关保持关闭；先前另行启用启动检查的测试因手机自动锁屏而中断，不能将它计为启动验证成功。Xcode 签发曾报 `No Accounts`，由用户重新登录后恢复。

北京时间 2026-10-15 08:38，用户再次解锁手机后补做验证：两款应用使用 `--terminate-existing` 重新启动成功，进程在两秒后仍存活，当前描述文件再次通过 CMS 逐字节读回校验，安装位置、版本及两份 IPA 的哈希保持不变。此步骤没有重新签发或安装描述文件、没有安装应用。设备当前保存的是 08:37 签发的更新文件，Kazumi 和 Store 到期时间分别为 2026-10-22 08:37:32、08:37:44；首次续签记录保留，本次结果追加在报告的 `followupVerification` 中。

本地报告：`dist/DeviceTests/wifi-profile-diagnosis/verification-profile-only.json`。报告与修复版应用均位于 Git 忽略的 `dist/`，未随仓库发布。新增通道、协议解析和禁止重装策略的自动化检查通过，完整测试集为 101 项。

## 仅更新描述文件

在 iPhone18pm（iPhone 18 Pro Max、iOS 27.0）的 `localNetwork` 连接上，对 Kazumi 和 AutoSign Store 1.1.0 执行真实续签。两款应用均走 `profileOnly`：新描述文件 UUID 与原文件不同，从设备读回的 CMS 原文与新文件完全一致；应用安装位置及版本均保持不变，随后使用 `--terminate-existing` 另行验证全新进程启动成功。

| 应用 | 原到期时间（北京时间） | 续签后到期时间（北京时间） | 结果 |
| --- | --- | --- | --- |
| Kazumi 2.3.8 | 2026-10-21 21:01:54 | 2026-10-21 22:07:11 | 无需重装，168 小时新签名，重新启动成功 |
| AutoSign Store 1.1.0 | 2026-10-21 20:52:51 | 2026-10-21 22:07:34 | 无需重装，168 小时新签名，重新启动成功 |

本地机器可读记录为项目根目录下的 `dist/DeviceTests/verification-profile-only.json`。`dist/` 被 Git 忽略，报告未随仓库发布，克隆项目后需自行运行真机测试生成。正常启动验证只检查启动与短时间进程存活，不替代应用所有功能的测试。

## 手机批量刷新

随后在手机 Store 1.1.0 点击“刷新全部应用”，Mac 1.4.1 完成两项真实任务：Kazumi 到期时间延长至北京时间 **2026-10-21 22:24:53**，Store 延长至 **2026-10-21 22:25:18**，均为新签发起 168 小时。刷新前后均使用 `localNetwork`；两款应用安装位置、版本、原 IPA 哈希及进程编号均不变，Store 自身未退出。设备描述文件逐字节核验通过，之后另行结束并重新启动两款应用，Kazumi 显示正常首页及版本提示，Store 保留配对、设备选择并显示新到期时间。手机“活动”显示两项“已更新描述文件，无需重装；有效期已延长，启动验证通过”。本地记录为项目根目录下的 `dist/DeviceTests/verification-profile-only-batch.json`，同样未随仓库发布。

## 验证范围

以上为 2026-10-14 的历史真机结果。手机“更新 / 一键更新全部”已通过自动化测试及模拟器验证，尚未完成真实 Apple 签名与真机版本升级实测，不能将仅刷新签名的结果视为版本升级验证。

## 复现步骤

重复真机验证需要 Xcode 账号有效、目标设备已配对、保持解锁，且应用已在 Store 应用库中。在项目根目录运行以下命令，会实际向 Apple 请求新文件并更新该设备的受管理应用，另行重新启动应用以验证签名：

```sh
swift build
AUTOSIGN_INTEGRATION_REFRESH_DEVICE='替换为设备UDID' \
AUTOSIGN_INTEGRATION_REFRESH_REPORT="$PWD/dist/DeviceTests/verification-profile-only.json" \
swift test --filter integrationProfileOnlyRefreshWhenConfigured
```

可以用 `AUTOSIGN_INTEGRATION_REFRESH_APPS` 指定逗号分隔的应用记录 ID（不是 Bundle ID）；未指定时处理该设备应用库中的全部应用，Store 自身最后处理。此测试要求最终走 `profileOnly` 路径，并显式启用启动验证、另行终止和重启应用，不受界面启动验证开关控制。
