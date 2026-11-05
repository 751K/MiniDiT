# MiniDiT 接入 Lightroom Classic：调研报告

> 2026-11 调研，2026-11-05 在 LrC 15.6 上实测了推荐方案的核心部分（见「实测结果」）。其余标了「未验证」的地方还没有确认。

## 0. 结论

- LrC **没有 AppleScript 字典**，不能像 C1 那样从外部用脚本建项目、导入照片。
- 唯一能**不弹导入对话框**、往目录里加照片的正式途径是 **LrC 插件（Lua SDK）里的 `catalog:addPhoto()`**。这个函数相当于导入对话框里的「添加」：文件留在原处，不复制，不移动。我们本来就自己复制、校验、备份，正好用得上。
- 插件能建收藏夹集、收藏夹、关键字，能写星级、色标和自定义元数据，能套用修改照片预设和元数据预设（12.5 起），也能把界面切到新收藏夹。体验可以做到和 C1 接近：**照片边下载边出现在 LrC 里**。
- 外部 App 和插件之间的通信，推荐用**任务文件夹（JSON 任务单）+ 插件后台轮询**，再加一个 `lightroom://` URL 让插件马上处理。`LrSocket` 作为以后要实时双向通信时的升级路线。
- 不装插件时的备用方案：`open -a` 把项目文件夹交给 LrC，弹出导入对话框，来源已经选好（「添加」模式），用户点一下「导入」。

---

## 1. 推荐方案：MiniDiT 插件 + 任务文件夹

### 用户体验

1. 首次使用：MiniDiT 的「软件」设置里选 Lightroom Classic，点「安装 LrC 插件」。App 把 `MiniDiT.lrplugin` 复制到 `~/Library/Application Support/Adobe/Lightroom/Modules/`，提示用户**重启 LrC 一次**。之后 App 能看到插件的心跳，界面显示「已连接」。
2. 导入时：用户和现在一样选照片、选命名模板、选按天或按场次拆分。MiniDiT 按模板建磁盘文件夹，比如 `<根目录>/10.28-卢森堡/`，把照片下载进去，校验，再备份。
3. 每校验完一个文件，就把它写进任务单。插件 1 秒内收到，把照片 `addPhoto` 进**当前打开的目录**，放进同名收藏夹，然后把 LrC 的视图切到这个收藏夹。用户在 LrC 的图库里看到照片一张张出现，和 C1 的会话一样。
4. 可选设置，都在 MiniDiT 里选：修改照片预设、元数据预设（版权信息），以及是否把场次名写成关键字。预设列表由插件读出来，写进心跳文件交给 App。
5. 导入结束：MiniDiT 的结果行显示「已加入 LrC：312 张，跳过已有 4 张」。这个数字来自插件写的回执。

LrC 没开怎么办：任务单留在任务文件夹里，用户下次打开 LrC 时插件会补上。MiniDiT 也可以在导入开始时主动启动 LrC，和现在的 `CaptureOneBridge.ensureRunning()` 一样。

### 和 C1 的差别（需要提前告诉用户）

- 要装一次插件，装完要重启 LrC。
- 照片进的是**用户当前打开的那个目录**，插件不能切换目录。
- 导入对话框里的「构建智能预览」「1:1 预览」「不导入可能重复的照片」等选项，插件都改不了。去重由我们自己用 `findPhotoByPath` 做。
- 改名、复制、移动、备份都由 MiniDiT 完成，本来就是这样。

---

## 2. 架构草图

```
┌──────────── MiniDiT（Swift）─────────────┐          ┌──────── MiniDiT.lrplugin（Lua，在 LrC 里跑）───────┐
│ FileImporter：下载 → xxHash → 备份       │          │ LrInitPlugin：启动后台任务（LrTasks.startAsyncTask）│
│ LightroomBridge（新的 ImportTarget）：    │          │   循环：LrTasks.sleep(1)，扫 inbox/*.json          │
│  1. 按模板建磁盘文件夹                    │  文件    │   → withWriteAccessDo（每张一个短事务）：           │
│  2. 写 inbox/<jobID>.json（原子 rename）  │ ───────▶ │       findPhotoByPath 去重 → addPhoto(path, nil,  │
│     {catalogHint, project, collectionSet, │          │       nil, metaPresetUUID, devPresetUUID)         │
│      collection, keywords, presets,       │          │   → createCollectionSet / createCollection        │
│      files:[{path, rating, serial,…}]}    │          │     （canReturnPrior=true，同名就复用）            │
│     追加文件时写 <jobID>.<n>.json         │          │   → collection:addPhotos / addKeyword /           │
│  3. 可选：open lightroom://com.minidit…   │ ──URL──▶ │     setRawMetadata('rating') / 自定义元数据         │
│     /poke（让插件马上扫一次）             │          │   → catalog:setActiveSources({collection})        │
│  4. 读 outbox/<jobID>.result.json         │ ◀─────── │   写 outbox/<jobID>.result.json（成功/跳过/失败）  │
│  5. 读 heartbeat.json 判断插件状态        │ ◀─────── │   每 5 秒写 heartbeat.json：LrC 版本、插件版本、    │
│                                           │          │     目录路径、预设列表（名称 + UUID）              │
│ 负责安装或更新 .lrplugin 到 Modules       │          │ LrShutdownPlugin：设退出标志，结束循环             │
└───────────────────────────────────────────┘          └────────────────────────────────────────────────────┘
       IPC 目录：~/Library/Application Support/MiniDiT/LrC/{inbox,outbox,heartbeat.json}
```

为什么首选文件当通道：

- **LrC 没开或插件还没加载时不会丢任务**。`LrSocket` 和 URL 都要求 LrC 正在运行，而且 URL 在 LrC 没开时会丢（见 3.3）。
- 不占端口、不怕防火墙、好调试，任务单本身就是导入记录。
- 轮询的代价可以忽略：1 秒扫一个小目录。开源的 Cull 插件也用「文件 + URL」的做法（见 5.7）。
- 以后要实时进度或请求/应答，再加 `LrSocket`。一个 socket 只能单向，要开一收一发两个（MIDI2LR 就是这样做的）。

### 插件侧要注意

- `withWriteAccessDo` 只能在异步任务里调用，要带 `timeoutParams`。别的写操作占着目录时会超时，要重试。
- **每张照片一个短事务**，不要一个事务包住整批。lightroom-mcp 的源码注释说，整批包在一个事务里会长时间锁住目录，阻塞其他操作。
- 在同一个写事务里新建的对象，事务结束前可能看不到。建收藏夹集、建收藏夹、加照片最好分成几个事务。Cull 和 akrabat 的博文都是这样分的。
- LrC 的文件表**不区分大小写**：同一个文件夹里只有大小写不同的两个文件名会失败（lightroom-mcp 在 15.6 上实测）。我们的命名模板要避开这种情况。

---

## 3. 逐项回答

### 3.1 AppleScript / Apple Events

- LrC **没有可用的 AppleScript 字典**。MacScripter 上有人用 Script Debugger 查过，看不到字典；网上能找到的用法都是 GUI 脚本（模拟点菜单）。Adobe 也没有官方文档提到脚本支持。最新版有没有字典：**未验证**，可以在 Script Editor 里用「打开字典」查。
- `open -a "Adobe Lightroom Classic" <文件夹>` 和把文件夹拖到 Dock 图标效果一样：**弹出导入对话框，来源已选好**。用户报告默认就是「添加」模式（文件不动）。
  - **不能**预先指定目标文件夹、导入预设或收藏夹。对话框沿用上次的设置。
  - 15.0 有一个 bug：LrC 没开时拖文件夹到图标，只会启动 LrC，不弹导入对话框。用户报告 15.0.1 里拖图标卡死的问题没有了，但「没开时不弹对话框」有没有修好：**未验证**。
  - 插件也能做同样的事：`catalog:triggerImportUI(path)` 打开导入对话框并预选来源（Windows 上曾有 bug，2024-01 已修）；`catalog:triggerImportFromPathWithPreviousSettings(path)` 不弹对话框，直接按「上一次导入的设置」导入。后者依赖用户上次怎么设，不可控，社区不推荐。
- LrC 的 Bundle ID 是 `com.adobe.LightroomClassicCC7`，`AppsSettings.swift` 里用前缀 `com.adobe.LightroomClassicCC` 能匹配上。

### 3.2 LrC SDK 插件（Lua）能做什么

`LrCatalog` 相关 API（版本号是 API 加入时的 SDK 版本）：

| 能力 | API | 说明 |
|---|---|---|
| 加照片（原地，不复制） | `catalog:addPhoto(path, stackWithPhoto, position, metadataPresetUUID, developPresetUUID)` | 2.0；两个预设参数是 12.5 加的；必须在 `withWriteAccessDo` 或 `withProlongedWriteAccessDo` 里调用 |
| 查重 | `catalog:findPhotoByPath(path)` | 2.0（有开源项目说它总是不区分大小写） |
| 文件夹 | `catalog:getFolderByPath(path)` | 3.0；**没有** `createFolder`，`addPhoto` 会自动把所在文件夹加进目录 |
| 收藏夹 / 收藏夹集 | `createCollection(name, parent, canReturnPrior)`、`createCollectionSet(...)`、`createSmartCollection(...)` | 3.0 |
| 关键字 | `createKeyword(...)` + `photo:addKeyword` | 3.0 / 4.0 |
| 元数据 | `photo:setRawMetadata('rating'/'label'/'pickStatus'…)`；自定义字段用 `LrMetadataProvider` + `setPropertyForPlugin` | 自定义字段可以存相机序列号、xxHash、备份状态，并且能搜索 |
| 切换视图 | `catalog:setActiveSources({collection})` | 3.0 |
| 写权限 | `withWriteAccessDo(name, func, timeoutParams)`、`withProlongedWriteAccessDo` | 只能在异步任务里调用 |

视频：开源插件 lightroom-live-stack 用 `addPhoto(videoPath, …)` 加视频，所以视频应该也能加。索尼的 XAVC MP4 能不能加：**未验证**。

**限制**（相对导入对话框）：

- 不能复制、移动、改名，也不能选「构建智能预览」或预览尺寸。我们自己处理文件，所以前三项不影响我们。
- 2020 年有开发者说 `addPhoto` 批量导入**慢**，而且总会生成预览（他怀疑是 1:1）。2020 年后有没有变化、现在一张要多久：**未验证，需要实测**。
- 社区的结论是没有别的导入 API：「catalog:addPhoto() is all we've got」（johnrellis，2020）。

**SDK 版本**：

- 14.0（2024-10）：只加了 `deleteAllEmptyMasks`，并改了日志位置。
- 14.3（2025-04）：加了 `LrApplication.shutdown()`。
- 15.0（2025-11）：只多了 `LrApplication.addHapticObserver`。2025-12 有用户下载到了 15.1 SDK。
- 2024–2026 年间**没有和导入相关的新 API**。最近的相关改动还是 12.5 给 `addPhoto` 加的两个预设参数。
- 写这份报告时 LrC 已经到 15.x：lightroom-mcp 提到在 15.6 上实测过；论坛提到 15.2。

### 3.3 外部 App 怎样通知插件

| 方式 | 机制 | 优点 | 缺点 |
|---|---|---|---|
| **任务文件夹 + 轮询（推荐）** | 插件在 `LrInitPlugin` 里启动 `LrTasks` 后台循环，`LrTasks.sleep` 加 `LrFileUtils` 扫目录 | LrC 没开时任务也不丢；简单；好调试 | 有约 1 秒延迟；要处理插件退出（`LrShutdownPlugin` 设标志，循环里检查） |
| `lightroom://<LrToolkitIdentifier>/…` URL | 在 Info.lua 里声明 `URLHandler`，用 `open` 发送 | 不用轮询，马上触发 | 只能单向；**LrC 没开时 URL 会丢**（2024-01 报 bug，Adobe 已开工单，没看到修复记录）；URL 不能太长，所以只适合传「去看任务文件夹」这类信号 |
| `LrSocket.bind` | 插件在 localhost 上监听，`mode` 只能是 send 或 receive，要两个 socket；端口可固定，也可以传 0 由系统分配 | 能实时双向通信、报进度 | 必须在 LrC 运行时才能连；社区反映文档少、难调；用端口 0 时还得用文件告诉 App 实际端口 |
| `triggerImportFromPathWithPreviousSettings` | 插件触发普通导入 | 能用到导入对话框的全部功能 | 设置取决于用户上一次导入，不可控 |

- **插件什么时候初始化**：社区说要让 `LrInitPlugin` 在 LrC 启动时就跑，可以设 `LrForceInitPlugin = true`。老帖子的说法是声明一个隐藏的自定义元数据字段。具体行为：**未验证**。
- **别人怎么做**：
  - MIDI2LR 用两个固定端口（58763 收、58764 发）。
  - lightroom-mcp 和 lightroom-cli 走 socket 加 JSON。
  - Cull 用 URL 带上 manifest 文件路径，再读文件。
  - Adobe 2018 年出过《Lightroom Controller SDK Guide》（外部控制 LrC 的补充文档），讲的就是 `LrSocket` 加插件，13.3 SDK（2024-05）时更新过。

### 3.4 自动导入（监视文件夹）

文件 → 自动导入 → 自动导入设置。根据 Adobe 帮助页和论坛：

- 只能监视**一个**文件夹，设置时这个文件夹**必须是空的**，**不看子文件夹**。
- 检测到的文件会被**移动**（不是复制）到**一个**目标文件夹，可以带子文件夹名。可以设文件命名、修改照片预设、元数据、关键字、初始预览，也可以加入一个收藏夹。
- 不能按日期分文件夹，所以做不到「每天或每场一个项目」。
- SDK 里**没有**读写自动导入设置的 API。设置大概存在目录或偏好设置里（**未验证**），外部改不了。
- 对我们来说，它会把文件从我们校验过的路径挪走，打乱「项目文件夹 + 备份」的结构。**只适合作为最后的退路**。Smart Shooter 在插件不能用时就让用户走这条路。

### 3.5 现有产品怎么交给 LrC

| 产品 | 实际做法 |
|---|---|
| Photo Mechanic | 自己导入（Ingest）到最终文件夹，用户再在 LrC 里用「添加」导入那个文件夹（或拖到图标上）。**没找到自动写入 LrC 目录的功能** |
| ShutterSnitch | 没有直接集成。第三方插件 SnitchSync（Photographer's Toolbox，2011）：把 ShutterSnitch 邮件里的选片列表粘进插件，插件把星级同步到 RAW |
| Hedge / OffShoot | 没找到 LrC 集成。OffShoot 有「File Copy Completed」脚本钩子，还有交给 EditReady 的集成（文件校验完以后通知 EditReady） |
| Sony Imaging Edge / Creators' App | 没找到索尼自己的 LrC 插件。LrC 13.3 起原生支持部分索尼机型的有线联机（基于 Camera Remote SDK，**不支持 Wi-Fi 或 LAN**）。在 Windows 上，Imaging Edge 的驱动会和 LrC 冲突 |
| Tether Tools Smart Shooter | 提供 LrC 联机插件，开始联机拍摄时照片直接进目录。插件用的是哪个接口，官方没说（公开 SDK 里**没有**联机拍摄的接口，**未验证**）。2025-03 起，Windows 上 LrC 原生支持的机型不能再用这个插件。另一条路是 LrC 的自动导入 |
| Capture One「导入 Lightroom 目录」 | 方向相反：C1 **只读** `.lrcat`，而且要先关掉 LrC。不往 LrC 写东西 |
| Cull（开源，2026） | 和我们的方案最像：App 写一个 manifest 文件，再用 `lightroom://com.getcull.shoot/open?manifest=<路径>` 通知插件。插件 `findPhotoByPath` 去重，`addPhoto` 原地导入，建收藏夹集、收藏夹和智能收藏夹（选中、拒绝、未标记），写回执文件，最后 `setActiveSources` |
| lightroom-mcp、lightroom-cli、MIDI2LR | 都是 socket 加插件。lightroom-mcp 的导入处理是 `addPhoto`，每张一个写事务，可以选加入收藏夹 |

### 3.6 直接写 `.lrcat`（SQLite）：排除

- 没有公开的表结构，Adobe 也从没说过可以外部写。每个大版本都可能升级目录格式。
- LrC 运行时自己持有目录，修改先进 WAL 文件。外部写入会和 LrC 的缓存和事务冲突，可能**损坏用户的整个目录**。老版本还会给 `.lrcat` 加文件锁，6.14 到 8.4.1 之间的某个版本起不加了。没有锁，不代表可以安全地写。
- 写进去的照片还缺预览、缓存和关联记录，LrC 未必认。
- 在社区里，连**读**目录都建议在 LrC 关掉时、或者对着副本做。C1 也要求先关掉 LrC。**结论：不做。**

### 3.7 分发和安装

- **两种安装方式**：
  1. 文件 → 增效工具管理器 → 「添加」。LrC 记住插件路径，插件可以放在任何地方。
  2. 把插件放进 `~/Library/Application Support/Adobe/Lightroom/Modules/`，LrC **启动时自动加载**。Adobe 社区专家说这个目录本来就是**留给真正的安装程序用的**，所以 MiniDiT 往这里装是正当用法。
- **MiniDiT 能替用户装和更新**：项目里 `ENABLE_APP_SANDBOX = NO`，App 可以直接写这个目录（目录不存在就先建）。
  - 更新流程：比较 Info.lua 里 `VERSION` 和 App 自带插件的版本，不一样就整体替换，然后提示用户重启 LrC（或在增效工具管理器里重新加载）。LrC 运行时替换插件文件安全不安全：**未验证**。
  - 以后要上 Mac App Store、打开沙盒，就要让用户手动选这个文件夹授权（security-scoped bookmark），或者改成「导出插件，让用户自己去增效工具管理器添加」。
- **签名和公证**：
  - `.lrplugin` 是一个装 Lua 文本或字节码的文件夹，LrC 不检查代码签名，Gatekeeper 也不管 Lua 文件。
  - 插件放在已签名、已公证的 App 包里（比如 `Contents/Resources/MiniDiT.lrplugin`）随 App 分发，由 App 复制出去。这样复制出来的文件没有 quarantine 属性，也不需要单独签名。
  - 风险点：用户从网上下载插件的 zip 时文件会带 quarantine 属性，LrC 会不会因此拒绝加载：**未验证**，估计不会。
  - 注意：别把插件装进 LrC 的 App 包里，会破坏 Adobe 的签名。

### 3.8 概念对应

| MiniDiT | C1（现在） | LrC（建议） |
|---|---|---|
| 一个拍摄项目（例如「10.28-卢森堡」） | 会话 | **磁盘文件夹** `<根目录>/10.28-卢森堡/`（照片原地添加后自动出现在「文件夹」面板）**+ 同名收藏夹** |
| 一次导入拆成几天或几个场次 | 每天或每场一个会话 | 每天或每场：**一个文件夹 + 一个收藏夹**。同一次导入的收藏夹放进一个**收藏夹集**（例如「MiniDiT / 2026-10 卢森堡」），左侧面板里能看出它们是一组 |
| 场次名、地点 | 会话名 | 可选：同时写成**关键字**（例如「MiniDiT > 卢森堡 > 场次 2」）。关键字会随导出文件带走，所以默认关闭，只当搜索的辅助 |
| Capture / Selects / Output / Trash | 会话的子文件夹 | 没有对应。可选：在收藏夹集里加智能收藏夹「选中 / 拒绝」（Cull 就是这样做的） |
| 相机星级、保护标记 | — | `rating`；保护标记可以映射成色标或自定义字段 |
| 相机序列号、xxHash、备份状态 | — | 插件的**自定义元数据字段**（`LrMetadataProvider`），在元数据面板里能看到，也能搜索 |
| C1 导入后打开会话 | 打开会话 | `setActiveSources` 切到收藏夹（多个收藏夹时切到收藏夹集或最新的那个） |

和 ROADMAP 里「LrC 里对应『文件夹 + 收藏夹』」的设想一致。拆分时多加一层收藏夹集。

---

## 4. 备用方案

1. **不装插件（零安装）**：导入完成后执行 `open -a "Adobe Lightroom Classic" <项目文件夹>`（或用 NSWorkspace 打开）。LrC 弹出导入对话框，来源已选好，默认应是「添加」。用户确认目标收藏夹和预设后点「导入」。
   - 每个项目都要手动点一次；不能预设收藏夹；要绕开 15.0 的「LrC 没开时不弹对话框」bug：先启动 LrC，等它就绪再交文件夹。
   - 拆成多个项目时，要么交上一级文件夹（会递归？**未验证**），要么一个个交。
2. **插件装了、但后台循环没起来**：插件在图库菜单里加一项「MiniDiT：导入待处理任务」，手动扫一次任务文件夹（Cull 也有手动入口）。
3. **最后的退路**：自动导入。不推荐，原因见 3.4。

---

## 实测结果（LrC 15.6，2026-11-05）

在独立的测试目录里，用一个最小插件（任务文件夹 + 后台轮询 + `addPhoto` + 收藏夹集 / 收藏夹 + `lightroom://`）测试：

| 项目 | 结果 |
|---|---|
| AppleScript 字典 | **没有**（App 包里没有 `.sdef`），和调研结论一致。注册了 `lightroom://` URL |
| 放进 `~/Library/Application Support/Adobe/Lightroom/Modules/` 自动加载 | ✅ 不用在增效工具管理器里手动添加 |
| `LrForceInitPlugin = true` | ❌ **15.6 不理它**：Init 不在启动时运行，第一次用到插件（收到 `lightroom://` 链接、点它的菜单）才运行。用链接把没开的 LrC 启动起来时也会触发 Init。所以 App 发现 LrC 开着、没有心跳时先发一次唤醒链接，40 秒还没心跳才提示重启 LrC |
| Init 里的错误 | LrC 不报告。正式插件的 Init.lua 只是个外壳，用 `pcall` 加载 Worker，结果写进 `/tmp/minidit-lightroom.log` |
| 在 LrC 运行时删掉重建插件文件夹 | ❌ 之后插件里的脚本都找不到（「No script by the name …」），Init 也不执行；**要完整重启 LrC**。只改文件内容、不重建文件夹时，增效工具管理器里的「Reload Plug-in」可以生效 |
| `addPhoto` 速度 | **每张约 1.1 秒**，和文件大小无关（300 KB 的 HIF 和 41 MB 的 ARW 一样）；10 张放进同一个写事务也还是每张 1.1 秒，开销在 `addPhoto` 本身。一组 RAW+HIF 2.2 秒，比 Wi-Fi 下载一组（约 4 秒）快，边下边加跟得上；读卡器会排队 |
| 预览 | 自动生成**标准预览**（最大 5120 像素，16 张约 67 MB），没有给每张都生成 1:1 预览 |
| 收藏夹集 / 收藏夹 / `setActiveSources` | ✅ 建好后 LrC 直接切到新收藏夹，照片一张张出现 |
| 写事务 | 一张一个事务，用户在两张之间还能操作；10 张放一个事务会把目录锁住 11 秒，不可取 |
| LrC 开着时发 `lightroom://<插件 ID>/…` | ✅ 约 25 毫秒送到插件的 URLHandler |
| LrC 没开时发 URL | LrC 被启动（加载目录约 20 秒），**这条 URL 本身丢了**（和 2024 年报的 bug 一致），但插件启动后扫任务文件夹，照常处理（3 张 3.3 秒）。所以「任务文件夹为主、URL 只用来叫醒」是对的 |
| LrC 的 Lua 环境 | 没有 `os.rename`，要用 `LrFileUtils.move`；`io.open` 可以用 |
| ARW + HIF 成对 | `addPhoto` 把它们当成两张照片分别加入（导入对话框会把 JPEG 当附属文件）。正式插件用 `addPhoto(path, rawPhoto, 'below')` 叠到 RAW 下面 ✅。RAW 必须先在目录里：卡上 HIF 常常先于 ARW 下载，所以 App 让 JPG/HIF 等它的 RAW 交出去后再交 |
| 插上存储卡 | LrC 默认会**自己弹出导入对话框**，和 MiniDiT 抢。插件在对话框开着时照常工作，但要提醒读卡器用户关掉「检测到存储卡时显示导入对话框」 |
| 发 URL 会不会把 LrC 拉到前台 | 用 `NSWorkspace.open`（`activates = false`）不会 |
| 从 MiniDiT 界面端到端 | ✅ 测试卡 4 张（6 个文件）→ 收藏夹「10.17-叠放」，两对 RAW+HIF 叠好，提示条显示「Lightroom Classic 已添加 6 个文件」 |
| 用 AppleEvent 退出 LrC | 会弹「Do you really want to quit?」，所以 App 不能随意替用户重启 LrC，要提示用户自己重启 |

还没测：外置盘 / 多目录、视频、预设 UUID、大批量（几百张）时界面是否卡顿。去重用 `findPhotoByPath`：已在目录里的照片只加进收藏夹（回执里记为 skip）。

---

## 5. 要在装了 LrC 的机器上验证的问题

1. `addPhoto` 的速度：在 SSD 和外置盘上，各加 500 张 ARW 和 500 张 ARW+JPG，每张要多久？会不会生成 1:1 预览，能不能跟目录的「标准预览」设置走？会不会卡住界面？
2. 边下载边导入：每张一个写事务，同时用户在 LrC 里操作，`withWriteAccessDo` 多久会超时？超时后重试的策略对不对？
3. `LrForceInitPlugin = true` 能不能让后台循环在 LrC 启动时就跑起来？插件在增效工具管理器里被重新加载或停用时，`LrShutdownPlugin` 能不能可靠地停掉循环？
4. URL handler：LrC 没开时 URL 还会不会丢？LrC 开着时，发 URL 会不会把 LrC 拉到前台？会不会抢焦点？
5. 视频（XAVC MP4、带 XML 附属文件）能不能 `addPhoto`？ARW+JPG 成对的照片怎么处理（导入偏好里「把 JPEG 单独导入」的设置会不会影响 `addPhoto`）？
6. 在 Modules 里替换插件后，要不要重启 LrC？LrC 运行时覆盖插件文件夹会不会出问题？带 quarantine 属性的插件能不能加载？
7. 去重：`findPhotoByPath` 在 APFS（不区分大小写）和外置 exFAT 盘上的表现。
8. 能不能列出预设：`LrApplication.developPresetFolders()` 和 `metadataPresets()` 能不能拿到 UUID，并交给 `addPhoto`？
9. 用户的目录在外置盘、或者同时有多个目录时，心跳里报出的目录路径对不对？要不要让用户确认「导入到这个目录」？
10. macOS 权限：LrC 访问 MiniDiT 写在外置或可移除卷上的文件时，会不会弹出系统授权？
11. 15.0 的拖图标 bug 在最新 15.x 上修好没有？`open -a` 加文件夹是不是一定进「添加」模式？
12. 最新版 LrC 有没有 AppleScript 字典（用 Script Editor 的「打开字典」确认）。

## 6. 风险

- **插件生命周期**：LrC 没有官方的「后台服务」概念，插件靠 `LrTasks` 循环常驻。版本更新后行为可能变，要有手动入口兜底。
- **SDK 跟进慢**：Adobe 每个大版本只发一两次 SDK，而且往往比 .0 版本晚；文档也少。好在我们用到的 API 都是 2.0 到 4.0 时代的老 API，很稳定。
- **用户要做的事**：装一次插件，重启一次 LrC。和 C1「什么都不用装」比，这是唯一明显的额外步骤。
- **目录安全**：一切写入只走 SDK。任务单要幂等：已经加过的照片只加进收藏夹，不重复导入；写结果时注明哪些是跳过的。

---

## 7. 来源

SDK 和 API：
- LrCatalog API 参考（SDK 文档的镜像，包括 addPhoto、triggerImportUI、triggerImportFromPathWithPreviousSettings 等）：https://lrc.mcor.dev/modules/LrCatalog.html
- LrSocket API 参考（镜像）：https://lrc.mcor.dev/modules/LrSocket.html
- 「Lightroom SDK: Import alternatives?」（addPhoto 又慢又生成预览；「is all we've got」）：https://community.adobe.com/t5/lightroom-classic/lightroom-sdk-import-alternatives/m-p/11652079
- 「Open the import prompt from nodejs or python」（lightroom:// URL、LrSocket、triggerImport*）：https://community.adobe.com/t5/lightroom-classic-discussions/open-the-import-prompt-from-nodejs-or-python/td-p/11602170
- withWriteAccessDo 只能在异步任务里调用、写完就落盘：https://community.adobe.com/questions-675/having-a-problem-using-catalog-withwriteaccessdo-983795 ；https://community.adobe.com/t5/lightroom-classic-discussions/lrcatalog-withwriteaccessdo-how-to-determine-if-the-write-to-catalog-has-completed/m-p/13600302
- addPhoto 堆叠：https://community.adobe.com/t5/lightroom-classic-discussions/sdk-how-to-stack-images-using-catalog-addphoto-filepath-photo-above/m-p/14628618
- triggerImportUI 在 Windows 上的 bug：https://community.adobe.com/t5/lightroom-classic-bugs/p-sdk-catalog-triggerimportui-doesn-t-open-import-with-the-supplied-path-on-windows/idi-p/14250055
- Lightroom Controller SDK Guide 和外部控制补充文档（2018，13.3 时更新）：https://community.adobe.com/t5/lightroom-classic-discussions/new-documentation-lightroom-controller-sdk-guide/m-p/14630774
- 用户报告的 LrSocket 难点：https://community.adobe.com/t5/lightroom-classic-discussions/working-with-lrsocket-receiving/m-p/7604358 ；https://community.adobe.com/t5/lightroom-classic-discussions/issue-connecting-to-listener-using-lrsocket-send/m-p/14497271
- URL handler 写法（Jeffrey Friedl，2012）：https://regex.info/blog/2012-01-17/1926
- URL handler 在 LrC 没开时不触发（bug，2024）：https://community.adobe.com/bug-reports-674/p-urlhandler-of-plugins-do-net-get-called-if-lightroom-classic-is-not-yet-running-664202
- 插件入门（收藏夹集、收藏夹、写事务）：https://akrabat.com/6102
- 插件初始化和退出、后台任务：https://community.adobe.com/t5/lightroom-classic-discussions/re-loading-initializing-plugins/m-p/2788623
- SDK 14.0 发布：https://community.adobe.com/t5/lightroom-classic-discussions/lightroom-classic-sdk-14-0-max-release-now-live/m-p/14915527
- SDK 14.3 的改动：https://community.adobe.com/questions-675/changes-to-the-lr-14-3-sdk-981935
- 15.x 的 SDK 情况：https://community.adobe.com/t5/lightroom-classic-discussions/no-lua-sdk-for-lightroom-classic-v15/td-p/15607061

LrC 功能：
- 自动导入（Adobe 帮助）：https://helpx.adobe.com/lightroom-classic/help/import-photos-automatically.html
- 自动导入不能按日期分（功能请求）：https://community.adobe.com/t5/lightroom-classic-ideas/p-auto-import-to-folders-organized-by-date/idi-p/12249730
- 拖到 Dock 图标弹出导入对话框：https://blog.thomasfitzgeraldphotography.com/blog/2016/6/lightroom-quick-tip-drag-and-drop-behaviour
- 15.0 拖图标的 bug：https://community.adobe.com/bug-reports-674/p-lrc-v15-drag-and-drop-on-dock-icon-opens-the-app-but-won-t-import-664528 ；https://community.adobe.com/bug-reports-674/p-lightroom-classic-14-5-1-stalls-or-freezes-when-i-drag-folder-on-icon-664523
- 没有 AppleScript 字典：https://www.macscripter.net/t/simple-lightroom-script/69428 ；https://rfshooters.com/threads/using-apple-script-to-select-menu-items-in-lightroom-classic.3924
- 插件安装和 Modules 目录：https://lightroom-tools.pages.dev/blog/how-to-install-lightroom-classic-plugin ；https://community.adobe.com/t5/lightroom-classic-discussions/install-a-lightroom-4-plug-in/m-p/4622597 ；https://lightroomkillertips.com/understanding-the-plug-in-manager/
- Bundle ID：https://community.adobe.com/t5/lightroom-classic-discussions/lightroom-classic-12-4-ne-s-ouvre-plus-sur-imac-apple-silicon-intel/m-p/13986267

目录文件：
- 文件锁和 SQLite 锁：https://community.adobe.com/t5/lightroom-classic-discussions/sdk-new-lightroom-plugin-to-see-develop-history-timestamps/td-p/13228966
- 目录损坏：https://www.lightroomqueen.com/catalog-corruption-cause-prevention/
- C1 导入 LrC 目录（只读）：https://support.captureone.com/hc/en-us/articles/8808388225053-Importing-a-Lightroom-catalog

现有产品：
- Photo Mechanic 导入后在 LrC 里「添加」：https://www.fujixpassion.com/?p=6458 ；https://digital-photography-school.com/speed-lightroom-workflow-photo-mechanic/
- SnitchSync：https://photographers-toolbox.com/blog/2011/03/snitch-sync-improving-your-shuttersnitch-to-lightroom-workflow
- OffShoot 和 EditReady 集成：https://docs.hedge.video/offshoot/integrations/editready
- Smart Shooter：https://tethertools.com/blog/lightroom-classic-plug-in-update ；https://tethertools.com/blog/how-to-tethering-lightroom-sony-camera-smart-shooter
- LrC 原生支持索尼联机、和 Imaging Edge 的冲突：https://community.adobe.com/t5/lightroom-classic-bugs/p-cannot-tether-sony-a7-iv-ilce-7m4-with-latest-3-01-firmware/idi-p/14630158 ；https://lightroomkillertips.com/how-to-tether-a-sony-camera-to-lightroom-classic/

开源插件源码（GitHub）：
- Cull（manifest 文件 + URL handler + addPhoto + 收藏夹集）：https://github.com/jshph/cull/tree/main/integrations/Cull.lrplugin
- lightroom-mcp（socket，每张一个写事务，大小写问题，15.6 实测）：https://github.com/Automaat/lightroom-mcp/blob/main/plugin/LightroomMCP.lrplugin/HandlerImport.lua
- MIDI2LR（两个 LrSocket，端口 58763/58764）：https://github.com/rsjaffe/MIDI2LR/blob/master/src/plugin/Client.lua
- lightroom-cli（socket + JSON-RPC）：https://pypi.org/project/lightroom-cli
- lightroom-live-stack（用 addPhoto 加视频）：https://github.com/thusoy/lightroom-live-stack
