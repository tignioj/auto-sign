# AutoSign

AutoSign 是一个原生 macOS 图形工具，用自己的 Apple 开发者签名将未签名的 `.ipa` 安装到自己的 iPhone 或 iPad。

## 使用前准备

1. 安装 Xcode，在 **Xcode → Settings → Accounts** 登录 Apple ID。
2. 用 USB 连接所有目标设备、解锁并选择“信任此电脑”。
3. 如果设备尚未完成开发者配对，在 AutoSign 中逐台点击 **发起配对**，保持设备解锁并确认提示。
4. 在每台设备的 **设置 → 隐私与安全性 → 开发者模式** 中开启开发者模式并重启。
5. 从 Apple Developer 下载匹配应用 Bundle ID 和目标设备 UDID 的 Development 或 Ad Hoc `.mobileprovision`。免费 Personal Team 也可以，但描述文件和应用通常只有 7 天有效期。

> 开启“开发者模式”只表示设备允许运行开发 App，不会自动把设备 UDID 写入描述文件。如果当前描述文件缺少目标设备，AutoSign 会通过 Xcode 尝试注册设备并重新生成描述文件。

## 构建和运行

要求 macOS 14 或更高版本，并安装完整的 Xcode。

双击或在终端运行：

```sh
./Scripts/build-app.sh
open dist/AutoSign.app
```

也可以在项目目录执行 `swift run AutoSign` 进行开发调试。

## 操作

连接设备后，AutoSign 会自动选择可用设备、钥匙串证书和 Xcode 中可用的最新描述文件。设备卡片支持多选，也可以按 iPhone 或 iPad 分类全选。拖入 `.ipa` 并点击“签名并安装到 N 台”后，AutoSign 会先让同一份描述文件覆盖所有已选设备，再逐台重签名和安装。每台设备对应的签名副本会保存在原 IPA 旁边，原文件不会被修改。如果 IPA 使用了无法注册的示例 Bundle ID，AutoSign 会采用描述文件中的明确 Bundle ID 完成重签名。

Personal Team 免费签名通常只有 7 天有效期。到期后保持 Xcode 账号登录、Mac 联网并连接设备，再次点击签名安装；AutoSign 会调用 Xcode 自动续期描述文件，随后在所有已选设备上重新签名和安装。若 Apple 要求重新登录或接受新的开发者协议，需要先在 Xcode 中完成该步骤。

当描述文件不包含所选设备时：

- 免费 Apple ID / Personal Team：保持 Xcode 账号登录、Mac 联网，并确保设备已解锁、信任此 Mac。AutoSign 会请 Xcode 自动注册设备。
- 付费开发者账号：如果自动注册失败，可在 Apple Developer 的 **Certificates, Identifiers & Profiles → Devices** 中添加 UDID，再重新生成并下载 Development 或 Ad Hoc 描述文件。

## 同一 Wi-Fi 后台自动续签

在界面中打开“为已选设备后台自动续签”。AutoSign 会保存整组已选设备并安装当前用户级后台任务，每 30 分钟检查一次。签名有效时不会重复安装；进入最后 24 小时后会尝试续期，Apple 发放新描述文件后自动通过局域网逐台重签名并覆盖安装。如果某台设备暂时离线，其他设备会先完成，离线设备进入待更新队列并在后续检查中继续重试。

Mac 需要保持开机、联网，所有目标设备与 Mac 必须位于同一可互访的局域网。每台设备首次无线使用前仍需通过 USB 完成配对，并在 Finder 中启用“连接到 Wi-Fi 时显示此设备”。

> iOS 应用安装包的扩展名是 `.ipa`，不是 `.ipk`。工具不绕过激活锁、开发者模式、证书校验或 iOS 代码签名安全机制。

请只签名和安装你有权使用、测试或分发的应用。IPA、描述文件和证书属于本机私有资产，已默认被 Git 忽略。
