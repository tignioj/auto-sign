# AutoSign

AutoSign 是一个原生 macOS 图形工具，用自己的 Apple 开发者签名将未签名的 `.ipa` 安装到自己的 iPhone 或 iPad。

## 使用前准备

1. 安装 Xcode，在 **Xcode → Settings → Accounts** 登录 Apple ID。
2. 用 USB 连接所有目标设备、解锁并选择“信任此电脑”。
3. 如果设备尚未完成开发者配对，在 AutoSign 中逐台点击 **发起配对**，保持设备解锁并确认提示。
4. 在每台设备的 **设置 → 隐私与安全性 → 开发者模式** 中开启开发者模式并重启。
5. 从 Apple Developer 下载匹配应用 Bundle ID 和目标设备 UDID 的 Development 或 Ad Hoc `.mobileprovision`。免费 Personal Team 也可以，但描述文件和应用通常只有 7 天有效期。

首次安装完成后，还需要在每台 iPhone 或 iPad 上进入 **设置 → 通用 → VPN 与设备管理**，在“开发者 App”下选择本次签名使用的开发者并点 **信任**，然后再打开应用。每台设备通常只需操作一次；更换签名身份后可能需要重新信任。

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

Personal Team 免费签名通常只有 7 天有效期。手机 Store 手动刷新或 Mac 进入后台续签窗口时，AutoSign 会备份并隔离匹配该团队与 Bundle ID 的 Xcode 缓存，使用独立构建目录请求 Apple 重新签发描述文件，再重签并覆盖安装。免费签名必须通过新 UUID、签发日期及新的 7 天有效期校验，旧文件或有效期不足时直接报错，不会把普通重装显示为续签成功。缓存处理失败时回滚，中断后下次续签会自动恢复；不会撤销开发者证书。如果 Xcode 暂时无法挂载开发者磁盘镜像或等待目标设备准备超时，手动及后台续签都会等待 15 秒后自动重试一次；再次失败时保留错误详情。系统更新后可先通过 Wi-Fi 重试，持续失败再解锁设备并通过 USB 连接，在 Xcode 中检查设备支持。

若 Apple 要求重新登录或接受新的开发者协议，需要先在 Xcode 中完成该步骤。

当描述文件不包含所选设备时：

- 免费 Apple ID / Personal Team：保持 Xcode 账号登录、Mac 联网，并确保设备已解锁、信任此 Mac。AutoSign 会请 Xcode 自动注册设备。
- 付费开发者账号：如果自动注册失败，可在 Apple Developer 的 **Certificates, Identifiers & Profiles → Devices** 中添加 UDID，再重新生成并下载 Development 或 Ad Hoc 描述文件。

## 从应用源安装

在“选择安装包”中切换到 **从源获取**，粘贴 AltStore / SideStore 格式的 JSON 源地址并点击 **添加源**。也可以点击 **添加 Kazumi 源** 使用以下地址：

```text
https://raw.githubusercontent.com/ChouChiu/Kazumi-AltStore-Source/kazumi/generated/apps.json
```

选择已添加的源即可浏览应用、最新版本、包大小、iOS 版本要求和更新说明。点击 **下载最新 IPA** 后，AutoSign 会重新获取源中的最新发布，下载并检查 IPA，随后自动选为当前安装包。确认目标设备、签名证书和描述文件后，点击下方的签名安装按钮即可安装。

源地址和上次获取的列表会保存在本机；再次进入“从源获取”或点击 **刷新源** 可检查更新。最新版本遵循 [AltStore 的版本顺序规则](https://faq.altstore.io/developers/updating-apps)，使用 `versions` 数组的第一项，也兼容旧源的顶层 `version` / `downloadURL` 字段。刷新失败时保留上次列表，下载前必须成功重新获取源。

下载的 IPA 保存在 `~/Library/Application Support/AutoSign/Downloads/`，每次下载单独保存，供手动安装及后台续签使用。应用升级需要刷新源并下载新版本；后台自动续签使用当前已选 IPA。移除源仅移除订阅记录，已下载文件会保留。

参考：[Kazumi iOS 安装说明](https://kazumi.app/docs/misc/how-to-install-in-ios/) · [AltStore 源格式](https://faq.altstore.io/developers/make-a-source)。

## 同一 Wi-Fi 后台自动续签

在界面中打开“为已选设备后台自动续签”。AutoSign 会保存整组已选设备并安装当前用户级后台任务，每 30 分钟检查一次。签名有效时不会重复安装；进入最后 24 小时后会尝试续期，Apple 发放新描述文件后自动通过局域网逐台重签名并覆盖安装。如果某台设备暂时离线，其他设备会先完成，离线设备进入待更新队列并在后续检查中继续重试。

界面顶部的“账号与自动续签”面板每 15 秒刷新，显示 Xcode 本地账号记录、后台任务加载状态、预计下次检查时间，以及每台已选设备的最近状态、成功时间、已确认安装的签名到期时间和失败详情。检测到账号记录不等于在线登录仍有效；旧版本没有逐设备历史时显示“暂无记录”，最近旧版后台错误仍可展开查看。续签时间为预计值，Mac 休眠、设备离线或 Apple 尚未发放新描述文件都会延后。

Mac 需要保持开机、联网，所有目标设备与 Mac 必须位于同一可互访的局域网。每台设备首次无线使用前仍需通过 USB 完成配对，并在 Finder 中启用“连接到 Wi-Fi 时显示此设备”。

> iOS 应用安装包的扩展名是 `.ipa`，不是 `.ipk`。工具不绕过激活锁、开发者模式、证书校验或 iOS 代码签名安全机制。

请只签名和安装你有权使用、测试或分发的应用。IPA、描述文件和证书属于本机私有资产，已默认被 Git 忽略。

## AutoSign Store 手机客户端

相邻的 `auto-sign-store` 项目提供 iOS 17+ 原生客户端，可在手机查看签名到期时间、逐个 / 批量刷新应用，并刷新 Store 自身。先用 `auto-sign-store/Scripts/build-ipa.sh` 生成 Store IPA，再使用本版 AutoSign 签名安装。

在本工具的 **AutoSign Store · 手机续签** 面板开启局域网服务。手机与 Mac 连接同一可信 Wi-Fi，在 Store 中发现 Mac 并输入面板中的配对密钥，核对并选择本机设备后即可发起刷新。服务监听端口 `8091`，通过 Bonjour `_autosign._tcp` 广播；Mac 必须保持运行，首次无线连接前仍需 USB 配对。

成功安装后，原始 IPA 和每应用独立描述文件会保存在 `~/Library/Application Support/AutoSign/Store/`，供客户端重新签名。旧版安装的应用需使用本版覆盖安装一次才能纳入列表。Store 自身最后安装，手机应用关闭不会取消 Mac 任务；重新打开后会恢复任务结果。1.2.1 起主动使匹配的 Xcode 缓存失效以请求新描述文件，免费账号只有获得新 7 天签名且覆盖安装成功后才显示刷新完成。

实现参考：AltStore 的 [`FetchProvisioningProfilesOperation`](https://github.com/altstoreio/AltStore/blob/main/AltStore/Operations/FetchProvisioningProfilesOperation.swift) 每次刷新获取新描述文件；[Apple 的自动签名说明](https://developer.apple.com/help/account/provisioning-profiles/edit-download-or-delete-profiles/) 明确指出本地缓存满足条件时 Xcode 不会请求新描述文件。AutoSign 继续使用 Xcode 已登录的账号完成请求，手机无需输入 Apple ID。

2026-10-14 已用 iPhone18pm 拔线实测 1.2.1：从 Store 1.0.1 build 3 点击批量刷新，Kazumi 和 Store 自身都获得新的 168 小时签名；从手机读取的新描述文件 UUID 和到期时间与安装记录一致。Store 最后覆盖安装，退出后重开能恢复两项成功结果，两款应用均能正常启动。详细时间及验证记录见相邻项目的 [7 天续签实测](../auto-sign-store/README.md#7-天续签修复后实测2026-10-14)。

局域网服务默认关闭，所有接口需要配对密钥；此版本使用 HTTP，只在可信局域网使用，不要将端口映射到公网。完整构建、首次安装、自身刷新和 API 说明见 [`auto-sign-store/README.md`](../auto-sign-store/README.md)。
