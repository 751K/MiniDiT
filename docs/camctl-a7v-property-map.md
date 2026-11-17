# α7 V 属性对照（camctl 需求逐项）

数据：2026-11-16 用 `camctl props` 从 ILCE-7M5（固件 2.00，FE 20-70mm F4 G）只读读出，426 项全部解析成功。
名称：属性码 → Camera Remote SDK 名称来自 [mikefsq/ptp](https://github.com/mikefsq/ptp)（SDK 内部表转写，426 项里 398 项有名字）和 libgphoto2 `ptp.h`。

**取值含义要单独核实**：SDK 的枚举值和相机线上的值不一定一样（StillImageStoreDestination 线上 0x11，SDK 里是 3；FocusMode 线上 0x8004，SDK 里是 3）。下表“含义”一栏只在线上值和已知表吻合时才写，其余标 ❓。

图例：✅ 已确认可写 · 🔒 现在只读（相机报告“仅显示”，原因见备注）· ❓ 属性找到了，取值含义待实机确认 · ❌ 没找到

## 曝光与对焦

| 需求 | 属性码 | SDK 名称 | 现在 | 状态 | 备注 |
|---|---|---|---|---|---|
| 曝光模式 M | 0x500E | ExposureProgramMode | 1（M） | ✅ | 相机优先（0xD25A = 0）时仅显示，PC 优先时可写。取值见下方「拍照 / 录像切换」 |
| ISO | 0xD21E | IsoSensitivity | 100 | ✅ | 35 个选项，含 AUTO（0xFFFFFF） |
| 快门 | 0xD20D | ShutterSpeed | 1/15 | ✅ | 56 个选项；另有 0xD19F ExtendedShutterSpeed（UINT64） |
| 光圈 | 0x5007 | FNumber | F5.6 | ✅ | 需 PC 优先。**镜头光圈环不在 A 档时仅显示**（FE 20-70mm F4 G 实测：环在 F4 时 A / M 模式下都是 displayOnly、恒为 F4.0，拨到 A 后立即可写） |
| 对焦模式 MF | 0x500A | FocusMode | 0x8004（AF-C） | ✅ | 可选值含 1（MF） |
| 驱动模式单张 | 0x5013 | DriveMode | 1（单张） | ✅ | 139 个选项，全部能按 libgphoto2 的 sony3_capturemode 表解出（单张 1、连拍 4、自拍 9、连续包围 60、单拍包围 60、其他包围 5）。包围按位解出：高 16 位 4 = 连续包围、5 = 单拍包围；次低字节 0x83/85/87/89 = 3/5/7/9 张、0xC2 = 2 张；最低字节去掉 0x08（2 张的「−」）是档位，连续包围比单拍大 1。抽查连拍：中、自拍 2 秒、连续包围 0.3EV 3 张、单拍包围 3.0EV 2 张 + 都和机身一致 |

## 白平衡

| 需求 | 属性码 | SDK 名称 | 现在 | 状态 | 备注 |
|---|---|---|---|---|---|
| 白平衡模式 | 0x5005 | WhiteBalance | 2（AWB） | ✅ | 15 个选项：AWB 2、日光 4、色温 0x8012、自定义 1–3 0x8020–0x8022 等，和现有表吻合 |
| 色温 2500–9900K / 100K | 0xD20F | Colortemp | — | ✅ | 范围正好 2500..9900 步进 100；白平衡不在“色温”时未启用 |
| 白平衡微调 A–B / G–M | 0xD21C / 0xD210 | ColorTuningAB / ColorTuningGM | 192（0） | ✅ | 实测：A2 = 200、G1 = 196。中心 192，每格 4，A、G 为正；AB 步进 2（半格），GM 步进 1（四分之一格），范围 164..220 = ±7 格。写法 `ColorTuningAB=A2`、`ColorTuningGM=M0.25` |
| 调焦（对焦位置） | 0xE088 / 0xE089（跟焦），0xE042 / 0xE043（绝对位置） | FollowFocusPositionSetting / CurrentValue，FocusPositionSetting / CurrentValue | — | ✅ | 扩展属性，UINT16 范围。**值越大越近**（扫描对焦时近处桌沿在大端最清楚，中景在 22000 左右）。跟焦的范围是镜头行程（这支镜头 0–63978），只在录像模式可写；绝对位置 0–65535，镜头实际只走 2048–61971，拍照和录像都可写。两个刻度线性对应（跟焦 0 → 绝对 2048，63978 → 61971）。两种都约 1 秒内到位；平滑拉焦由电脑分步发送。AF 时相机会重新对焦，应先切 MF。0xE086 镜头信息可用状态为 0，暂时换算不出米数 |
| 放大对焦 | 0xD254 | Focus_Magnifier_Setting | 0 | ✅ | UINT64：高 4 字节倍率 ×10（0 关、10 = ×1.0、55 = ×5.5、110 = ×11），低 4 字节位置 x << 16 \| y（640×480，0xFFFFFFFF = 当前位置）。可选值只列「当前位置」，但写入任意位置也会采用。**传到电脑的取景画面也会放大**（实测 ×5.5、×11 都能看清焦点）。α7 V 上只在拍照模式 + MF 时可写；录像模式下仅显示（和 Log 无关）。0xD2CB / 0xD2CC 放大按键这台没有列出 |
| 对焦距离 | 0x9223 SDIO_GetLensInformation，0xE086 | LensInformation / LensInformationEnableStatus | — | ✅ | 录像模式下 0xE086 = 1。0x9223 参数 2 = 米表：头部 u32 偏移、u32 长度；表为 u16 版本（100）、u16 类型、u16 条数、2 字节保留，然后每条 u32 跟焦位置 + u32 距离（厘米，0xFFFF = ∞）。这支镜头 29 条，65535 → 25 cm … 0 → ∞。条与条之间按 1 / 距离插值；滑块在中间时显示 0.49 m，和表里 0x7FFF → 50 cm 吻合。拍照模式下 0xE086 = 0、读不到表，但 0xE089（跟焦当前位置）仍以只读报告；MiniDiT 在录像模式读到表后按镜头型号存下来，拍照时用 0xE089 查这张表显示距离（实测显示 0.65 m）。表可能随焦段变化，换焦段后回录像模式会重读 |
| 点按对焦（远程触摸） | 控制 0xD2E4 / 0xD2E5，状态 0xD283 / 0xD284 / 0xD285 | RemoteTouchOperation / CancelRemoteTouchOperation | 0xD284 = 1 | ✅ | 0xD2E4 经 0x9207 发 UINT32 = x << 16 \| y，整幅取景画面线性映射到 640×480：实测 (160, 120) 落在画面左上四分之一处，(480, 300) 落在对应物体上。触摸后 0xD285 由 0 变 1，0xD2E5（按下 + 松开）取消后回到 0。0xD283 触摸功能 {9, 8, 11, 10, 5, 1}，可写，和 SDK 的 CrFunctionOfTouchOperation 一致：11 时为触摸跟踪，9 时为触摸对焦（实测）；1 关、5 触摸 AE、8 / 10 为对应的「+ 触摸 AE」（5、8、10 按 SDK 推断：远程能设置，但机身「触摸操作」菜单里找不到这一项，没能对照名称）。AF-C 下触摸后 0xD213 仍为 1（不半按就不报合焦）。取景 JPEG 里不画对焦 / 跟踪框，但取景数据集头部 8–15 字节给出 FocalFrameInfo（α7 V 为 v1.04）：平时是一个「广域」对焦框（类型 3，中心 0.5 / 0.5，约 0.79 × 0.83）；触摸后变成一个跟踪框（类型 2），中心就是触摸点（(480, 300) → 0.748 / 0.625），会随目标移动（实测转动相机时从 0.19 移到 0.44）；半按时状态变 2（合焦），取消后回到广域框 |
| 自定义白平衡 | 控制 0xD2DF / 0xD2E0 / 0xD2E1 | CustomWBCaptureStandby / Cancel / Capture | — | ✅ | 远程取白实测可用，流程见下方「自定义白平衡」。0xD135 CustomWB_Size_Setting 是取白框大小：1 S、2 M、3 L |

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
| 文件格式 | 0xD253（统一记录）/ 0xD28B、0xD28C（分卡槽） | FileType / MediaSLOT1/2_FileType | — | ✅ | 实测：1 RAW、4 RAW+HEIF、5 HEIF；压缩格式为 JPEG 时可选 {1 RAW, 3 JPEG}（分卡槽）或 {1 RAW, 2 RAW+JPEG, 3 JPEG}（统一记录），2、3 在机身上分别显示 RAW+JPEG、JPEG。0xD15F 记录媒体（均实测）：1 只记录到卡槽 1、2 只记录到卡槽 2、257 同时记录、258 分类记录。用哪一组取决于记录媒体设置（0xD15F：258 时分卡槽的那组可写，257 时统一的那组可写）。|
| 传到电脑的格式 | 0xD269 | RAW_J_PC_Save_Image | 5（只有 HEIF） | ✅ | {3 RAW, 4 RAW+HEIF, 5 HEIF}（libgphoto2 表）。实测：5 时只收到 .HIF，改成 4 后同一次拍摄收到 .ARW + .HIF |
| HEIF / JPEG、色度采样 | 0xD287 | CompressionFileFormatStill | 3（HEIF 4:2:0） | ✅ | {1 JPEG, 2 HEIF 4:2:2, 3 HEIF 4:2:0}，和 SDK 表完全吻合 |
| 画质 | 0xD252 / 0xD28D、0xD28E | StillImageQuality / MediaSLOT1/2_ImageQuality | — | ✅ | 实测：1 超精细、2 精细、3 标准、4 轻量（JPEG 下逐个核对）。和 SDK 的 CrImageQuality 正好相反 |
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
| 图片配置文件 | 0xD23F | PictureProfile | 0（关） | ✅ | {0, 1–6, 10, 11, 0x41–0x44}（关、PP1–6、PP10、PP11、PP-LUT1–4），和 SDK 一致，没有 PP7–9。拍照模式下只读；录像模式下可写，但机身「Log 拍摄」打开时未启用（创意外观也未启用） |
| 伽马 S-Log3 | 0xD0E1 | PictureProfile_Gamma | 1 | ✅ | 选了 PP1–11 时可写。{1 Movie, 2 Still, 3 S-Cinetone, 0x101–0x104 Cine1–4, 0x201 ITU709, 0x303 S-Log3, 0x401–0x404 HLG/HLG1–3}，和 SDK 一致，没有 S-Log2。实测把 PP1 改成 0x303 后机身显示 S-Log3。改的是该 PP 的内容 |
| 色域 S-Gamut3(.Cine) | 0xD0E9 | PictureProfile_ColorMode | 1 | ✅ | 同上。{1–9} = Movie、Still、S-Cinetone、Cinema、Pro、ITU709 Matrix、黑白、S-Gamut3.Cine、S-Gamut3。实测 8 时机身显示 S-Gamut3.Cine。0xE001 相机列出但没报值 |
| Log 拍摄 | 0xE000 / 0xE001 | MovieShootingMode / MovieShootingModeColorGamut | 0x501 | ✅ | α7 V 用 0xE000（不是 SDK 列的 0xE0E3 LogShootingMode）：{1 关, 0x501 Flexible ISO}，UINT16；0xE001 Log 色域 {1 S-Gamut3.Cine, 2 S-Gamut3}，Log 打开时可写（两个值都和机身一致）。录像模式下可写，拍照模式下未启用。实测远程打开后机身显示 Log 拍摄已开，图片配置文件和创意外观随之变为未启用，Base Look、监看 LUT 变为可写。**扩展属性**：0x9209 不带参数时相机不报告 0xE000 起的属性，要带 (0, 1)；0x9205 设置它们时也要带第二个参数 1，否则回 OK 但不改（见 PROTOCOL.md） |
| Base Look | 0xD03C | BaseLookValue | 257 | ✅ | {1–3, 257–272}：高字节是类型（0 预设、1 用户），低字节是序号，257 = 用户 1（SDK 注释）。Log 拍摄打开时可写，关闭时仅显示。预设 1–3 实测为 S-Log3（不套 LUT）、s709、709(800%)，这台没有 709tone |
| 监看 LUT | 0xD04D | MonitorLUTSetting | 2（开） | ✅ | {1 关, 2 开}（实测远程关掉后机身显示关）；和 Base Look 一样，只在 Log 拍摄时可写。也作用在传到电脑的取景画面上：开时是套了 LUT 的画面，关时是 S-Log3 原样（窄范围编码，最暗处约 8/255，对应黑位码值 95；18% 中灰约 104/255）。MiniDiT 的按档位伪色据此判断要不要按 S-Log3 换算 |
| S&Q 帧率 | 0xD052 | SQFrameRate | 120 | ✅ | {120, 60, 30, 15, 8, 4, 2, 1}，取值就是帧数（实测 30 时机身显示 30fps） |
| 录像格式 | 0xD241 | Movie_File_Format | 11 | ✅ | {11, 8, 9, 14, 15}，和 SDK 枚举不同。逐个改值对照机身菜单核实：11 XAVC HS 4K、8 XAVC S 4K、9 XAVC S HD、14 XAVC S-I 4K、15 XAVC S-I HD。换格式时相机会把码率和帧率改成该格式可用的值（实测：9 → 50M 4:2:0 8bit；14 → 300M 4:2:2 10bit、30p；15 → 222M 4:2:2 10bit、60p），和机身显示一致 |
| 分辨率 / 码率 | 0xD242 | Movie_Recording_Setting | 46 | ✅ | {46, 50, 54, 59, 64} = 200M 4:2:2 10bit、150M 4:2:0 10bit、100M 4:2:2 10bit、75M 4:2:0 10bit、45M 4:2:0 10bit。与 SDK 2.00 的 CrRecordingSettingMovie 一致（46 时实测录到 4:2:2；50、59、64 以及换格式时出现的 41、42、45、54、63 都和机身显示一致） |
| 帧率 | 0xD286 | Movie_Recording_FrameRateSetting | 3 | ✅ | {3, 7, 1} = 60p、24p、120p，与 SDK 一致（3 时实测 59.94p，1 时机身显示 120p）。S&Q 用 0xD0D0（记录帧率）和 0xD0D1（录像设置），同一套枚举。实测 S&Q 模式下改 0xD0D0 = 7、0xD052 = 30，机身显示 24p、30fps，相机自动把码率改成 100M 4:2:2 10bit，和回读一致 |
| 拍照 / 录像切换 | 0x500E | ExposureProgramMode | — | ✅ | 没有单独的切换属性：把曝光模式改到另一组即可，见下方 |

## 拍照 / 录像切换（2026-11-16 实测）

曝光模式的值 = 模式组（高位）+ SDK 的 CrExposureProgram（低 16 位）。每组相机列出的顺序都是：智能自动、P、A、S、M。

| 组 | 智能自动 | P | A | S | M | 状态 |
|---|---|---|---|---|---|---|
| 照片 | 0x48000 | 0x10002 | 0x20003 | 0x30004 | 0x1 | ✅ |
| 录像 | 0x78054 | 0x78050 | 0x78051 | 0x78052 | 0x78053 | ✅ 拨杆拨到录像时读到 0x78053 |
| S&Q | 0x9805D | 0x98059 | 0x9805A | 0x9805B | 0x9805C | ✅ 拨杆拨到 S&Q 时读到 0x9805C |
| 间隔录像 | 0xC8097 | 0xC8093 | 0xC8094 | 0xC8095 | 0xC8096 | ✅ 实测（P） |

- 拨杆在录像时，PC 优先下写 1 能切到照片 M，再写 0x78053 切回；照片 P → 录像 A → 录像 M 也都成功，每次加回读约 0.3 秒。拨杆位置不影响远程切换。
- 切到录像后，照片专用的属性（Creative Look、传到电脑的格式、DRO、色彩空间等）变为未启用或仅显示，录像专用的（防抖、时间码、录音、对焦图等）变为可写；切回后恢复。
- 拨杆在录像、相机优先时，白平衡、ISO、快门读到的是录像那一套值（例如 ISO 800、色温 4600K），说明照片和录像各自记一套曝光设置。
- 0xC8093–0xC8097：低 16 位和 SDK 的 CrExposure_Movie_IntervalRec_P/A/S/M/AUTO（0x8093–0x8097）一一对应，是间隔录像（视频延时，直接出成片）那一组。实测远程写 0xC8093 回读为 Interval P，侧栏参数随之可用：0xD055 拍摄间隔（值即秒数，5 = 5 秒）、0xD151 记录帧率、0xD152 录像设置（和录像的 0xD286 / 0xD242 同一套枚举）。照片的「间隔拍摄」是另一套：0xD24F 开关（1 关 / 2 开）和 0xD16A–0xD16F 参数，不改曝光模式。
- 拨盘实测（PriorityKey 交给相机）：AUTO、P、A、S、M 读到的值和照片组一致；拨到 MR 1/2/3 时值不变，相机报告的是记忆里存的模式，不会出现单独的值（SDK 的 CrExposure_MemoryRecall 0x8020 这台不用）。
- MiniDiT：`tether mode --mode photo|movie|sq [--exposure auto|p|a|s|m]`，不给 exposure 时沿用当前字母；需要时先把 PriorityKey 改成 PC，结束联机时改回。

### PriorityKey 的回读延迟

连接时写入 PC 优先后，相机要过一会儿才报告新值。原先写完立刻读，读到的还是旧值，于是没记下原值，结束时也就没改回去，相机一直停在 PC 优先。现在最多等 1 秒；实测连接后 `changedProperties` 里有 PriorityKeySettings（原值 Camera），`tether stop` 后用 camctl 只读确认已回到 Camera。

## 自定义白平衡（2026-11-16 实测）

| 属性 | 含义（libgphoto2 名称 + 实测） |
|---|---|
| 0xD26B / 0xD26C | 可取白区域、取白框尺寸（UINT32）。α7 V 上待机时也一直是 0 |
| 0xD26D | 现在能否进入取白待机：白平衡在自定义 1–3 且不在待机时为 1 |
| 0xD26E | 现在能否取消待机：待机时为 1 |
| 0xD26F | 现在能否取白：待机时为 1 |
| 0xD270 | 执行状态：0 无效、1 待机、2 取白中、3 相机端操作中 |

流程（共约 2.7 秒）：

1. 白平衡设成自定义 N（0x8020 + N − 1）。
2. 控制 0xD2DF 按下（2）再松开（1）→ 约 0.3 秒后 0xD270 = 1，0xD26E、0xD26F = 1，0xD26D = 0。
3. 控制 0xD2E1，数据为 UINT32 位置 `x << 16 | y`（640×480 坐标；用的是中央 (320, 240) = 0x014000F0）→ 0xD270 = 2。
4. 约 0.5 秒后色温（0xD20F，仅显示）和 G–M（0xD210）变成测得的值；再过约 1 秒 0xD270 自动回到 0，相机自己退出待机。
5. 只想退出待机：控制 0xD2E0 按下再松开，0xD270 回到 0。

- 测得的色温和 G–M 都存进槽位：自定义 3 从 5500K / 0 变成 6300K / M1；切到自定义 1 再切回来，仍是 6300K / M1。G–M 是测量结果的一部分，不是单独的微调。
- 菜单里取白后，自定义 1 是 7000K / M1。

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
