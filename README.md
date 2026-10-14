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

也可以在项目目录执行 `swift build && swift run AutoSign` 进行开发调试。构建会同时生成管理设备描述文件的 `AutoSignDeviceHelper`，打包脚本会将它放入应用；无需额外安装 Python 或 libimobiledevice。

## 操作

连接设备后，AutoSign 会自动选择可用设备、钥匙串证书和 Xcode 中可用的最新描述文件。设备卡片支持多选，也可以按 iPhone 或 iPad 分类全选。拖入 `.ipa` 并点击“签名并安装到 N 台”后，AutoSign 会先让同一份描述文件覆盖所有已选设备，再逐台重签名和安装。每台设备对应的签名副本会保存在原 IPA 旁边，原文件不会被修改。如果 IPA 使用了无法注册的示例 Bundle ID，AutoSign 会采用描述文件中的明确 Bundle ID 完成重签名。

Personal Team 免费签名通常只有 7 天有效期。手机 Store 手动刷新或 Mac 进入后台续签窗口时，AutoSign 会备份并隔离匹配该团队与 Bundle ID 的 Xcode 缓存，使用独立构建目录请求 Apple 重新签发描述文件。免费签名必须通过新 UUID、签发日期、新的 7 天有效期及到期时间延长校验，旧文件或有效期不足时直接报错，不会把普通重装显示为续签成功。缓存处理失败时回滚，中断后下次续签会自动恢复；不会撤销开发者证书。如果 Xcode 暂时无法挂载开发者磁盘镜像或等待目标设备准备超时，手动及后台续签都会等待 15 秒后自动重试一次；再次失败时保留错误详情。系统更新后可先通过 Wi-Fi 重试，持续失败再解锁设备并通过 USB 连接，在 Xcode 中检查设备支持。

Mac 1.4.1 起，续签优先通过 macOS 的 MobileDevice / `com.apple.misagent` 服务单独安装新描述文件，不重新签名或传输 IPA。只有已安装证书被新描述文件允许、原签名权限兼容且不包含未单独处理的扩展时才使用此路径。随后读回设备上的原始 CMS 文件，确认与已校验的新文件逐字节一致，检查安装位置和版本保持不变。

“账号与自动续签”面板提供 **刷新签名后验证应用启动** 开关，默认关闭并保存到本机。手机 Store 发起的单个 / 批量刷新及 Mac 后台续签都遵循此设置，包括续签时的覆盖安装。关闭后不会自动启动应用或检查进程，仍校验新描述文件、有效期及安装结果，完成提示为“已跳过启动验证”。开启后会启动应用并检查进程仍在运行，不会主动结束已有应用或切换到前台；手机锁定时启动验证会失败，等待解锁后重试。关闭启动验证不保证锁定设备可完成其他设备操作。

证书变化、权限不兼容、应用扩展或设备明确不支持单独更新时，自动回退到原标识、原团队的完整签名和覆盖安装，并按上述开关决定是否验证启动。扩展仍受现有签名器的支持范围限制，不支持的扩展会报错。若系统不支持读回描述文件，此路径依据已验证的新签名包、安装成功响应及可选的启动检查确认结果；支持读回时必须核对设备文件。临时 Wi-Fi Mux 连接错误最多重连两次，每次等待 2 秒；连接中断、设备锁定、取消、本地校验失败、设备报告描述文件被封禁或无法完成验证，都不会盲目触发重装。版本升级及首次安装继续使用完整安装流程，不要求其到期时间晚于原签名。本功能不引入 AltStore 的 Apple ID / Anisette 登录链路；MobileDevice 是系统设备协议实现，仍需随系统版本验证兼容性。

若 Apple 要求重新登录或接受新的开发者协议，需要先在 Xcode 中完成该步骤。

当描述文件不包含所选设备时：

- 免费 Apple ID / Personal Team：保持 Xcode 账号登录、Mac 联网，并确保设备已解锁、信任此 Mac。AutoSign 会请 Xcode 自动注册设备。
- 付费开发者账号：如果自动注册失败，可在 Apple Developer 的 **Certificates, Identifiers & Profiles → Devices** 中添加 UDID，再重新生成并下载 Development 或 Ad Hoc 描述文件。

## 从应用源安装

在“选择安装包”中切换到 **从源获取**，粘贴 AltStore / SideStore 格式的 JSON 源地址并点击 **添加源**。也可以点击 **添加 Kazumi 源** 使用以下地址：

```text
https://raw.githubusercontent.com/ChouChiu/Kazumi-AltStore-Source/kazumi/generated/apps.json
```

安装手机续签客户端时，点击 **添加 AutoSign Store 源**，或手动添加以下固定地址：

```text
https://raw.githubusercontent.com/tignioj/auto-sign-store/source/apps.json
```

该源由 [auto-sign-store 的 GitHub Actions](https://github.com/tignioj/auto-sign-store/actions) 在正式版本标签发布后自动更新；IPA 托管在 GitHub Releases，无需本地构建 Store。

选择已添加的源即可浏览应用、最新版本、包大小、iOS 版本要求和更新说明。点击 **下载最新 IPA** 后，AutoSign 会重新获取源中的最新发布，下载并检查 IPA，随后自动选为当前安装包。确认目标设备、签名证书和描述文件后，点击下方的签名安装按钮即可安装。

源地址和上次获取的列表会保存在本机；再次进入“从源获取”或点击 **刷新源** 可检查更新。最新版本遵循 [AltStore 的版本顺序规则](https://faq.altstore.io/developers/updating-apps)，使用 `versions` 数组的第一项，也兼容旧源的顶层 `version` / `downloadURL` 字段。刷新失败时保留上次列表，下载前必须成功重新获取源。

下载的 IPA 保存在 `~/Library/Application Support/AutoSign/Downloads/`，每次下载单独保存，供手动安装及后台续签使用。Mac 的后台自动续签使用当前已选 IPA；手机端的版本升级见下方“源更新检测与一键更新”。移除源仅移除订阅记录，已下载文件会保留。

参考：[Kazumi iOS 安装说明](https://kazumi.app/docs/misc/how-to-install-in-ios/) · [AltStore 源格式](https://faq.altstore.io/developers/make-a-source)。

## 源更新检测与一键更新

Mac 1.4.0 配合 Store 1.2.0，开启局域网服务后默认每 30 分钟检查所有已订阅源；服务启动时若已到检查时间会立即补查，签名、下载或刷新忙碌时延后重试。Mac 需保持 AutoSign 运行并联网，休眠期间暂停，唤醒后补查。可以在局域网服务面板关闭自动检查；检查时间与缓存保存在本机，重启不会重新计时或丢失已发现的更新。

手机“我的应用”显示可更新数量徽标、当前与最新版本、版本说明，可单独更新或点击 **一键更新全部**（每批最多 50 个）。手机在前台每 30 秒同步，重新打开也会自动同步；**检查更新**可立即让 Mac 获取所有远端源。提示在 Store 内显示，手机完全关闭时没有系统推送。离线时显示上次结果，源检查失败会显示提示并保留缓存。

更新只针对所选设备已有的受管理应用，取源的 `versions` 第一项，并比较实际已安装版本及构建号，避免降级和重复提示。旧安装记录可从保存的原始 IPA 识别应用及构建号；已有源关联会固定使用该源，没有关联且多个源都包含相同应用时不自动选择。移除订阅后不再提示该源的版本。

更新任务在执行前保存，逐应用重新获取源、下载并验证 IPA 的 Bundle ID、版本、构建号及完整性，再沿用原应用标识和签名团队覆盖安装。失败的应用保留旧记录，其他应用继续执行；Store 自身最后更新，手机退出或被覆盖安装后 Mac 继续执行，重开可恢复结果。相同请求不会重复执行。“刷新签名”仍使用已保存的 IPA，不自动升级。

## 同一 Wi-Fi 后台自动续签

在界面中打开“为已选设备后台自动续签”。AutoSign 会保存整组已选设备并安装当前用户级后台任务，每 30 分钟检查一次。签名有效时不会重复安装；进入最后 24 小时后会尝试续期，Apple 发放新描述文件后自动通过局域网逐台优先更新描述文件，不兼容时覆盖安装；仅在开启“刷新签名后验证应用启动”时自动启动应用验证。如果某台设备暂时离线，其他设备会先完成，离线设备进入待更新队列并在后续检查中继续重试。

界面顶部的“账号与自动续签”面板每 15 秒刷新，显示 Xcode 本地账号记录、后台任务加载状态、预计下次检查时间，以及每台已选设备的最近状态、成功时间、已确认安装的签名到期时间和失败详情。检测到账号记录不等于在线登录仍有效；旧版本没有逐设备历史时显示“暂无记录”，最近旧版后台错误仍可展开查看。续签时间为预计值，Mac 休眠、设备离线或 Apple 尚未发放新描述文件都会延后。

Mac 需要保持开机、联网，所有目标设备与 Mac 必须位于同一可互访的局域网。每台设备首次无线使用前仍需通过 USB 完成配对，并在 Finder 中启用“连接到 Wi-Fi 时显示此设备”。

> iOS 应用安装包的扩展名是 `.ipa`，不是 `.ipk`。工具不绕过激活锁、开发者模式、证书校验或 iOS 代码签名安全机制。

请只签名和安装你有权使用、测试或分发的应用。IPA、描述文件和证书属于本机私有资产，已默认被 Git 忽略。

## AutoSign Store 手机客户端

[auto-sign-store](https://github.com/tignioj/auto-sign-store) 提供 iOS 17+ 原生客户端，可在手机管理应用源、选择应用让 Mac 自动下载安装，查看签名到期时间、逐个 / 批量刷新应用，并刷新 Store 自身。在“从源获取”中添加 AutoSign Store 源、下载最新 IPA，再使用 AutoSign 签名安装；也可以用相邻项目的 `Scripts/build-ipa.sh` 在本地构建。

在本工具的 **AutoSign Store · 手机安装与续签** 面板开启局域网服务。手机与 Mac 连接同一可信 Wi-Fi，在 Store 中发现 Mac 并输入面板中的配对密钥，核对并选择本机设备后即可发起刷新。服务监听端口 `8091`，通过 Bonjour `_autosign._tcp` 广播；Mac 必须保持运行，首次无线连接前仍需 USB 配对。

Mac 1.3.0 配合 Store 1.1.0 后，手机“应用源”与 Mac 的“从源获取”共用源订阅。手机可添加、刷新、移除源，浏览和搜索应用，选择目标设备并发起安装。Mac 先保存任务，再重新检查最新源、下载并验证 IPA、向 Xcode 请求匹配的描述文件，然后签名和安装。进度及错误在手机“活动”中显示；手机退出后 Mac 继续执行，重新打开可恢复结果。相同请求编号不会重复安装。

首次安装采用 Mac 当前描述文件的签名团队，为应用生成独立的团队专属 Bundle ID；不会复用 Store 的明确标识覆盖 Store。升级受管理应用保留原标识和团队，后续刷新继续使用已安装版本的原始 IPA。手机不需要输入 Apple ID 或持有证书。两端均需更新；本地构建不更新公开源或 GitHub Release。

成功安装后，原始 IPA 和每应用独立描述文件会保存在 `~/Library/Application Support/AutoSign/Store/`，供客户端续签。旧版安装的应用需使用本版覆盖安装一次才能纳入列表；已在应用库中的旧记录会兼容迁移，无需专门重装。Store 自身最后处理，手机应用关闭不会取消 Mac 任务；重新打开后会恢复任务结果。1.2.1 起主动使匹配的 Xcode 缓存失效以请求新描述文件；1.4.1 起优先单独更新描述文件，有效期延长并完成设备验证后才显示刷新完成。旧 Store 客户端仍能发起请求及读取结果，新版客户端根据 `profile-refresh` 能力显示对应说明。

实现参考：AltStore 的 [`FetchProvisioningProfilesOperation`](https://github.com/altstoreio/AltStore/blob/main/AltStore/Operations/FetchProvisioningProfilesOperation.swift) 每次刷新获取新描述文件；[Apple 的自动签名说明](https://developer.apple.com/help/account/provisioning-profiles/edit-download-or-delete-profiles/) 明确指出本地缓存满足条件时 Xcode 不会请求新描述文件。AutoSign 继续使用 Xcode 已登录的账号完成请求，手机无需输入 Apple ID。

2026-10-14 已用 iPhone18pm 拔线实测 1.2.1：从 Store 1.0.1 build 3 点击批量刷新，Kazumi 和 Store 自身都获得新的 168 小时签名；从手机读取的新描述文件 UUID 和到期时间与安装记录一致。Store 最后覆盖安装，退出后重开能恢复两项成功结果，两款应用均能正常启动。详细时间及验证记录见相邻项目的 [7 天续签实测](../auto-sign-store/README.md#7-天续签修复后实测2026-10-14)。

2026-10-14 已实测 Mac 1.3.0 与 Store 1.1.0：从 iPhone18pm 添加 Kazumi 源并选择安装，Mac 通过局域网完成真实下载、获取新 168 小时描述文件及覆盖安装。Store 进入后台后任务继续，重开可恢复成功结果，Kazumi 正常启动。详见相邻项目的 [手机源安装真机实测](../auto-sign-store/README.md#手机源安装真机实测2026-10-14)。

局域网服务默认关闭，所有接口需要配对密钥；此版本使用 HTTP，只在可信局域网使用，不要将端口映射到公网。完整构建、首次安装、自身刷新和 API 说明见 [`auto-sign-store/README.md`](../auto-sign-store/README.md)。

## 仅更新描述文件实测：2026-10-14

在 iPhone18pm（iPhone 18 Pro Max、iOS 27.0）的 `localNetwork` 连接上，对 Kazumi 和 AutoSign Store 1.1.0 执行真实续签。两款应用均走 `profileOnly`：新描述文件 UUID 与原文件不同，从设备读回的 CMS 原文与新文件完全一致；应用安装位置及版本均保持不变，随后使用 `--terminate-existing` 另行验证全新进程启动成功。

| 应用 | 原到期时间（北京时间） | 续签后到期时间（北京时间） | 结果 |
| --- | --- | --- | --- |
| Kazumi 2.3.8 | 2026-10-21 21:01:54 | 2026-10-21 22:07:11 | 无需重装，168 小时新签名，重新启动成功 |
| AutoSign Store 1.1.0 | 2026-10-21 20:52:51 | 2026-10-21 22:07:34 | 无需重装，168 小时新签名，重新启动成功 |

机器可读记录：[`dist/DeviceTests/verification-profile-only.json`](dist/DeviceTests/verification-profile-only.json)。68 项自动测试覆盖有效期不延长时拒绝续签、证书/权限/扩展不兼容时回退、回退失败不报告成功、锁定/验证失败不重装、Wi-Fi 有限重连、取消及旧记录兼容；Mac Release 和 iOS 模拟器构建通过。正常验证只检查启动与短时间进程存活，不替代应用所有功能的测试。

随后在手机 Store 1.1.0 点击“刷新全部应用”，新版 Mac 1.4.1 完成两项真实任务：Kazumi 到期时间延长至北京时间 **2026-10-21 22:24:53**，Store 延长至 **2026-10-21 22:25:18**，均为新签发起 168 小时。刷新前后均使用 `localNetwork`；两款应用安装位置、版本、原 IPA 哈希及进程编号均不变，Store 自身未退出。设备描述文件逐字节核验通过，之后另行结束并重新启动两款应用，Kazumi 显示正常首页及版本提示，Store 保留配对、设备选择并显示新到期时间。手机“活动”显示两项“已更新描述文件，无需重装；有效期已延长，启动验证通过”。完整记录：[`dist/DeviceTests/verification-profile-only-batch.json`](dist/DeviceTests/verification-profile-only-batch.json)。

重复真机验证需要 Xcode 账号有效、目标设备已配对、保持解锁，且应用已在 Store 应用库中。以下命令会实际向 Apple 请求新文件并更新该设备的受管理应用，另行重新启动应用以验证签名：

```sh
swift build
AUTOSIGN_INTEGRATION_REFRESH_DEVICE=<设备UDID> \
AUTOSIGN_INTEGRATION_REFRESH_REPORT="$PWD/dist/DeviceTests/verification-profile-only.json" \
swift test --filter integrationProfileOnlyRefreshWhenConfigured
```

可以用 `AUTOSIGN_INTEGRATION_REFRESH_APPS` 指定逗号分隔的应用记录 ID。未设置设备环境变量时，常规 `swift test` 不会续签或操作真机。
