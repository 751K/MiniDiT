# α7 V 属性对照（camctl 需求逐项）

数据：2026-11-16 用 `camctl props` 从 ILCE-7M5（固件 2.00，FE 20-70mm F4 G）只读读出，426 项全部解析成功。
名称：属性码 → Camera Remote SDK 名称来自 [mikefsq/ptp](https://github.com/mikefsq/ptp)（SDK 内部表转写，426 项里 398 项有名字）和 libgphoto2 `ptp.h`。

**取值含义要单独核实**：SDK 的枚举值和相机线上的值不一定一样（StillImageStoreDestination 线上 0x11，SDK 里是 3；FocusMode 线上 0x8004，SDK 里是 3）。下表“含义”一栏只在线上值和已知表吻合时才写，其余标 ❓。

图例：✅ 已确认可写 · 🔒 现在只读（相机报告“仅显示”，原因见备注）· ❓ 属性找到了，取值含义待实机确认 · ❌ 没找到

## 曝光与对焦

| 需求 | 属性码 | SDK 名称 | 现在 | 状态 | 备注 |
|---|---|---|---|---|---|
| 曝光模式 M | 0x500E | ExposureProgramMode | 1（M） | 🔒 | 当前由相机拨盘控制。0xD25A PriorityKeySettings 现为 0（相机优先），改成 1（PC 优先）后预计可写；可选值里还有一批 0x7805x / 0x9805x / 0xC809x，看起来是录像和 S&Q 的曝光模式 |
| ISO | 0xD21E | IsoSensitivity | 100 | ✅ | 35 个选项，含 AUTO（0xFFFFFF） |
| 快门 | 0xD20D | ShutterSpeed | 1/15 | ✅ | 56 个选项；另有 0xD19F ExtendedShutterSpeed（UINT64） |
| 光圈 | 0x5007 | FNumber | F5.6 | 🔒 | 同曝光模式，需 PC 优先 |
| 对焦模式 MF | 0x500A | FocusMode | 0x8004（AF-C） | ✅ | 可选值含 1（MF） |
| 驱动模式单张 | 0x5013 | DriveMode | 1（单张） | ✅ | 139 个选项 |

## 白平衡

| 需求 | 属性码 | SDK 名称 | 现在 | 状态 | 备注 |
|---|---|---|---|---|---|
| 白平衡模式 | 0x5005 | WhiteBalance | 2（AWB） | ✅ | 15 个选项：AWB 2、日光 4、色温 0x8012、自定义 1–3 0x8020–0x8022 等，和现有表吻合 |
| 色温 2500–9900K / 100K | 0xD20F | Colortemp | — | ✅ | 范围正好 2500..9900 步进 100；白平衡不在“色温”时未启用 |
| 白平衡微调 A–B / G–M | 0xD21C / 0xD210 | ColorTuningAB / ColorTuningGM | 192（0） | ✅ | 实测：A2 = 200、G1 = 196。中心 192，每格 4，A、G 为正；AB 步进 2（半格），GM 步进 1（四分之一格），范围 164..220 = ±7 格。写法 `ColorTuningAB=A2`、`ColorTuningGM=M0.25` |
| 自定义白平衡 | 控制 0xD2DF / 0xD2E0 / 0xD2E1 | CustomWBCaptureStandby / Cancel / Capture | — | ❓ | 状态属性 0xD26B–0xD270（可拍摄区域、执行状态等）都在；0xD135 CustomWB_Size_Setting 可写。流程推测：先把白平衡设成自定义 1–3，再待机 → 拍摄 |

## Creative Look

| 需求 | 属性码 | SDK 名称 | 现在 | 状态 | 备注 |
|---|---|---|---|---|---|
| 外观 | 0xD0FA | CreativeLook | 1（ST） | ✅ | 实测 FL2 = 11，1–12 依次为 ST、PT、NT、VV、VV2、FL、IN、SH、BW、SE、FL2、FL3；257–262 = 自定义外观 1–6。换外观时各参数会跳到该外观的默认值（FL2 的褪色 = 1） |
| 对比度 | 0xD0FB | CreativeLook_Contrast | 0 | ✅ | −9..9 |
| 高光 | 0xD0FC | CreativeLook_Highlights | 0 | ✅ | −9..9 |
| 阴影 | 0xD0FD | CreativeLook_Shadows | 0 | ✅ | −9..9 |
| 褪色 | 0xD0FE | CreativeLook_Fade | 0 | ✅ | 0..9 |
| 饱和度 | 0xD0FF | CreativeLook_Saturation | 0 | ✅ | −9..9 |
| 锐度 | 0xD100 | CreativeLook_Sharpness | 4 | ✅ | 0..9 |
| 锐度范围 | 0xD101 | CreativeLook_SharpnessRange | 3 | ✅ | 1..5 |
| 清晰度 | 0xD102 | CreativeLook_Clarity | 1 | ✅ | 0..9 |

## 照片格式

| 需求 | 属性码 | SDK 名称 | 现在 | 状态 | 备注 |
|---|---|---|---|---|---|
| 文件格式 | 0xD253（统一记录）/ 0xD28B、0xD28C（分卡槽） | FileType / MediaSLOT1/2_FileType | — | ✅ | 实测：1 RAW、4 RAW+HEIF、5 HEIF。用哪一组取决于记录媒体设置（0xD15F：258 时分卡槽的那组可写，257 时统一的那组可写）。压缩格式为 JPEG 时的取值未测 |
| 传到电脑的格式 | 0xD269 | RAW_J_PC_Save_Image | 5（只有 HEIF） | ✅ | {3 RAW, 4 RAW+HEIF, 5 HEIF}（libgphoto2 表）。实测：5 时只收到 .HIF，改成 4 后同一次拍摄收到 .ARW + .HIF |
| HEIF / JPEG、色度采样 | 0xD287 | CompressionFileFormatStill | 3（HEIF 4:2:0） | ✅ | {1 JPEG, 2 HEIF 4:2:2, 3 HEIF 4:2:0}，和 SDK 表完全吻合 |
| 画质 | 0xD252 / 0xD28D、0xD28E | StillImageQuality / MediaSLOT1/2_ImageQuality | — | ✅ | 实测：1 超精细、2 精细、3 标准（4 轻量，排除法）。和 SDK 的 CrImageQuality 正好相反 |
| 图像尺寸 | 0xD203 / 0xD28F、0xD290 | ImageSize / MediaSLOT1/2_ImageSize | — | ✅ | 实测：M = 2、S = 3（1 = L）。只拍 RAW 时仅显示 |
| RAW 压缩 | 0xD288 / 0xD289、0xD28A | RAW_FileCompressionType / MediaSLOT1/2_RAW_FileCompressionType | — | ✅ | 实测：6 无损压缩、7 压缩HQ、1 压缩。α7 V 没有「未压缩」。和 SDK 的 CrRAWFileCompressionType 对不上 |
| DRO / 自动 HDR 关 | 0xD201 | DRO | 1（关） | ✅ | {1 关, 31 自动, 17–21 Lv1–5}；可选值里没有 HDR。0xE0DB CompRAWShootingHDR 相机列出但没报值 |
| 色彩空间 sRGB | 0xD15E | ColorSpace | 1（sRGB） | 🔒 / ✅ | 拍 HEIF 时仅显示（固定 sRGB）；只拍 RAW 时可写 |
| 暗角补偿 | 0xD1A2 | LensCompensationShading | 2（自动） | ✅ | {1 关, 2 自动, 3 弱}，值和 SDK 表吻合 |
| 色差补偿 | 0xD1A3 | LensCompensationChromaticAberration | 2（自动） | ✅ | {1 关, 2 自动} |
| 畸变补偿 | 0xD1A4 | LensCompensationDistortion | 2（自动） | 🔒 | 只读，很可能是这支镜头强制开启畸变补偿 |
| 照片存电脑和卡 | 0xD222 | StillImageStoreDestination | 0x11（卡 + 电脑） | ✅ | 已经是需要的设置 |

## 视频

| 需求 | 属性码 | SDK 名称 | 现在 | 状态 | 备注 |
|---|---|---|---|---|---|
| 图片配置文件 | 0xD23F | PictureProfile | 0（关） | 🔒 | {0, 1–6, 10, 11}；拍照模式下只读 |
| 伽马 S-Log3 | 0xD0E1 | PictureProfile_Gamma | — | ❓ | 现在未启用；SDK 里 S-Log3 = 771，线上值待确认 |
| 色域 S-Gamut3(.Cine) | 0xD0E9 / 0xE001 | PictureProfile_ColorMode / MovieShootingModeColorGamut | — | ❓ | 0xD0E9 未启用；0xE001 相机列出但没报值 |
| 录像格式 | 0xD241 | Movie_File_Format | 11 | ❓ | {11, 8, 9, 14, 15} |
| 分辨率 / 码率 | 0xD242 | Movie_Recording_Setting | 46 | ❓ | {46, 50, 54, 59, 64} |
| 帧率 | 0xD286 | Movie_Recording_FrameRateSetting | 3 | ❓ | {3, 7, 1} |
| 拍照 / 录像切换 | — | — | — | ❓ | 没有单独的切换属性；ExposureProgramMode 的可选值里有录像模式，PC 优先时或许能切 |

## info 用到的

镜头名 0xD07B（FE 20-70mm F4 G）、焦距 0xD00B、电量 0xD218（82%）、卡 1 剩余 0xD249（18759 张）、卡 2 剩余 0xD257（5127 张）、固件 0xD040（2.00）、录像状态 0xD21D、待传照片 0xD215。

## 相机列出但没报值的 62 项（0xE0xx）

大多是电影机向的功能：MovieShootingMode / ColorGamut（0xE000 / 0xE001）、监看推流、对焦和变焦位置、Comp.RAW HDR、显示模式等。推测要在录像模式下、或用别的读法才报值，还没验证。

## 实机测试（2026-11-16，Wi-Fi + 访问认证）

用 MiniDiT 的 `tether.*` 工具：

- 连接 2 秒左右；`properties` 426 项，和只读导出一致。
- PriorityKeySettings 改成 PC 后，ExposureProgramMode 变为可写；FNumber 仍然仅显示，原因未查明（可能和这支镜头或光圈相关设置有关）。
- ISO 100 → 200 → 100：每次设置加回读约 0.3 秒。FNumber=F8 报 `not_writable`（仅显示）。
- 拍摄：只传 HEIF 时约 4 秒；RAW+HEIF（ARW 36 MB + HIF 3.6 MB）约 10 秒，两个文件都完整后才返回，复制到目标目录的文件与缓存逐字节一致，7008×4672。
- 测试后 RAW_J_PC_Save_Image、PriorityKeySettings、ISO 均已改回原值。

## 存储卡与录像（2026-11-16 实测）

- 联机连接里直接用远程传输读卡：2104 个文件约 2 秒；下载的 HIF 与联机时收到的逐字节一致。
- `record_clip --seconds 2`：14.5 秒内完成录像、等片段、下载（C2699.MP4 67 MB，4K 59.94p HEVC 4:2:2，rec709），XML 写成 C2699M01.XML。实际时长 1.5 秒（90 帧），开始 / 停止各有延迟。

## 改菜单对比（2026-11-16）

在相机菜单里改设置、前后各读一遍全部属性并对比，确认了上面标 ✅ 的取值（白平衡微调、Creative Look 顺序、文件格式、画质、尺寸、RAW 压缩、色温）。改文件格式时记录媒体设置（0xD15F）也从 258 变成了 257，分卡槽的格式属性随之停用、统一的那组启用。

## 下一步：核实取值（不写相机）

对每个 ❓ 项：你在相机菜单里把它改成已知的选项 → 重跑 `camctl props` → 对比前后两份输出，就能确定这个值的线上编码。整个过程只读。全部确认后，再在你同意的前提下实测写入（PriorityKey 改成 PC 优先、改 RAW 压缩等），每一项改完都改回原值。
