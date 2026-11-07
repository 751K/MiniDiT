# MiniDiT

从相机到电脑这一段，交给 MiniDiT。

通过 Wi-Fi 连接索尼 α 相机（不用拔卡），或者插读卡器，按拍摄日期浏览卡里的照片和视频，导入到你建的会话里。每个文件存两份并校验；导入时按会话名建好 Capture One 会话或 Lightroom Classic 收藏夹，视频交给 DaVinci Resolve 或 Final Cut Pro。

> 早期版本（v0.8），仅支持 Apple 芯片的 Mac、macOS 14 以上。功能规划见 [docs/MiniDiT-ROADMAP.md](docs/MiniDiT-ROADMAP.md)。
>
> **Sony / 索尼是索尼集团的商标，本项目与索尼没有关联。** 本项目根据公开资料独立实现了 PTP/IP 和索尼 SDIO 扩展协议，参考了 libgphoto2、alpha2go 等开源项目，没有复制它们的代码。

## 能做什么

**连接**
- Wi-Fi 连接相机，支持访问身份验证（SSH）；连过的相机按指纹记住，IP 变了也认得出。
- 读卡器：插卡就打开，也可以设为自动导入。
- 同时打开几台相机、几张卡，按拍摄时间合在一起看；每台相机可以只看卡 1 或卡 2。
- 相机掉线自动重连，浏览内容和选择都保留；导入中断后从断点续传。

**浏览**
- 按拍摄日期列出，也可以按时间间隔分成场次；RAW 和 JPG/HIF 合成一格。
- 和访达一样选（⇧ 连选、⌘ 加选、框选、方向键、⌘A），空格看大图和拍摄参数。
- 显示机内星级、视频的 Shot Mark、时长、伽马和帧率。

**会话**
- 会话就是一次拍摄（日期 + 事件），由 MiniDiT 管理，在侧栏「会话」里新建和切换。
- 导入时会话名沿用到下游：Capture One 会话、Lightroom 收藏夹、下载文件夹、视频文件夹。
- 导入过的文件记在会话里，没连相机时也能翻看。

**放心导入**
- 每个文件存两份（第二份在另一块盘），两份都读回来比对 xxHash64。
- 每次导入写一份 ASC MHL 校验清单；导入前检查两块盘的空间。
- 用读卡器时可以在导入后删除卡上的照片（只删核对过、备份成功的）。

**交给后期**
- Capture One：建好会话，照片直接存进 Capture 文件夹；可按创意外观自动套 Look。
- Lightroom Classic：通过插件逐张加入当前目录，RAW+JPG 自动叠放。
- 只下载到文件夹，导完用访达、Adobe Bridge 或 DxO PhotoLab 打开。
- 视频单独存放，代理和 XML 一起导；可以加入 DaVinci Resolve 当前项目或交给 Final Cut Pro，带卷号和 Log 设置。
- Wi-Fi 导视频时可以只导代理，原片留在卡上。

**后台**
- 关掉窗口后留在菜单栏；连过的相机开机后发通知，可以设为自动导入新照片。

每项功能的细节和实测情况见 [docs/MiniDiT-FEATURES.md](docs/MiniDiT-FEATURES.md)。

## 开始使用

1. **设置向导**：第一次打开时，依次选择使用方式（个人 / 专业）、照片导入到哪里（Capture One、Lightroom Classic 或只下载）、视频存在哪里、是否同时备份。个人方式会隐藏不常用的设置。之后可以在「设置 › 通用」里重新打开向导。
2. **准备相机**（用 Wi-Fi 时）
   - MENU → 网络 → 连接/遥控拍摄 → 遥控拍摄功能 → **遥控拍摄：开**，并让相机连上 Mac 所在的 Wi-Fi。
   - 第一次连接时，输入相机上显示的用户名和密码，并核对指纹（相机的 MENU → 网络 → 网络选项 → 访问认证信息）。
   - 相机同一时间只接受一个遥控端，先断开 Creators' App。
3. **选择来源**：点相机或「搜索相机」，也可以直接输入 IP；插着的存储卡也列在这里。
4. **浏览**：左边是拍摄日期，点日期查看，勾选日期就选中这一天没导入过的内容。
5. **建会话**：在侧栏「会话」里点「＋」，选日期（默认是正在看的那天）、填事件名，比如「公园」，会话名按模板生成为「3.15-公园」。点一下会话就把它设为导入目标。
6. **导入**：勾选要导入的内容，点底栏的「导入」。还没有会话时会先请你新建一个。导入完成后，在会话上悬停点箭头，可以查看导进来的文件。

**Lightroom Classic**：先在「设置 › 软件」里点「安装插件」（LrC 开着时装完要重启一次），再在「设置 › 照片」里选「导入到 Lightroom Classic」。用读卡器时，建议在 LrC 的「偏好设置 › 常规」里关掉「检测到存储卡时显示导入对话框」。

**DaVinci Resolve**：在 Resolve 的偏好设置里把「外部脚本使用」设为「本地」，再在「设置 › 视频」里打开「导入后加入 DaVinci Resolve 当前项目」。

## 编译

需要 Xcode 26 以上（液态玻璃和 `.icon` 图标要用）。

```bash
open Apps/MiniDiT/MiniDiT.xcodeproj
```

工程用「Apple Development」证书签名（团队 HGXZB3UC25）。自己编译时，在 Signing 里换成自己的团队；没有开发者账号就改成「Sign to Run Locally」，只是每次重新编译后，钥匙串都会再问一次能不能读取相机账号。

第一次导入时，macOS 会询问是否允许 MiniDiT 控制 Capture One。

## 开发

运行测试：

```bash
swift test
```

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
  Views/                        来源、浏览、会话、设置向导、设置；Theme.swift 是统一的颜色、字号和分段控件
Sources/SonyRemoteKit/          协议层（无界面）：SSH 隧道、PTP/IP、索尼 SDIO、内容传输和远程传输
Sources/MiniDiTCore/            和界面无关的逻辑：拍摄分组、选择、导入记录匹配、xxHash64
Sources/FakeSonyCamera/         模拟索尼相机（测试和联调用），命令行工具在 Sources/fake-sony-camera/
Tests/                          单元测试和端到端测试
Vendor/CLibssh2.xcframework     预编译的 OpenSSL 3.5.9 + libssh2 1.11.1（版本和校验值见 Vendor/CLibssh2.VERSION）
Scripts/                        编译 SSH 库、SSH 测试服务器
docs/                           协议笔记、功能规划、功能清单、界面规范
```

文档：

- [docs/MiniDiT-FEATURES.md](docs/MiniDiT-FEATURES.md)：功能清单与实测记录
- [docs/MiniDiT-ROADMAP.md](docs/MiniDiT-ROADMAP.md)：产品规划
- [docs/MiniDiT-DESIGN.md](docs/MiniDiT-DESIGN.md)：界面规范
- [docs/PROTOCOL.md](docs/PROTOCOL.md)：PTP/IP 和索尼扩展协议笔记

## 排查问题

「设置 › 通用」里有「复制日志」，内容包括网络状况、SSH 协商结果、列目录方式和缩略图格式，不包括密码。出错时，提示里会带上 PTP 操作码和响应码，可以对照 [docs/PROTOCOL.md](docs/PROTOCOL.md) 排查。

## 许可证

[MIT](LICENSE)。预编译的 OpenSSL、libssh2 使用各自的许可证，见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。
