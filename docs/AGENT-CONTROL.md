# CLI 与 MCP

MiniDiT 提供原生命令行 `minidit`，也可作为 MCP stdio 服务供 agent 调用。两个入口操作同一个正在运行的应用，项目、素材选择、导入进度和结果会直接反映在界面中。

## 使用 CLI

安装命令行后，先打开应用并查询状态：

```sh
minidit launch
minidit status
minidit projects list
```

项目和素材的 ID 都从查询结果中取得，不依赖列表位置或显示名称。下面是一次普通导入的流程：

```sh
# 创建并选中项目；同名项目会被选中，不重复创建。
minidit projects create --date 2026-11-09 --event 海边拍摄

# 也可以选择已有项目。
minidit projects select --id PROJECT_UUID

# 连接相机，或打开存储卡目录，二选一。
minidit sources connect --host 127.0.0.1
minidit sources open-card --path /Volumes/CARD

# 连接和读取是异步的，等待 status 的 phase 为 ready、refreshing 为 false。
minidit status

# 调整界面筛选；空 query 清除搜索，days=[] 显示全部日期。
minidit assets filter --content all --only-new false --query '' --days '[]' --mark all
minidit assets list --limit 50
minidit assets select --ids 1,2,3

# 先预览，检查目标、素材范围、备份和可能的删除原片行为。
minidit import preview

# 使用预览结果中的 planId，执行这份计划。
minidit import start --plan-id PLAN_UUID
minidit status
minidit imports list
minidit imports get --id BATCH_UUID --limit 50
```

示例中的 UUID 和素材 ID 必须替换为查询结果。`projects create` 只创建项目，不开始传输。可通过 `--photo-root` 和 `--video-root` 指定已存在的根目录；确认创建时应用到相应媒体的默认存储地址。照片使用 Capture One 新建会话模式时，照片根目录对应会话根目录。

普通导入必须有已选择的项目，CLI 和 MCP 不能绕过此规则。直接拖到桌面或访达文件夹仍由应用独立处理，无需项目；第一版 agent 接口未提供单独的原文件拖出工具。

所有操作结果使用 JSON。错误包含稳定的 `code` 和说明；CLI 成功退出码为 `0`，无效命令或参数为 `2`，其他失败为 `1`。查看完整工具及参数定义：

```sh
minidit --help
minidit tools
minidit call projects.select '{"id":"PROJECT_UUID"}'
```

## 接入 MCP

服务通过标准输入输出通信，支持 MCP 协议版本 **2025-11-25**。只向标准输出写 JSON-RPC 消息，不启动 HTTP 服务。

在支持 MCP stdio 的客户端中配置命令的绝对路径：

```json
{
  "mcpServers": {
    "minidit": {
      "command": "/absolute/path/to/minidit",
      "args": ["mcp"]
    }
  }
}
```

按客户端使用的配置格式填写。安装脚本默认将命令放在 `~/.local/bin/minidit`；配置文件中使用展开后的绝对路径。启动 MCP 服务不等于启动应用：agent 可先调用 `minidit_app_launch`，然后查询 `minidit_app_status`。

MCP 暴露与 CLI 对应的 35 个工具，例如 `minidit_projects_list`、`minidit_assets_select`、`minidit_import_preview`、`minidit_import_start`。工具有参数 schema、只读/修改标记和结构化结果。连接、刷新、导入、取消均需通过状态查询观察完成情况；工具返回已接受请求，不代表传输已经完成。

协议依据：[stdio 传输](https://modelcontextprotocol.io/specification/2025-11-25/basic/transports)、[初始化流程](https://modelcontextprotocol.io/specification/2025-11-25/basic/lifecycle)、[工具定义与调用](https://modelcontextprotocol.io/specification/2025-11-25/server/tools)。

## 可用操作

| CLI 方法 | 作用 |
|---|---|
| `app.launch`、`app.status` | 启动应用、查询状态与待处理提示 |
| `projects.list`、`projects.create`、`projects.select` | 查询、创建和选择项目 |
| `sources.list`、`sources.connect`、`sources.open_card` | 查询来源、连接相机、打开卡目录 |
| `sources.refresh`、`sources.disconnect` | 刷新或断开来源 |
| `assets.filter`、`assets.list`、`assets.select` | 筛选、分页列出和选择素材 |
| `import.preview`、`import.start` | 预览和执行导入计划 |
| `import.cancel`、`import.resume` | 取消当前任务或继续中断的任务 |
| `imports.list`、`imports.get` | 查询批次摘要、逐文件及副本记录 |
| `tether.start`、`tether.stop`、`tether.status` | 开始 / 结束索尼联机拍摄，查询联机状态 |
| `tether.shoot`、`tether.focus`、`tether.record` | 拍摄、锁定或释放对焦、开始或停止录像 |
| `tether.set`、`tether.configure` | 调整曝光参数；设置自动导入和实时取景 |
| `tether.live_view` | 取一帧实时取景 JPEG（MCP 中为图片内容），或把原始帧存成文件 |
| `tether.properties`、`tether.get` | 列出相机的全部属性；读取指定属性 |
| `tether.set_properties` | 设置任意属性，逐项回读确认 |
| `tether.capture` | 拍一张并等所有文件传完，返回路径和参数快照 |
| `tether.files`、`tether.download` | 列出存储卡文件；按文件名下载（视频附 M01.XML） |
| `tether.record_clip` | 录一段指定秒数的视频并取回 MP4 + XML |
| `tether.mode` | 切换拍照 / 录像 / S&Q（需要时先改成 PC 优先） |
| `tether.custom_wb` | 远程取白：结果存进自定义 1–3，返回色温和 G–M |
| `tether.focus_position` | 远程调焦：读镜头位置，或移到 / 在几秒内平滑拉到某个位置（值越大越近） |
| `tether.touch` | 远程触摸：在 640×480 坐标处按机身的触摸功能对焦或跟踪；`cancel=true` 取消 |

CLI 的方法可以写成分隔的命令，例如 `projects list`；下划线操作可以写成连字符，例如 `sources open-card`。完整方法也可通过 `minidit call METHOD 'JSON'` 调用。

`assets.list` 返回当前界面可见范围内的拍摄 ID；RAW+JPG 配对时，一个 ID 可对应多个文件。选择接口只接受当前可见的拍摄 ID，不会把隐藏素材加入任务。列表默认最多返回 50 项，素材列表上限 200，批次详情上限 100，通过 `offset` 继续读取。标记筛选可能需要异步读取元数据，等待 `status.metadataLoading` 为 `false` 后再取结果。

## 计划与状态

- 预览不会下载文件。计划保留五分钟；项目、素材选择、设备连接或相关导入设置变化后，旧计划失效，需重新预览。
- 同一个 `planId` 重试启动只返回原批次 ID，不重复创建传输。应用退出后计划不保留。
- 备份已启用但未配置目标、必需目标不可用、空间不足、来源未就绪、LrC 插件未就绪等情况返回明确错误，不自动跳过用户配置。可选目标离线不阻止导入，但会记录该目标的失败。
- 预览中的 `backupTargets` 包含本批全部启用目标的 ID、名称、路径、卷标识及必需性。任意目标的相关设置改变都会使旧计划失效。`app.status.progress.backups` 返回逐目标进度，`imports.list/get` 的 `backupStatus` 返回已校验/待补数量及当前位置状态；`requiredBackupsComplete` 单独表示必需目标是否完成。配置目标、补齐与迁移仍在应用中操作，未新增 MCP 工具。
- 已开启导入后删除原片时，预览要求显式传 `--allow-delete-originals true`。预览展示该行为，执行仍遵守应用的校验和备份条件。没有开启该设置时，这个参数不会额外开启删除。
- `import cancel` 保留已保存文件；没有活动传输时可放弃待续传任务。`import resume` 使用原任务的项目及冻结路径；不会因当前另选项目而改投其他位置。
- 相机首次账号、指纹或软件授权仍在应用中处理。`pendingInteraction` 指出需要处理的提示，不返回账号密码或钥匙串内容。
- 第一版不提供删除项目、清空历史、清卡、补备份或任意执行脚本的工具；这些操作继续在应用中处理。

## 联机拍摄

索尼相机开启“电脑遥控”后，`tether start` 开始联机（不带 `--host` 时用当前连接的索尼 Wi-Fi 相机）。这会断开当前来源，主来源换成这次的联机缓存。连接是异步的，轮询 `tether status` 直到 `active=true`。

```sh
minidit tether start --host 192.168.1.23
minidit tether status
minidit tether set --setting iso --label 400        # 或 --value 原始值、--step 1（相对档位）
minidit tether shoot
minidit tether live-view --max-width 1024           # data 字段为 base64 JPEG
minidit tether live-view --out-file /path/frame.jpg   # 原始帧写成文件，不覆盖
minidit tether configure --auto-import false
minidit tether mode --mode movie                     # 照片 M ↔ 录像 M；--exposure auto|p|a|s|m 可另选
minidit tether custom-wb --slot 3                    # 先把相机对准灰卡；--probe true 只试待机，不取白
minidit tether stop --restore-settings true         # 先改回本次改过的属性再断开
```

- `tether.status` 返回拍摄模式、电量、对焦/录像状态、各参数的当前值和全部可选值（`value` 原始值、`label` 显示文字）、`shotCount`、`lastShot`（文件名、缓存路径、曝光、器材、是否已导入）、`autoImport`、`spoolPath`。
- `tether.set` 的 `value`、`label`、`step` 三选一；当前拍摄模式下由相机决定的参数返回 `setting_unavailable`，选项不存在返回 `invalid_value` 并列出可选值。
- `tether.shoot`、`tether.set`、`tether.focus`、`tether.record` 返回 `accepted` 即结束；结果看 `tether.status`，导入进度看 `app.status.progress`。
- 自动导入仍要求已选择项目：未选项目时照片留在联机缓存，选好项目后补导；不提供绕过项目的导入。
- `tether.live_view` 在 MCP 中返回 `image` 内容块（agent 可直接看构图），结构化结果只含尺寸和类型。图像按 `maxWidth`（默认 1024，最大 1600）缩小后重新编码，保证不超过本地接口单条消息上限。
- 相机断开时其他 `tether.*` 操作返回 `camera_lost`；没有联机时返回 `not_tethering`。
- 录像只保存在相机存储卡上。

### 任意属性与等待式拍摄

除了上面五项常用参数，`tether.properties` 列出相机报告的全部属性（α7 V 约 426 项）：编号、SDK 名称（`CrDeviceProperty_*` 去掉前缀）、`state`（writable / displayOnly / disabled / readOnly）、当前值、可选值或范围。

```sh
minidit tether properties --query CreativeLook
minidit tether get --names ISO,ShutterSpeed,Colortemp
minidit tether set-properties --assignments WhiteBalance=ColorTemp,Colortemp=3200K,CreativeLook=ST,CreativeLook_Contrast=+3
minidit tether capture --out-dir /path/to/dir --timeout-seconds 60
```

- 名称用 SDK 名称（不分大小写）或编号 `0xD20F`；别名：ISO、Shutter、Aperture、ColorTemp、ExposureMode、DriveMode、FocusMode。
- 取值可用可读写法（`1/1000`、`F5.6`、`ISO 400`、`3200K`、`ST`、`+3`、`AWB`、`Custom1`、`MF`、`Off`），也可用原始值（十进制或 `0x…`）。可读写法只覆盖已核实的属性，见 [camctl-a7v-property-map.md](camctl-a7v-property-map.md)；其余用原始值。
- `set_properties` 先解析全部赋值，有一项名称或写法不对就一项都不改；然后按顺序逐项设置并回读，超时（`timeoutSeconds`，默认 5 秒）未生效报 `readback_mismatch`。出错时消息里列出已经生效的项。
- 错误码：`unknown_property`、`invalid_value`（附可选值）、`not_writable`（区分“仅显示”和“未启用”）、`readback_mismatch`、`camera_busy`、`card_full`、`card_unavailable`、`camera_lost`、`capture_timeout`、`file_exists`。
- `capture` 等到相机没有待传文件、新文件 0.6 秒不再变化才返回；结果含文件路径和字节数、`settings`（按下快门前的曝光、白平衡、Creative Look、文件格式等快照）。`outDir` 里已有同名文件时报 `file_exists`，一个都不复制；照片始终在联机缓存和存储卡上各有一份。开启自动导入时照片仍会按项目导入，脚本化拍摄可先 `tether configure --auto-import false`。
- `tether.status` 的 `info` 里有镜头、焦距、电量、固件、两个卡槽剩余张数、曝光模式、照片存储位置、PriorityKey。
- `tether.files` / `download` / `record_clip` 用远程传输（0x923B–0x923E）读卡，走联机的同一条连接，不用切换模式。`files --latest N --slot 1|2` 新的在前；`download --names A,B --out-dir DIR [--slot N]` 两个卡槽有同名文件时默认卡槽 1；视频另写出 MP4 内嵌的 XML（`C0001M01.XML`，与卡上的 M01.XML 一字不差）。先写成隐藏的 `.partial` 再改名，已有同名文件报 `file_exists`。
- `record_clip --seconds S [--out-dir DIR]`：开始录像 → 等 S 秒 → 停止 → 等新片段出现在卡上（`timeoutSeconds`，默认 120）→ 下载。α7 V 上开始和停止各有延迟，结果里的 `durationSeconds`（来自 XML）是实际时长，2 秒约为 1.5 秒。
- `live_view --out-file PATH`：把相机送来的那一帧 JPEG 原样写到文件（不缩小、不重新编码），只返回 `path`、`bytes`、`width`、`height`、`savedAt`。要绝对路径、目录已存在；文件已存在报 `file_exists`，先写隐藏临时文件再改名。
- CLI 等待回复的时间：`capture` 330 秒、`set_properties` 90 秒、`files` 120 秒、`download` 3600 秒、`record_clip` 录像秒数 + 超时 + 3600 秒、`stop` 60 秒、其余 10 秒。

### 远程取白

`tether custom-wb --slot N` 依次：白平衡切到自定义 N → 取白待机 → 在画面中央取白 → 等相机完成 → 返回 `colorTemperature`、`tintGM`、`tintAB`。α7 V 上约 3 秒。结果存进该槽位，白平衡保持在自定义 N（白平衡的原值记在 `changedProperties` 里，`stop --restore-settings` 会改回）。

- `--probe true` 只进入待机再取消，不改槽位里的结果，用来确认相机能否远程取白。
- `--position` 指定取白框位置 `x << 16 | y`（640×480 坐标），默认中央。
- 每一步的状态记在 `trace` 里；相机不允许待机、待机或取白超时时报 `custom_wb_unavailable` / `custom_wb_timeout`，消息里附 trace，并会尝试取消待机。

### 还原相机设置

- 连接时 MiniDiT 会尝试把 PriorityKey（0xD25A）改成 PC 优先，真的改动了才记下原值。结束联机时（`tether stop`、关闭联机窗口、断开来源）总会先把它改回原值，相机上的拨盘才能继续用。Wi-Fi 意外断开时没法写回，需要在相机菜单里改回，或者下次联机后再正常结束一次。
- `tether.status` 的 `changedProperties` 列出本次联机改过的属性和原值：连接时改的 PriorityKey，加上 `set_properties` 改过的属性（同一属性只记第一次改之前的值）。`tether set`（界面那五项常用参数）不记录。
- `tether stop --restore-settings true` 先把这些属性逐项改回原值并回读确认，后改的先还原（先还原色温再还原白平衡模式，PriorityKey 最后），结果在 `restored` 里逐项列出 `ok` / `error`，然后断开。改不回的项不会中断其余项。

### 命令日志

CLI 和 MCP 发来的每条 `tether.*` 命令都在应用里追加一行 JSON 到 `~/Library/Logs/MiniDiT/tether-YYYY-MM-DD.jsonl`（路径见 `tether.status` 的 `logPath`）：

```json
{"time":"2026-11-16T14:03:12.481+01:00","method":"tether.set_properties","params":{"assignments":["ISO=400"]},"durationMs":312,"ok":true,"result":{"results":[…]}}
{"time":"…","method":"tether.capture","params":{},"durationMs":60012,"ok":false,"error":{"code":"capture_timeout","message":"…"}}
```

- 失败的命令也记录，带错误码和消息。
- 取景图片不写 base64，只记长度；超过 30 项的列表只留前 30 项（`tether.properties` 的完整结果请直接看命令输出），超过 2000 字的字符串截断。
- 只追加，按天分文件，不自动清理。

## 本地接口与安装

CLI 使用当前用户专属的 Unix socket 连接应用：`/private/tmp/minidit-agent-<uid>/control.sock`。目录权限为 `0700`，socket 权限为 `0600`，双端检查对端用户 ID。接口不监听网络端口；同一系统账户下的进程可以调用。应用日志记录修改操作的名称。

开发构建与安装：

```sh
swift build -c release --product minidit
sh Apps/MiniDiT/scripts/install-cli.sh .build/release/minidit
```

若 `~/.local/bin` 不在 `PATH` 中，可直接使用完整路径，不必修改终端配置。

相关源码：`Sources/minidit/main.swift`、`Sources/MiniDiTCore/AgentProtocol.swift`、`Sources/MiniDiTCore/AgentSocket.swift`、`Apps/MiniDiT/MiniDiT/App/AppModel+Agent.swift`、`Apps/MiniDiT/MiniDiT/App/AppModel+AgentTether.swift`、`Sources/SonyRemoteKit/Sony/SonyPropertyCatalog.swift`（名称与可读写法）。

隔离检查：

```sh
swift test --filter AgentProtocolTests
swift build --product minidit
sh Tests/AppFeatureChecks/run.sh --agent
swift build --product fake-sony-camera
sh Tests/AppFeatureChecks/run.sh --tether "$(swift build --show-bin-path)/fake-sony-camera" --cli "$(swift build --show-bin-path)/minidit"
```

应用层检查使用独立偏好域、临时卡、临时项目和 socket；覆盖实际 CLI 启动导入、重试幂等性、计划失效、JSON 输出和 MCP 握手/工具调用。`MINIDIT_TEST_CLI` 可指定测试所用 CLI 路径；`MINIDIT_SOCKET_PATH` 仅供 CLI/MCP 连接隔离实例，应用默认地址不受其影响。
