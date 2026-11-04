# MiniDiT

Mac 上的「小号 DIT」：通过 Wi-Fi 连接索尼 α 相机，按拍摄日期浏览卡里的照片，下载后直接建好 Capture One 会话。

> 早期 demo。功能规划见 [docs/MiniDiT-ROADMAP.md](docs/MiniDiT-ROADMAP.md)。
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

## 项目结构

```
Apps/MiniDiT/MiniDiT.xcodeproj  Mac 工程（SwiftUI，本机签名运行）
Apps/MiniDiT/MiniDiT/
  App/                          入口、AppModel、日志
  Camera/                       搜索相机、钥匙串账号、连过的相机
  Import/                       导入记录、Capture One（AppleScript）
  Views/                        连接、浏览、设置、会话、身份验证界面
Sources/SonyRemoteKit/          协议层（无界面）
  Transport/ SSH/ PTP/ PTPIP/   字节流、SSH 隧道、PTP 和 PTP/IP
  Sony/                         SDIO 握手、属性、内容传输、远程传输
  Camera/ Discovery/            对上层的接口、查找相机
Sources/FakeSonyCamera/         模拟索尼相机（测试和联调用）
Sources/fake-sony-camera/       模拟相机命令行工具
Sources/ssh-e2e/                SSH 端到端测试
Tests/SonyRemoteKitTests/       单元测试和端到端测试
Vendor/CLibssh2.xcframework     预编译的 OpenSSL 3.5.9 + libssh2 1.11.1（版本和校验值见 Vendor/CLibssh2.VERSION）
Scripts/                        编译 SSH 库、SSH 测试服务器
docs/                           协议笔记、功能规划
```

## 编译运行

需要 Xcode 16 以上，以及 Apple 芯片的 Mac。

```bash
open Apps/MiniDiT/MiniDiT.xcodeproj
```

直接运行即可，用的是本机签名，不需要开发者账号。第一次导入时，macOS 会询问是否允许 MiniDiT 控制 Capture One。

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

1. **相机设置**
   - MENU → 网络 → 连接/遥控拍摄 → 遥控拍摄功能 → **遥控拍摄：开**。
   - 让相机连上 Mac 所在的 Wi-Fi。
   - 第一次连接时，要输入相机上显示的用户名和密码，并核对指纹。这些信息在相机的 MENU → 网络 → 网络选项 → 访问认证信息里。
   - 相机同一时间只接受一个遥控端，先断开 Creators' App。
2. **找相机**：点「搜索相机」，或者直接输入相机的 IP。连过的相机按 SSH 指纹记住，IP 变了也能认出来。
3. **浏览**：左边按拍摄日期列出，按住 ⌘ 可以多选；右边是缩略图。
4. **导入**：点「导入到新会话…」，输入会话名（比如 `3.15-公园`），也可以加入已有的会话。新会话默认放在 C1 当前打开的会话所在的文件夹。

   设置里可以改会话存放位置，也可以换成其他模式：导入到 C1 当前打开的目录，或者只下载到文件夹。

## 不用相机联调

在 Mac 上启动模拟相机。它带两张卡；加 `-no-remote` 可以模拟不支持远程传输的相机。

```bash
swift run fake-sony-camera 15740
```

然后在 MiniDiT 里连接 `127.0.0.1`。

## 排查问题

连接页和浏览页都有「复制诊断信息」，里面有网络状况、SSH 协商结果、列目录方式和缩略图格式，不包括密码。出错时，提示里会带上 PTP 操作码和响应码，可以对照 [docs/PROTOCOL.md](docs/PROTOCOL.md) 排查。

## 许可证

[MIT](LICENSE)。预编译的 OpenSSL、libssh2 使用各自的许可证，见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。
