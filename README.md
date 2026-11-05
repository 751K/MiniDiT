# MiniDiT

Mac 上的「小号 DIT」：通过 Wi-Fi 连接索尼 α 相机（或者插读卡器），按拍摄日期浏览卡里的照片，下载后直接建好 Capture One 会话。

> 早期版本（v0.3）。功能规划见 [docs/MiniDiT-ROADMAP.md](docs/MiniDiT-ROADMAP.md)。
>
> **Sony / 索尼是索尼集团的商标，本项目与索尼没有关联。** 本项目根据公开资料独立实现了 PTP/IP 和索尼 SDIO 扩展协议，参考了 libgphoto2、alpha2go 等开源项目，没有复制它们的代码。协议笔记见 [docs/PROTOCOL.md](docs/PROTOCOL.md)。

## 现状

**实机验证**：A7 V（ILCE-7M5）连家里的 Wi-Fi，开着访问身份验证（SSH）。

| 功能 | 状态 |
|---|---|
| 搜索相机（扫描子网，按 SSH 指纹认出连过的相机） | ✅ |
| 访问身份验证（核对指纹，账号存进钥匙串，之后自动登录） | ✅ |
| 浏览存储卡（远程传输 0x923B–0x923E；双卡槽；有缩略图；相机不支持时退回内容传输模式） | ✅ |
| 按拍摄日期分组；按卡槽、类型筛选；只看没导入过的 | ✅ |
| 导入到新建的 C1 会话（命名「月.日-内容」，照片直接存进 Capture 文件夹） | ✅ 用模拟相机测过 |
| 已经下载到本地的文件不重新下载 | ✅ |
| 读卡器 / 本地存储卡（和 Wi-Fi 共用导入记录；拍摄时间读 EXIF / 视频 XML） | ✅ |
| 按天勾选导入；RAW + JPG/HEIF 合成一格；访达式选择（⇧ 连选、⌘ 加选、框选、方向键、⌘A） | ✅ |
| 大图预览（空格；← → 翻页，P 选中） | ✅ |
| 一键全选 / 取消全选；设置里查看和 Capture One 的连接情况（运行、自动化授权、当前会话） | ✅ |
| 启动时自动连接上次的相机；会话内容名记住最近用过的 | ✅ |
| 导入记录按机身序列号区分 | ✅ |
| 识别机型和固件（ILCE-7M5 显示为「α7 V · 固件 2.00」） | ✅ |
| 在侧栏切换相机、卡槽或读卡器（先确认目标在线再断开当前的） | ✅ |
| 「分别记录」（RAW 在卡 1、HIF 在卡 2）合成一格；「同时记录」两张卡的同一文件只导一份 | ✅ |
| 相机掉线后自动重连，保留浏览内容和选择；导入中断后可以继续导进同一个会话；没传完的文件从断开处接着传 | ✅ |
| 第二份备份到另一块盘（「年-月-日-事件」文件夹），两份都用 xxHash64 校验；读卡器来源是卡 → 盘端到端校验；没接备份盘时提醒，之后再导一次补上 | ✅ v0.3 |
| 导入前检查主盘和备份盘的剩余空间；传输时显示速度和剩余时间 | ✅ v0.3 |
| 每个文件的备份状态：缩略图标「两份 / 一份」，侧栏每天一个盾牌，标题下方显示整张卡能不能格式化 | ✅ v0.3 |
| 导入报告：每次导入在保存位置和备份盘各写一份 ASC MHL v2.0 校验清单（`ascmhl/` 文件夹），可以用 `ascmhl verify` 复查 | ✅ v0.3 |
| 导入后删除存储卡上的照片（仅读卡器；只删和卡上数据核对过、且备份成功的照片；视频不删；写保护的卡会提示） | ✅ v0.3 |
| 按时间间隔分场次：同一天相邻两张隔得比设定久（默认 2 小时）就分成两场，侧栏和网格里可以按场次勾选、跳转 | ✅ v0.4 |

## 项目结构

```
Apps/MiniDiT/MiniDiT.xcodeproj  Mac 工程（SwiftUI）
Apps/MiniDiT/MiniDiT/
  AppIcon.icon                  App 图标（Icon Composer 文档）
  App/                          入口、日志、AppModel（按职责拆成 +Source / +Library / +Import）
  Camera/                       搜索相机、钥匙串账号、连过的相机
  Import/                       单个文件的导入（FileImporter）、导入记录、Capture One（AppleScript）
  Views/                        连接、浏览、设置、会话、身份验证界面
Sources/SonyRemoteKit/          协议层（无界面）
  Transport/ SSH/ PTP/ PTPIP/   字节流、SSH 隧道、PTP 和 PTP/IP
  Sony/                         SDIO 握手、属性、内容传输、远程传输
  Camera/ Discovery/            对上层的接口、查找相机
Sources/MiniDiTCore/            和界面无关的逻辑：拍摄分组、选择、导入记录匹配、xxHash64
Sources/FakeSonyCamera/         模拟索尼相机（测试和联调用）
Sources/fake-sony-camera/       模拟相机命令行工具
Sources/ssh-e2e/                SSH 端到端测试
Tests/SonyRemoteKitTests/       单元测试和端到端测试
Vendor/CLibssh2.xcframework     预编译的 OpenSSL 3.5.9 + libssh2 1.11.1（版本和校验值见 Vendor/CLibssh2.VERSION）
Scripts/                        编译 SSH 库、SSH 测试服务器
Apps/MiniDiT/design/            平面版图标 SVG 和渲染脚本
docs/                           协议笔记、功能规划
```

## 编译运行

需要 Xcode 26 以上（Liquid Glass 和 `.icon` 图标要用），以及 Apple 芯片的 Mac。App 支持 macOS 14 以上，在 macOS 26 以上才有液态玻璃效果。

```bash
open Apps/MiniDiT/MiniDiT.xcodeproj
```

工程用「Apple Development」证书签名（团队 HGXZB3UC25）。自己编译时，在 Signing 里换成自己的团队；没有开发者账号就把签名身份改成「Sign to Run Locally」。用临时签名也能运行，只是每次重新编译后，钥匙串都会再问一次能不能读取相机账号。

第一次导入时，macOS 会询问是否允许 MiniDiT 控制 Capture One。

运行测试：

```bash
swift test
```

SSH 端到端测试（需要装了 paramiko 的 Python）：

```bash
PYTHON=/path/to/python Scripts/test-ssh-e2e.sh
```

重新编译 SSH 库（会下载源码并校验 SHA-256，大约 10 分钟）：

```bash
Scripts/build-libssh2-xcframework.sh
```

## 使用

1. **第一次打开**：选择导入方式：照片存在哪里、是否同时备份到另一块盘、导入后是否删除存储卡上的照片。以后在「设置 › 导入」里改，导入栏上的「备份」「删除原片」两个开关也能按次切换。
2. **相机设置**
   - MENU → 网络 → 连接/遥控拍摄 → 遥控拍摄功能 → **遥控拍摄：开**。
   - 让相机连上 Mac 所在的 Wi-Fi。
   - 第一次连接时，要输入相机上显示的用户名和密码，并核对指纹。这些信息在相机的 MENU → 网络 → 网络选项 → 访问认证信息里。
   - 相机同一时间只接受一个遥控端，先断开 Creators' App。
3. **找相机**：点「搜索相机」，或者直接输入相机的 IP。连过的相机按 SSH 指纹记住，IP 变了也能认出来。
4. **浏览**：左边按拍摄日期列出。勾选某天，就是选中这一天没导过的照片，这一天也会显示在右边；点日期只是查看（按住 ⌘ 可以多选）。一天里分了场次时，日期下面列出每一场的时间段，勾选框选这一场，点时间段跳到这一场；场次间隔在「设置 › 导入 › 场次」里改。右边和访达一样选：单击、⌘ 单击、⇧ 单击、拖动框选、方向键、⌘A；空格看大图。
   侧栏上面可以切换卡槽、换另一台连过的相机，或者换成读卡器。也可以把存储卡插到读卡器上，在「选择来源」页点那张卡。
5. **导入**：点「导入到新会话…」，输入会话名（比如 `3.15-公园`），也可以加入已有的会话。新会话默认放在 C1 当前打开的会话所在的文件夹。

   每个文件先存第一份，再复制到备份盘，两份都读回来比对 xxHash64，通过了才算导好；哈希和两份的位置记在导入记录里。备份盘没接上时会先提醒，可以只存一份继续；接上以后对这些照片再导入一次，会补上第二份。

   设置里可以改会话存放位置，也可以换成其他模式：导入到 C1 当前打开的目录，或者只下载到文件夹。「设置 › 软件」显示 Capture One 有没有装、在不在运行、有没有允许 MiniDiT 控制，以及当前打开的会话。

## 不用相机联调

在 Mac 上启动模拟相机。它带两张卡；加 `-no-remote` 可以模拟不支持远程传输的相机。

```bash
swift run fake-sony-camera 15740
```

然后在 MiniDiT 里连接 `127.0.0.1`。

## 排查问题

设置 › 记录 里有「复制日志」，内容包括网络状况、SSH 协商结果、列目录方式和缩略图格式，不包括密码。出错时，提示里会带上 PTP 操作码和响应码，可以对照 [docs/PROTOCOL.md](docs/PROTOCOL.md) 排查。

## 许可证

[MIT](LICENSE)。预编译的 OpenSSL、libssh2 使用各自的许可证，见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。
