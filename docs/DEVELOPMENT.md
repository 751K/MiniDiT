# MiniDiT 开发说明

使用说明见 [README](../README.md)。

## 编译

需要 Xcode 26 以上（液态玻璃和 `.icon` 图标要用）。

```bash
open Apps/MiniDiT/MiniDiT.xcodeproj
```

工程默认使用「Apple Development」证书签名。自己编译时，在 Signing 里换成自己的团队；没有开发者账号就改成「Sign to Run Locally」，只是每次重新编译后，钥匙串都会再问一次能不能读取相机账号。

## 发布

Debug 和 Release 都开着强化运行时，不开沙盒（沙盒会挡住 PTP/IP、SSH、USB 透传和往 Resolve 发脚本）。`MiniDiT/MiniDiT.entitlements` 只声明强化运行时下还要单独申请的两项：Apple Events（让 Capture One 导入）和照片图库（导出实况照片）。

发给别人用的版本由 `Apps/MiniDiT/scripts/release.sh` 生成：Developer ID 签名 → 公证 → 钉上公证结果 → 做成 DMG 并公证 → 写出自动更新清单 `appcast.xml`。Developer ID 证书不用事先建：导出时用自动签名，Xcode 会用已登录的开发者账号申请一张存进钥匙串，以后复用。公证凭据要存一次：`xcrun notarytool store-credentials minidit-notary --team-id HGXZB3UC25 --keychain ~/Library/Keychains/login.keychain-db`，按提示粘贴在 appleid.apple.com 生成的 App 专用密码。

```bash
sh Apps/MiniDiT/scripts/release.sh               # 版本号取工程里的 MARKETING_VERSION
VERSION=0.2 sh Apps/MiniDiT/scripts/release.sh
NOTARIZE=0 sh Apps/MiniDiT/scripts/release.sh    # 只签名打包，先检查签名
```

结果在 `Apps/MiniDiT/build/release/`：`MiniDiT-<版本>.dmg` 和 `appcast.xml`。构建号默认取提交数（没有 `.git` 时用日期时间），可用 `BUILD=` 指定，每次发布必须比上一版大。公证被拒时脚本会打出 Apple 返回的日志。

### 自动更新

App 用 [Sparkle](https://sparkle-project.org) 检查更新：读最新 GitHub Release 里的 `appcast.xml`（地址和公钥在 `Apps/MiniDiT/Info.plist`），只安装用同一把 EdDSA 私钥签过名、同一个开发者团队签名的版本。Debug 版不启动更新器。

- 私钥由 Sparkle 的 `generate_keys` 生成，存在发布者的登录钥匙串里，`release.sh` 用 `sign_update` 给 DMG 签名（Sparkle 命令行工具默认在 `~/Tools/Sparkle-2.10.1/bin`，可用 `SPARKLE_BIN` 改）。私钥要另外备份（`generate_keys -x <文件>`）：丢了以后，已安装的 App 就收不到更新。
- 更新说明：有 `Apps/MiniDiT/release-notes/<版本>.html` 时写进 `appcast.xml`，在更新窗口里显示；`<版本>.md` 是 GitHub 发布页的说明，`publish-release.sh` 默认使用。
- 发布：`sh Apps/MiniDiT/scripts/publish-release.sh`，把 DMG 和 `appcast.xml` 上传成 GitHub Release `v<版本>`（`NOTES_FILE=` 指定发布页说明）。仓库是公开的，App 才能读到。
- 本地测试：`defaults write com.kong.MiniDiT updateFeedURL http://127.0.0.1:<端口>/appcast.xml` 让 Release 版从本地地址检查更新（清单里的下载地址也要改成本地的），测完 `defaults delete com.kong.MiniDiT updateFeedURL`。

## 开发

运行测试：

```bash
swift test
```

浏览功能的 App 层检查在 `Tests/AppFeatureChecks/`：使用 `run.sh <临时测试卡路径>`，链接 Debug App 对象文件，验证刷新保留身份/选择/日期、全卡标记筛选、FCPXML 时间码及 Shot Mark 偏移、AVPlayer 播放/定位/释放。测试卡应包含 `FEATURE001.JPG`（4 星）、`FEATURE002.JPG`（无星）及 3 秒、25p 的 `PRIVATE/M4ROOT/CLIP/C0001.MP4`，配套 XML 起始 TC 为 `01:02:03:04`、第 25 帧有 Shot Mark。该检查会在测试卡中创建 `FEATURE003.JPG` 和 `feature-check.fcpxml`，只能对临时副本运行；加 `--show-ui` 可查看实际预览界面。检查使用独立偏好域，不读取相机账号、不写应用设置、不启动后台服务。

大疆存储卡检查使用 `Tests/AppFeatureChecks/run.sh --dji-card`：在临时目录构造只有 `DCIM/DJI_001/` 的卡，验证识别、DNG 归为 RAW、.LRF 不单独列出而作为代理导入到 `Proxy/*.MP4`、按文件名取拍摄时间。文件内容是占位字节，不能代替真卡实测。

尼康无线：`Sources/SonyRemoteKit/Nikon/NikonWiFi.swift`（探测、配对、打开标准 `PTPCameraLibrary`）和 `NikonBonjour.swift`（mDNS 配对状态），App 里由 `AppModel+Source.swift` 的 `openOtherBrandIfNeeded` 在索尼流程之前分流。配对流程依据 libgphoto2 issue #1314（Nikon ZR 抓包），独立实现。`swift test --filter Nikon` 用 `FakeCamera`（可设 `ackGUID` / `ackName`）模拟配对、重连、已配对和被别的电脑占用的情况。

USB：`Sources/SonyRemoteKit/PTP/PTPTransport.swift` 是 PTP 传输接口（`PTPIPClient` 和 `PTPUSBClient` 都实现它），`SonyCamera`、`PTPCameraLibrary`、索尼远程传输 / 内容传输都只依赖它。`USB/PTPUSBClient.swift`（USB 容器编解码、事务）、`USB/ICPassthroughDevice.swift`（ImageCaptureCore 适配）、`USB/USBCameraOpener.swift`（选择浏览方式）。App 里是 `Camera/USBCameraBrowser.swift` 和 `AppModel+USB.swift`。`swift test --filter "PTPUSB|USBCameraOpener"` 用 `FakeUSBDevice` 把命令容器交给 `FakeSonyState`。

富士无线：`Sources/SonyRemoteKit/Fujifilm/FujiWiFi.swift`（82 字节握手和 USB 式容器的 `FujiPTPClient`）与 `FujiCameraLibrary.swift`（按 libfuji 的 `fuji_setup` 建立会话、列文件、1 MB 分块下载），App 里是 `AppModel+Fujifilm.swift` 的 `connectFujifilm`（来源页按钮，默认 192.168.0.1，可用 `fujiHost` 改）。`swift test --filter Fuji` 里的 `FakeFuji` 模拟握手、按 OK、远程看图和下载。

佳能无线：`Sources/SonyRemoteKit/Canon/CanonWiFi.swift`（握手、SetRemoteMode、1 MB 分块下载、KeepDeviceOn 保活，打开标准 `PTPCameraLibrary`；`CanonBonjour` 在握手被拒或超时时看 mDNS 里有没有佳能）。同一个 `openOtherBrandIfNeeded` 里按握手返回的相机名（含 Canon 或以 EOS 开头）分流。协议依据 libgphoto2 的 `camlibs/ptp2` 源码和 Troopers 2013「Paparazzi over IP」，独立实现。`swift test --filter Canon` 用 `FakeCamera` 模拟连接、下载和未配对；读卡检查用 `Tests/AppFeatureChecks/run.sh --canon-card`。

联机拍摄：`Apps/MiniDiT/MiniDiT/Camera/TetherSession.swift`（遥控、取景、下载到缓存 `TetherSpool`）、`App/AppModel+Tether.swift`（换主来源、自动导入）、`Views/TetherView.swift`（独立窗口 `tether`：取景和底部参数条；选择器在 `TetherPickers.swift`，右边的侧栏在 `TetherSidebar.swift`）。遥控协议在 `Sources/SonyRemoteKit/Sony/SonyCamera.swift`。`swift build --product fake-sony-camera` 后运行 `sh Tests/AppFeatureChecks/run.sh --tether $(swift build --show-bin-path)/fake-sony-camera`（模拟相机监听 127.0.0.1:15740，缓存写在临时目录）。

大疆无线：协议层在 `Sources/SonyRemoteKit/DJI/`（`DUML` 帧与 CRC、`DJIManifest` 文件列表、`DJIDatalink` UDP 会话、`DJIBluetooth` 配对、`DJICameraLibrary` 实现 `CameraLibrary`），加入热点在 App 的 `Camera/DJIWiFi.swift`，连接流程在 `AppModel+DJI.swift`。协议资料和 Pocket 3 列表样本来自 osmosis / OsmoOffload（MIT，见 `THIRD_PARTY_NOTICES.md`）。`swift test --filter DJI` 覆盖帧编码（对照协议文档里的十六进制样例）、真实列表解析和模拟 Pocket 3 的端到端下载/续传；蓝牙、Wi-Fi 加入和真机行为只能实机验证，调试时看日志里以「大疆」开头的行。

工作流程检查使用 `Tests/AppFeatureChecks/run.sh --workflow`，验证旧模式兼容、推荐设置、自定义命名保留和只切换流程不改现有选项。检查程序使用自己的偏好设置域，结束后恢复该域，不改已安装应用的设置。

整理与导入偏好检查使用 `Tests/AppFeatureChecks/run.sh --organization`。检查程序创建自己的临时卡和偏好设置域，覆盖照片/视频独立目录、项目类型（含旧项目沿用原全局选择）、仅视频的下游计划、镜像备份内容校验、旧副本保留、跨日期项目、隐藏选择和路径预览。

项目结果使用独立的 `MiniDiT/import-journal.sqlite`，按文件增量提交，不重写原有 `history.json` / `sessions.json` 格式。

来源身份检查使用 `Tests/AppFeatureChecks/run.sh --identity`（可加 `--render`）：使用临时档案和独立偏好域，覆盖同名不同卡、挂载路径变化、重复卷标识、容量冲突、无 UUID 手动确认、本地目录身份、卡别名与相机设置隔离、连接切换、历史快照和同卡不同机身照片的逐文件 EXIF。卡档案保存在 `MiniDiT/card-identities.json`，不向存储卡写入识别文件。`Sources/MiniDiTCore/SourceIdentity.swift` 定义纯识别规则与导入快照，`SourceIdentityStore` 管理持久卡档案和当前连接绑定。照片仅有机型/序列号而无曝光参数时也保留元数据。

卡类型：`CardMediaProbe` 从卷对应 IOMedia 的提供者链读取 `Card Characteristics / Card Type` 和 `Protocol Characteristics / Physical Interconnect`；`CardMediaType` 负责保守分类。不要从 USB 产品名或 NVMe 接口推测 CFexpress A/B，也不要把 SDXC 当作全尺寸 SD 的证明。`SourceIdentityTests` 覆盖模糊和冲突报告、通用传输协议及快照序列化；`--identity --render` 输出卡来源和 Wi-Fi 来源详情截图。

项目导入与补备份检查使用 `Tests/AppFeatureChecks/run.sh --journal`，可加 `--render` 渲染结果页。检查使用临时项目、卡、历史索引、项目文件和日志路径，不更改已安装应用的偏好、项目和导入记录；覆盖照片/视频与代理/XML 的真实导入、跳过当次备份后的计划保留、移除原卡后补备份、单项内容变化失败后的其余副本保留、失败记录跨重启、重复执行、离线目标、主文件先记录再取消备份、旧记录迁移及损坏日志不覆盖。补备份核心单元测试位于 `ImportJournalTests.swift`，还覆盖同大小内容变化、路径越界与符号链接、冲突文件保留及本任务临时文件恢复。

项目页面布局检查使用 `Tests/AppFeatureChecks/run.sh --project-layout`，验证空项目和已有文件项目在最小、默认宽度下的布局。

### 项目导入约束

- `beginImport()` 先检查 `currentSession`，再检查备份、空间及后期软件。无项目时创建 `NewSessionPrompt(importAfter: true)`，不隐式调用 `createSession()`。
- `ProjectSidebar` 不自动选择最近项目；移除当前项目时将目标设为 `nil`。项目列表和事件名称仍保留。
- `currentSessionJob()` 将项目 ID、名称及事件写入任务；`startImport(jobs:)` 拒绝缺少有效 `appSession` 的任务，并保留被拒绝任务之前的续传状态。自动导入复用同一任务生成逻辑，无目标时提示并停止。
- `continueImport()` 使用原任务冻结的项目和路径，侧栏后来选择的其他项目不能改变归属。
- `NewSessionSheet` 的目录选择先保存在本地状态。确认新建时写入对应媒体的存放设置；取消不修改设置。通过底栏确认新建后重新调用 `beginImport()`，不能跳过备份或空间检查。
- `FileDragSource` 拖到项目时走普通导入；拖到 Finder 时交给独立的 `FileExport`，无需项目，也不写项目记录或执行备份。

项目约束检查使用 `Tests/AppFeatureChecks/run.sh --project-import`。检查使用独立偏好域、临时卡、项目文件和导入记录，覆盖全部媒体范围及照片软件模式的无项目拦截、取消不写文件、失效项目 ID、低层任务拦截、直接拖出、实际项目归属、备份检查、续传归属和移除目标后的状态。

### CLI 与 MCP

原生入口为 `Sources/minidit/main.swift`，CLI 和 MCP 共享 `AgentTools` 参数 schema，经仅限当前用户的 Unix socket 调用 `AppModel+Agent`，复用 GUI 的导入和项目记录。应用启动时启用服务；隔离模型只在显式调用 `startAgentControl(path:)` 后监听。修改操作在主 actor 上串行处理，传输任务继续由现有异步流程负责。

`swift test --filter AgentProtocolTests` 检查消息、参数和端点权限；`Tests/AppFeatureChecks/run.sh --agent` 通过临时应用实例和真实 CLI 验证 socket、MCP、计划失效、幂等启动和实际项目导入。构建、安装和协议边界见 [CLI 与 MCP](AGENT-CONTROL.md)。

### 虚拟相机与协议联调

不用相机联调：启动模拟相机（带两张卡；加 `-no-remote` 模拟不支持远程传输的相机），然后在 MiniDiT 里连接 `127.0.0.1`。

```bash
swift run fake-sony-camera 15740
```

SSH 端到端测试（需要装了 paramiko 的 Python）：

```bash
PYTHON=/path/to/python Scripts/test-ssh-e2e.sh
```

重新编译 SSH 库（会下载源码并校验 SHA-256，大约 10 分钟）：

```bash
Scripts/build-libssh2-xcframework.sh
```

### 项目结构

```
Apps/MiniDiT/MiniDiT/
  App/                          入口、日志、AppModel（按职责拆成 +Source / +Sources / +Library / +Import / +Sessions / +Background）
  Camera/                       搜索相机、钥匙串账号、连过的相机
  Import/                       单个文件的导入、导入记录、Capture One、Lightroom Classic、Resolve、FCP
  Views/                        三栏浏览、设备与筛选、项目及照片/视频分类、设置向导、设置；Theme.swift 是统一的颜色、字号和分段控件
Apps/MiniDiT/scripts/           release.sh：签名、公证、打包；publish-release.sh：发布到 GitHub；install-cli.sh：安装 minidit 命令
Sources/SonyRemoteKit/          协议层（无界面）：SSH 隧道、PTP/IP、索尼 SDIO、内容传输和远程传输
Sources/MiniDiTCore/            和界面无关的逻辑：拍摄分组、选择、媒体筛选、导入记录匹配、原文件拖出、xxHash64
Sources/FakeSonyCamera/         模拟索尼相机（测试和联调用），命令行工具在 Sources/fake-sony-camera/
Tests/                          单元测试和端到端测试
Vendor/CLibssh2.xcframework     预编译的 OpenSSL 3.5.9 + libssh2 1.11.1（版本和校验值见 Vendor/CLibssh2.VERSION）
Scripts/                        编译 SSH 库、SSH 测试服务器
docs/                           协议笔记、功能规划、功能清单、界面规范、开发说明
```

浏览界面的三栏分别由 `ProjectSidebar`、`SourceDateSidebar` 和素材网格组成。项目和媒体子项使用自定义 `ScrollView + VStack`，不依赖 Native List 的系统行高。`FileDragSource` 同时提供 Finder 文件 promise 和应用内项目拖拽类型；拖到项目时调用正常导入任务，拖到 Finder 时只复制文件。

文档：

- [docs/MiniDiT-FEATURES.md](MiniDiT-FEATURES.md)：功能清单与实测记录
- [docs/MiniDiT-ROADMAP.md](MiniDiT-ROADMAP.md)：产品规划
- [docs/MiniDiT-DESIGN.md](MiniDiT-DESIGN.md)：界面规范
- [docs/PROTOCOL.md](PROTOCOL.md)：PTP/IP 和索尼扩展协议笔记

多目标备份检查使用 `Tests/AppFeatureChecks/run.sh --multi-backup`（可加 `--render`）。检查使用独立偏好域、临时卡/目标及日志，覆盖照片、视频、代理/XML 到多个目标的实际内容核对、离线失败隔离、停用目标、冻结计划、目录重叠拒绝、逐目标 MHL、保留原卡、重开后从其他备份恢复、添加/迁移目标、幂等重试和第二目标复制中取消。`BackupTargetsTests` 覆盖必需/可选汇总、记录序列化、目标身份与无工作文件恢复；`--agent` 另验证第二目标变化使计划失效及离线目标的必需性检查。上述检查不能替代真实外置盘拔插及物理设备身份验收。

`BackupDestination` 保存稳定目标 ID、根目录、卷 UUID、启用和必需性；每批记录冻结目标快照，逐资产 `targetErrors` 与副本 `targetID` 隔离结果。原位置字段仅用于保留本机已有配置/记录，不作为多目标的事实来源。复制按文件、按目标顺序执行；每份完成后立即提交，禁止以一个目标失败清除其他目标的结果。副本数量代表可访问路径数，不代表物理设备数或新近内容复核。

物理盘判断：`PhysicalDiskProbe` 在后台调用系统 `diskutil list -plist physical` 与各挂载卷的 `diskutil info -plist`，按挂载卷合并查询并限制单次等待。`PhysicalDiskMap` 只将系统明确列为 physical 的整盘/分区计为物理设备；APFS 卷与快照通过 `APFSPhysicalStores` 追溯，所有成员均已识别且集合不相交才确认不同硬盘，任一已知成员相交即判定共用。网络盘、磁盘映像、无法映射的 RAID/虚拟盘维持未知，不从名称、不同 UUID 或 USB 端口推断独立性。BSD 设备名只用于当次查询，不写入配置或历史；挂载及路径变化会使结果失效。`PhysicalDiskIdentityTests` 覆盖拓扑边界，`run.sh --disk-identity` 检查真实卷查询、尚未创建的工作目录、同盘/不同盘提示、未知与停用目标、挂载失效刷新；`--live / /Volumes/盘名` 可只读输出指定位置的当前映射。

备份位置编辑使用目标 ID 和值快照，禁止在 `ForEach($model.backupTargets)` 的删除闭包中再次读取行绑定。原生菜单/控件可能在删除后保留绑定，`BackupTargetBindings` 必须在每次读写时按 ID 查找；目标已移除则读取关闭状态、忽略写入，不把变化写到移位后的其他目标。`--multi-backup` 覆盖实际菜单共用的删除操作与保留绑定，包括中间/首个/最后一个目标、重复删除、列表持久化及目录保留。

交接报告：`HandoffReport.snapshot` 只读取给定项目的已冻结批次并执行文件可读性/大小检查，不重算素材哈希；后台导出入口位于 `HandoffExportSheet`。`HandoffPDF` 使用 Core Graphics/Core Text 原生分页，照片用 Image I/O 读取缩略图，视频用 AVFoundation 从记录内可访问副本抽帧，按整份报告的统一时间比例绘制连续胶片条；逐项回传进度并检查取消。图像按 JPEG 压缩嵌入，避免大量素材产生过大的 PDF。`HandoffPackage.write` 使用独立暂存目录，生成 PDF/CSV/JSON 并收集 MHL 历史后原子移入唯一新目录，取消只清理本次目录。`HandoffReportTests` 和 `run.sh --multi-backup --render` 覆盖失败、仅代理、历史核验/当前状态、CSV/PDF、版本保留、真实四类实体文件及补备份后重新导出。报告输出不修改 journal 和媒体。


### 视频软件发送与重试

`Tests/AppFeatureChecks/run.sh --video-delivery --render` 使用隔离临时卡、项目、偏好域和数据库，执行原片/代理/XML 的实际文件导入，再注入软件成功、失败和部分接收响应。覆盖计划快照、重开后无原卡重试、原 Resolve 项目绑定、连续点击、旧批次回执隔离、缺失文件、未知 FCP 接收结果及已修改交接文件保护；`--render` 在 `/tmp/minidit-delivery-ui` 输出明暗外观。

同一检查还运行 `ResolveDeliveryChecks.py`，将生产 Resolve 脚本的媒体池逻辑放入确定性的 API 替身，验证部分导入恢复、全媒体池去重、用户移动媒体夹、路径别名、标记保留、代理/元数据恢复、项目切换和并发锁。它不连接真实 Resolve，也不修改 FCP 资源库。真实软件端导入仍需另行实测。模型与文件预检查由 `VideoDeliveryTests` 覆盖。

发送记录及状态语义见 [后期软件发送](SOFTWARE-DELIVERY.md)。


### Premiere Pro

插件资源位于 `Apps/MiniDiT/MiniDiT/Resources/PremierePlugin.bundle`，随 App 原样打包。`PremierePlugin.makePackage` 在后台将已测试的 5 个文件打为根目录含 manifest 的 CCX，不改 Adobe 的开发者模式或插件注册表。安装由 Creative Cloud 处理，不以“已打开安装器”推断插件安装成功；只有插件面板的有效心跳代表已连接。

`PremiereBridge` 通过当前用户的 `Application Support/MiniDiT/Premiere` 交换类型固定的 JSON 请求，只提供 identify/import。原生端为每次请求生成 UUID、有效期和定时续期的租约。插件以原子移动认领请求，串行执行；每次修改前检查租约和原项目标识。超时、取消或应用退出后不在下次打开时盲目重放旧任务。导入回执包含实际找到的文件，不能仅凭 importFiles 返回 true 就记为成功。

检查：`Tests/AppFeatureChecks/run.sh --premiere` 验证原生通信、租约、错误任务回执拒绝、超时/取消清理及 CCX 完整性；`--video-delivery --render` 同时覆盖 PR 的实际临时卡导入、冻结计划、部分接收、换项目拦截、重启后无原卡重试和回执隔离。`node --test Tests/AppFeatureChecks/PremierePluginChecks.cjs` 直接执行生产接收器和邮箱代码，使用官方 API 形状的替身覆盖素材箱、部分导入、跨素材箱去重、用户代理/标记保留、项目切换、过期租约和重复轮询。`PremiereHandoffTests` 覆盖目录分组、同名不同文件、规范路径、代理与标记的持久化。

真实 PR 安装与导入尚未验证；不得将这些隔离检查写成 PR 实测。API 和产品边界见 [Premiere Pro 连接](PREMIERE.md)。


### 实况照片导出

`LivePhotoWindow` 默认选择约 3 秒，也接受显式 In / Out 范围和独立封面；将区间及封面对齐到输出帧率，最短 0.5 秒，处理片头/片尾、短片和非零轨道起点。`LivePhotoWindowTests` 覆盖边界、可变时长与无效参数。`LivePhotoEditor` 用稳定 UUID 管理手动片段的添加、选择与移除，并分别保留手动片段及各 Shot Mark 的独立选择，`LivePhotoTimeline` 提供三个独立拖动手柄与键盘/辅助功能逐帧调整；预览结束点及导出计划均使用选中的范围。`LivePhotoExporter` 使用 AVFoundation 读取选定区间，按画面变换生成最高 4K/60fps 的 H.264 SDR 与 AAC 音频；不改原文件。Apple 输出写入共享 content identifier、JPEG MakerApple 标识及 still-image-time 定时元数据，并在发布前用 PHLivePhoto 读取配对文件。Motion Photo 使用 1.0 Camera/Container/Item XMP，JPEG 之后紧接完整 MP4。输出在同目录暂存后发布，同名不覆盖，失败/取消清理未完成文件。

`LivePhotoExportSheet` 提供封面、片段预览、按有效且去重的 Shot Mark 批量导出及格式选择。可从来源视频预览或项目内视频右键菜单打开。Photos 只在点击“存入照片”时申请 addOnly 权限；一个批次的生成文件准备完成后，再通过 PHAssetCreationRequest 的 photo + pairedVideo 提交。系统提交期间不提供伪取消。文件导出不请求照片权限。

使用 `sh Scripts/make-live-photo-fixtures.sh <新目录>`（需要 ffmpeg）生成纯合成测试素材，然后运行 `Tests/AppFeatureChecks/run.sh --live-photo <目录> --render --keep`。检查包括系统 Live Photo 识别、共享 ID、封面时间、AAC 音频、XMP 与内嵌 MP4 偏移、旋转、静音/短片/HLG、同名保留、途中取消与源文件散列不变。`--render` 输出明暗窗口到 `/tmp/minidit-live-ui`。在图形登录会话中追加 `--interaction` 可检查三个手柄的实际鼠标拖动。检查不会向照片图库写入内容。`--single <视频>` 可用自己的视频生成两种样例并验证原片未改动。

已用本地真实 3840×2160 H.264 + PCM 视频完成两种导出，并通过 PHLivePhoto 的配对识别及原片散列检查。未自动向用户照片图库写入测试资产，iPhone/Android 及社交应用分享兼容仍需实机验证。更多范围见 [实况照片](LIVE-PHOTO.md)。

camctl（相机控制命令行，目前只有只读摸底）：`Sources/camctl/main.swift`，读取逻辑在 `Sources/SonyRemoteKit/Sony/SonyPropertyDump.swift`。`camctl props --host IP [--user 用户名] [--raw-out 文件]` 以遥控模式连接，列出相机报告的全部属性（编号、类型、可写、当前值、可选值或范围，已知编号带名称和可读值），不发送任何设置或按键操作。解析中途停下时 `parseError` 说明位置，`--raw-out` 保存原始数据供离线核对。本机身份和 SSH 指纹存在 `~/Library/Application Support/camctl/`。测试：`swift test --filter SonyPropertyDump`。
