# Sony α (ILCE-7M4 / ILCE-7M5) PTP/IP + SDIO notes

These notes were compiled 2026-11-04. Everything here comes from source files that were actually downloaded and read. Anything not confirmed in source is marked **UNVERIFIED**.

**Sources (exact versions read):**

| Tag | Repo / file | Version | License |
|---|---|---|---|
| GP | libgphoto2 `camlibs/ptp2/{ptp.h, ptp.c, ptp-pack.c, ptpip.c, ptpip-private.h, library.c, config.c}`, raw from `https://raw.githubusercontent.com/gphoto/libgphoto2/master/camlibs/ptp2/<file>` | master @ `26a57b27caeb865a6b1d415aa5a80b47837c9023` | LGPL-2.1+ (reimplement from facts only) |
| RC | ROCC, `https://github.com/simonmitchell/rocc` (`Sources/Helpers/PTP/**`, `Sources/Manufacturer Implementations/Sony/PTP IP Camera/**`) | `b8b29207e808c1a2e5b397f4d4c0950149e8b76d` (2021-05-19). Targets older ScalarWebAPI-era bodies (A7 III / A9 era), not A7 IV. | MIT |
| SAP | sony-alpha-python, `https://github.com/jakkuh/sony-alpha-python` (`sony_camera/{connection,client,protocol}.py`) | `d40b7a080617664a4efb107930910bf63347f82e` (2026-02-09). Tested by its author on FX30 / A6700, which are "PTP 3" bodies like the A7 IV. | **No LICENSE file, so all rights reserved.** Use the facts only, copy no code. The repo also contains `docs/Camera Control PTP 3 Reference.pdf`, which looks like a redistributed Sony document; I did NOT read or use it. |
| A2G | alpha2go, `https://github.com/knallli/alpha2go` (`docs/protocol.md`, `ptpip/sonyremote.go`) | read 2026-11-04 (a6700 field notes) | Apache-2.0 (facts used, no code copied) |
| SONY | Sony Help Guide ILCE-7M4: `https://helpguide.sony.net/ilc/2110/v1/en/contents/TP1000656591.html`; Sony tutorial: `https://support.d-imaging.sony.co.jp/support/tutorial/ilc/ilce-7m4/l/pcremote.php` | fetched 2026-11-04 | official docs |

All multi-byte integers are **little-endian**, both in PTP/IP framing and in PTP datasets.

---

## 1. PTP/IP framing (GP `ptp.h`, `ptpip.c`; SAP `protocol.py`; RC `Packets/*.swift`)

### Generic header (8 bytes)
| Off | Size | Field |
|---|---|---|
| 0 | u32 | Length of the whole packet, header included |
| 4 | u32 | Packet type |

### Packet types (GP `ptp.h` `PTPIP_*`; SAP and RC agree)
| Type | Name |
|---|---|
| 1 | InitCommandRequest |
| 2 | InitCommandAck |
| 3 | InitEventRequest |
| 4 | InitEventAck |
| 5 | InitFail |
| 6 | OperationRequest (CMD_REQUEST) |
| 7 | OperationResponse (CMD_RESPONSE) |
| 8 | Event |
| 9 | StartData |
| 10 (0x0A) | Data |
| 11 (0x0B) | Cancel(Transaction) |
| 12 (0x0C) | EndData |
| 13 (0x0D) | Ping / ProbeRequest |
| 14 (0x0E) | Pong / ProbeResponse |
| 0xFFFF | RC defines `sonyUnknown1 = 0x0000ffff` (`PainInTheArsePacket`). Its parser scans forward to resync, which implies the camera sometimes emits junk. **UNVERIFIED** on A7 IV. |

### InitCommandRequest (host → camera, command socket) (GP `ptp_ptpip_init_command_request`)
| Off | Size | Field |
|---|---|---|
| 0 | u32 | len = 24 + 2·(nchars+1) + 4 |
| 4 | u32 | 1 |
| 8 | 16 B | Host GUID. GP generates 16 random bytes once and persists them in its settings; SAP uses random bytes per run; RC uses the last 16 ASCII characters of an identifier string. Keep it **stable per install**, because pairing may key on it (**UNVERIFIED**). |
| 24 | var | Friendly name, UTF-16LE, **NUL-terminated** (GP: hostname; RC: device name capped at 80 chars) |
| … | u16 | Protocol version minor = 0x0000 |
| … | u16 | Protocol version major = 0x0001. As a u32 this is 0x00010000; SAP writes it that way. |

### InitCommandAck (camera → host) (GP `ptp_ptpip_init_command_ack`; RC `InitCommandAckPacket`)
| Off (after 8-B header) | Size | Field |
|---|---|---|
| 0 | u32 | Connection number ("eventpipeid"), echoed in InitEventRequest |
| 4 | 16 B | Camera GUID |
| 20 | var | Camera friendly name, UTF-16LE, NUL-terminated |
| … | u32 | Protocol version. GP does not parse it. |

If the camera replies with type 5 (InitFail) instead of 2, GP maps it to `PTP_RC_AccessDenied` ("likely reason is permission denied"). This is the expected failure when pairing or access authentication is missing (see §9).

### InitEventRequest (host → camera, event socket): 12 bytes
`u32 len=12 | u32 type=3 | u32 connectionNumber`

### InitEventAck: 8 bytes, `len=8, type=4`

### OperationRequest (GP `ptp_ptpip_sendreq`)
| Off | Size | Field |
|---|---|---|
| 0 | u32 | len = 18 + 4·nParams |
| 4 | u32 | 6 |
| 8 | u32 | Data phase info: **1** = no data or data-in (camera→host), **2** = data-out (host→camera). This is what GP and RC send. SAP sends 0 and 1, and its author reports it works, so the camera appears tolerant. Use 1/2. |
| 12 | u16 | Opcode |
| 14 | u32 | Transaction ID |
| 18 | u32 × n | Params 1..5 (send only as many as used) |

### OperationResponse (GP `ptp_ptpip_getresp`)
`hdr(8) | u16 code @8 | u32 tid @10 | u32 params @14…`, with nParams = (len − 14)/4.
GP tolerates a stray EndData arriving before the response (`goto retry`). RC says the Sony OpenSession response is sometimes not matched by tid (`callCallbackForAnyResponse` "doesn't contain a transaction ID"), so match it leniently.

### StartData (GP `ptp_ptpip_senddata` / `getdata`)
| Off | Size | Field |
|---|---|---|
| 0 | u32 | len = 20 |
| 4 | u32 | 9 |
| 8 | u32 | tid |
| 12 | u64 | Total data length. GP writes the low u32 at offset 12 and 0 at offset 16; SAP packs `<IIIQ`. |

### Data / EndData
`u32 len = 12 + payload | u32 type (10 or 12) | u32 tid | payload…`
- GP send: payload chunks of ≤ 65536 B. Every chunk except the last is type 10; **the last chunk travels in EndData (12)**.
- SAP send: one Data(10) with the full payload, then an empty EndData(12). Its author reports both styles work.
- Receive: accumulate type 10 and type 12 payloads until the StartData total is reached. Payload length = len − 12.

### Event packet (event socket) (GP `ptp_ptpip_event`)
`hdr(8) | u16 eventCode @8 | u32 tid @10 | u32 p1 @14 | p2 @18 | p3 @22`, with nParams = (len − 14)/4.

### Cancel (type 11)
GP has a TODO and sends nothing. By analogy it would be `u32 len=12 | 11 | u32 tid`, but that is **UNVERIFIED** (not implemented in GP, RC or SAP).

### Ping/Pong (13/14), header-only 8 bytes
- SAP answers type 13 with type 14 on whichever socket received it.
- SAP sends a type 13 keepalive on both sockets after 30 s idle.
- RC replies Pong to Ping on the event socket.

### Transaction ID rules
- GP: `OpenSession` is sent with session/tid fields reset and **TransactionID = 0**. Every later op increments: GetDeviceInfo = 1, and so on.
- GP checks that the response tid equals the request tid.
- RC's counter skips tid 1 and also resets the counter after GetExtDeviceInfo ("Sony app seems to jump current transaction ID back to 2"). This is quirky; don't copy it.
- SAP starts at tid 1 for OpenSession and also works.
- Recommendation: OpenSession tid 0, then strictly +1.

Timeouts: GP uses 2.5 s per socket op (`PTPIP_DEFAULT_TIMEOUT_S 2`, `_MS 500`). GP retries the event-socket connect twice after 100 ms on ECONNREFUSED.

---

## 2. Connection sequence for a Sony body

| # | Channel | Action | Exact values | Source |
|---|---|---|---|---|
| 0 | — | (Access-auth bodies only) Open an SSH tunnel to camera:22 and forward local port → camera `localhost:15740` | see §9 | SAP `connection.py` |
| 1 | TCP | connect cmd socket → `<cam>:15740` | port 15740 | GP `ptp_ptpip_connect` |
| 2 | cmd | InitCommandRequest | GUID, UTF-16 name, version 1.0 | GP |
| 3 | cmd | ← InitCommandAck (or InitFail ⇒ not authorised) | keep connectionNumber | GP |
| 4 | TCP | connect event socket → same host:15740 (GP: retry ×2, 100 ms) | | GP |
| 5 | evt | InitEventRequest(connectionNumber) → ← InitEventAck | | GP |
| 6 | cmd | `OpenSession` 0x1002, p1 = sessionId | GP: sessionId = 1, tid = 0. On `0x2004 InvalidTransactionID` GP retries with sessionId+1, up to 10×. Treat `0x201E SessionAlreadyOpened` as OK. SAP uses a random sessionId and retries on `0x200F AccessDenied` ("camera busy"). | GP `camera_init`, `ptp_opensession`; SAP |
| 7 | cmd | `GetDeviceInfo` 0x1001 (data-in) | Model string = "ILCE-7M4". Over PTP/IP VendorExtensionID may be MTP (0xFFFFFFFF in standard PTP); GP forces Sony when Manufacturer == "Sony Corporation". | GP `fixup_cached_deviceinfo` |
| 8 | cmd | If Operations include 0x9202: `SDIO_Connect` 0x9201 (1, 0, 0), data-in (camera returns 8 bytes, all 0 per GP comment) | phase 1 | GP `ptp_sony_sdioconnect` |
| 9 | cmd | `SDIO_Connect` 0x9201 (2, 0, 0), data-in | phase 2 | GP |
| 10 | cmd | `SDIO_GetExtDeviceInfo` 0x9202 (**0x012C, 1**), data-in. GP repeats up to 20× while the returned list is empty. | 0x12C = 300 = "protocol 3.00". RC sends (0x12C) only; SAP sends (0x12C, 0, 0). | GP `ptp_sony_get_vendorpropcodes` |
| 11 | cmd | `SDIO_Connect` 0x9201 (3, 0, 0), data-in | phase 3 | GP |
| 12 | cmd | Set PriorityMode: `SDIO_SetExtDevicePropValue` 0x9205, p1 = 0xD25A, data-out = **INT8 1** ("application") | GP's table: 0 = Camera, 1 = Application. GP ignores errors (LOG_ON_PTP_E). | GP library.c, config.c `sony_prioritymode` |
| 13 | cmd | `SDIO_GetAllExtDevicePropInfo` 0x9209 (no params in GP; RC sends p1 = 0 or 1 "partial"), data-in → parse §3 | | GP `_ptp_sony_getalldevicepropdesc` |
| 14 | — | GP waits **3 s** after connect before the first capture on ILCE-7M4 (and on ZV-1, A7R4, A7 III, A7S III, A1, A7C…), draining events and re-polling 0x9209 | "need around 3 seconds startup time" | GP `camera_sony_capture` |

**Differences between sources:**
- SAP sends GetStorageIDs (0x1004) before SDIO_Connect 1. After phase 3 it sends GetExtDeviceInfo a second time.
- RC sends opcode **0x920D** ("unknownHandshakeRequest", no params) after phase 3, then polls events. **UNVERIFIED** whether that is needed on the A7 IV.

**GetExtDeviceInfo (0x9202) response layout** (GP; matches RC `SDIOExtDeviceInfo`):
| Off | Type | Field |
|---|---|---|
| 0 | u16 | Camera's protocol version. **0x012C (300)** ⇒ `sony_mode_ver = 3` ("2020 models or later", absolute set). Any other value (e.g. **0x00C8 = 200**) ⇒ mode 2 (stepping). An empty response also means mode 2. |
| 2 | u32 n + u16[n] | List 1: "device properties" (prop codes, plus opcodes/events) |
| … | u32 m + u16[m] | List 2: "controls" (button-type codes such as D2C1/D2C2) |

GP merges both lists and classifies each code by `code & 0x7000`: 0x1000 = opcode, 0x4000 = event, 0x5000 = property. The A7 IV is explicitly listed as a mode-3 body (GP `ptp.c` comment above `sony_mode3_controls`: "A7C / A7S III / A7 IV").

**Sony-specific response codes** (GP `ptp.h`):
- 0xA101 AuthenticationFailed (RC calls the same value `sony_anotherSessionOpen`, and on it does CloseSession + retry)
- 0xA102 PasswordLengthOverMax
- 0xA103 PasswordIncludesInvalidChar
- 0xA104 FeatureVersionInvalidValue
- 0xA105 TemporaryStorageFull
- 0xA106 CameraStatusError

**Standard response codes:** 0x2001 OK, 0x2002 GeneralError, 0x2005 OperationNotSupported, 0x2009 InvalidObjectHandle, 0x200F AccessDenied, 0x2019 DeviceBusy, 0x201C InvalidDevicePropValue, 0x201D InvalidParameter, 0x201E SessionAlreadyOpened.
(SAP uses 0x2013 for "session already open", which disagrees with the standard 0x201E. Handle both.)

### Sony opcodes (GP `ptp.h`)
| Opcode | Name | Params / data |
|---|---|---|
| 0x9201 | SDIO_Connect | (phase, 0, 0), data-in 8 B |
| 0x9202 | SDIO_GetExtDeviceInfo | (0x12C, 1), data-in |
| 0x9203 | GetDevicePropdesc | (propcode), data-in, one Sony DPD |
| 0x9204 | GetDevicePropertyValue | — (not used by GP) |
| 0x9205 | SDIO_SetExtDevicePropValue ("SetControlDeviceA") | (propcode), **data-out = value in the prop's datatype**. Absolute set. |
| 0x9206 | GetControlDeviceDesc | — |
| 0x9207 | SDIO_ControlDevice ("SetControlDeviceB") | (propcode), data-out = value. Used for buttons and for ±step. |
| 0x9209 | SDIO_GetAllExtDevicePropInfo | (), data-in |
| 0x920A / 0x920B / 0x920C / 0x920D | RC: startMovieRec / endMovieRec / terminateCapture / unknownHandshake | **UNVERIFIED** |
| 0x9210 | SDIO_OpenSession | not used by GP |
| 0x9211 | SDIO_GetPartialLargeObject | not used by GP |
| 0x9212 | SDIO_SetContentsTransferMode | not used by GP |
| 0x9215 | SDIO_GetDisplayStringList | — |
| 0x9223 | SDIO_GetLensInformation | — |
| 0x922F | SDIO_OperationsResultsSupported | — |
| 0x9251 | SAP: SDIO_GetExtDeviceProp | **UNVERIFIED** |
| 0x9280 / 0x9281 | GP `ptp_sony_9280/9281` (unnamed) | — |

Standard opcodes used: 0x1001 GetDeviceInfo, 0x1002 OpenSession, 0x1003 CloseSession, 0x1004 GetStorageIDs, 0x1008 GetObjectInfo, 0x1009 GetObject, 0x101B GetPartialObject (RC uses it to download: (handle, 0, size)).

---

## 3. Sony all-props dataset (0x9209 response) (GP `_ptp_sony_getalldevicepropdesc`, `ptp_unpack_Sony_DPD`; RC `getAllDevicePropDesc`, `getDevicePropHeader`)

**Header:** 8 bytes. GP: "nr of entries 32bit, 0 32bit". RC reads it as a u64 count. Then DPD records follow back to back until the buffer ends. GP stops at the first record that fails to parse.

**Per-property record (Sony DPD):**
| Off | Type | Field |
|---|---|---|
| 0 | u16 | DevicePropCode |
| 2 | u16 | DataType (table below) |
| 4 | u8 | GetSet. In mode 3 it is used as-is (0 = get, 1 = get/set). In mode 2, bit 0x80 marks a "control" (GP comment: 0x81 button, 0x82 notch, 0x83 lock, 0x84 variable). |
| 5 | u8 | IsEnabled: 0 = greyed out, 1 = enabled, 2 = display-only. GP mode 3: if ≠ 1, treat as read-only. |
| 6 | T | FactoryDefault value |
| 6+sz | T | CurrentValue |
| … | u8 | FormFlag: 0 none, 1 Range, 2 Enumeration |
| Range | T, T, T | Min, Max, Step |
| Enum | u16 N, T × N | **List 1** |
| (Enum, newer bodies) | u16 N2, T × N2 | **List 2 (twin list)**. After an Enum, GP peeks the next u16. If it is **< 0x200** it is treated as N2 of a second list, and GP **replaces** list 1 with list 2. Otherwise it is the next record's prop code (0x5xxx/0xDxxx). GP comment: "secondary list of items, this is for newer Sonys (2024)". RC models this as `available` vs `supported` lists. Sony's naming is unknown; the second list is most likely "currently settable" vs "supported" (**UNVERIFIED** which is which). |

**Strings:** a STR record whose payload ends after DefaultValue is accepted (GP). Note that RC reads Enum N as u16, the same as GP.

**Controls that never appear in 0x9209:** in mode 3, GP synthesises descriptors for codes that are in the 0x9202 lists but absent from 0x9209:
- D2C1, D2C2, D2C3, D2C4, D2C7, D2C8, D2C9, D2D9 → UINT16 Enum
- D2D1 → UINT16 Range
- D2DC → UINT32 Range
- D2DD → INT8 Range
- D2E9, D2EA → UINT8
- D2CB, D2CC, D2CD–D2D0 → UINT16

So **do not require a button code to be present in 0x9209** before sending 0x9207 to it.

**Extended properties (0xE000–0xEFFF) and controls (0xF000–0xFFFF)**, per Sony's *Camera Control PTP 3 Reference*:
- These need "Flag of Device Property Option" = 1.
- It goes in parameter 2 of 0x9209 (parameter 1 is "only differences", 0 = all), parameter 2 of 0x9205, and parameter 2 of 0x9207.

Verified on the α7 V (vendor code version 3.x, firmware 2.00):
- **Reading:** a plain 0x9209 returns 426 properties. With (0, 1) it returns 488: the 62 properties that 0x9202 advertises but 0x9209 otherwise omits, for example 0xE000 MovieShootingMode (Log shooting) and 0xE042 / 0xE043 focus position.
- **Writing:** 0x9205 on an 0xE*** code without parameter 2 = 1 answers OK, but the value doesn't change.
- **Other single-property reads don't help:** 0x9203 answered OK with no data, and 0x9204 is not supported. Sending 0x1014 / 0x1015 broke the session.

### PTP datatype codes (GP `ptp.h` `PTP_DTC_*`, `ptp_unpack_DPV`)
| Code | Type | Size |
|---|---|---|
| 0x0001 | INT8 | 1 |
| 0x0002 | UINT8 | 1 |
| 0x0003 | INT16 | 2 |
| 0x0004 | UINT16 | 2 |
| 0x0005 | INT32 | 4 |
| 0x0006 | UINT32 | 4 |
| 0x0007 | INT64 | 8 |
| 0x0008 | UINT64 | 8 |
| 0x0009 | INT128 | 16 |
| 0x000A | UINT128 | 16 |
| 0x4000 \| t | Array of t | u32 count + elements |
| 0xFFFF | STR | u8 nChars (**including** the NUL terminator; 0 = empty string), then nChars × UTF-16LE code units |

Caching: GP re-fetches 0x9209 at most every 2 s (`cachetime` default 2) and before every read during capture or set loops ("avoid caching").

---

## 4. Property and control codes (GP `ptp.h`, config.c, library.c; RC `DeviceProperty.swift`)

| Code | Name (GP) | Type / notes |
|---|---|---|
| 0xD20D | ShutterSpeed | UINT32 (§5) |
| 0x5007 | FNumber (standard PTP) | UINT16 ×100 |
| 0xD21E | ISO | UINT32 (§5) |
| 0xD226 | ISO2 | UINT32. GP: "undocumented property on 2020+ cameras", set absolute via 0x9205 |
| 0x5010 | ExposureBiasCompensation | INT16 ×1000. Mode 3: absolute 0x9205 |
| 0xD224 | Sony ExposureCompensation | INT16, absolute 0x9205 (`_put_Sony_ExpCompensation2`). Use whichever code the camera lists. |
| 0x5005 | WhiteBalance | UINT16 (§5), set via 0x9205 (GP `ptp_generic_setdevicepropvalue` routes Sony to 0x9205) |
| 0xD20F | ColorTemp | UINT16 |
| 0x500A | FocusMode | UINT16: 1 Manual, 2 Automatic (AF-S), 3 Auto Macro, 0x8004 AF-C, 0x8005 AF-A, 0x8006 DMF, 0x8007 Manual Reverse, 0x8008 AF-D, 0x8009 Preset Focus. Set via 0x9205; GP polls up to 3 s for it to take. |
| 0x500E | ExposureProgramMode | Mode 3: **UINT32** (§5) |
| 0x5013 | StillCaptureMode | Mode 3: UINT32 (single 0x00000001, Cont Hi 0x00010002, Cont Hi+ 0x00018010, Cont Lo 0x00018012, Cont Mid 0x00018015, self-timer 2 s 0x00038005 / 5 s 0x00038003 / 10 s 0x00038004, …) |
| 0xD218 | BatteryLevel | INT8, Range form. Min −1 may mean "unknown". |
| 0xD20E | BatteryLevelIndicator | — |
| 0xD221 | LiveViewStatus | Values **UNVERIFIED** (GP only names it) |
| 0xD213 | FocusFound | UINT8. 2 (or 3 on RX0) = focus achieved |
| 0xD215 | ObjectInMemory | UINT16. ≥ 0x8000 ⇒ an image is waiting at 0xFFFFC001. GP treats 0x8001 as "1 image" (low bits look like a count; **UNVERIFIED**). GP: the value also briefly reads 1, and downloading then "will crash the firmware", so wait for ≥ 0x8000. |
| 0xD222 | StillImageStoreDestination | UINT16 enum: 0x0001 = host/SDRAM only, 0x0010 = card, 0x0011 = card + host (GP `sony_capturetarget`) |
| 0xD21D | MovieRecordingState | UINT8. SAP: 0 not recording, 1 recording, 2 failed, 3 waiting. **Medium confidence.** |
| 0xD25A | PriorityMode | UINT8: 0 Camera, 1 Application (GP). RC calls it `exposureProgramModeControl`, i.e. whether the camera dial or the PC controls exposure mode. **Conflict between sources.** |
| 0xD268 / 0xD269 | PcSaveImageSize / PcSaveImageFormat | UINT8 |
| 0xD26A | LiveViewImageQuality | — |
| 0xD231 | LiveViewSettingEffect | UINT8 enum [1, 2] |
| 0xD252 / 0xD253 | JpegQuality / CompressionSetting | — |
| 0xD203 / 0xD211 | ImageSize / AspectRatio | UINT8 |
| 0xD248 / 0xD249 / 0xD24A | Slot 1 status / remaining shots / remaining time | — |
| 0xD251 | DeviceOverheatStatus | — |
| 0xD264 | RemoteControlRestrictionStatus | — |
| 0xD278 | RC `liveViewURL` (STR) | HTTP live-view URL on older ScalarWebAPI bodies. **Not GP; UNVERIFIED on A7 IV.** |

### Controls (send with 0x9207 `SDIO_ControlDevice`, data = UINT16 unless noted)
| Code | Name | Press / release |
|---|---|---|
| 0xD2C1 | ShutterHalfRelease (S1 / AF) | **2 = down, 1 = up** (GP capture; `_put_Sony_Autofocus`; RC). SAP: "button type (0x81): Down 0x0002 then Up 0x0001". |
| 0xD2C2 | ShutterRelease (S2) | 2 down, 1 up |
| 0xD2C3 | AELButton | 2 / 1 (assumed; same button type) |
| 0xD2C4 | AFLButton | 2 / 1 (assumed) |
| 0xD2C7 | RequestOneShooting | 2 / 1 (GP bulb path) |
| 0xD2C8 | MovieRecButtonHold | **2 = start (press), 1 = release**. GP `_put_Sony_Movie`; SAP start 0x02, stop 0x01. |
| 0xD2C9 | FELButton | — |
| 0xD2D1 | ManualFocusAdjust | INT16 step −7…+7 (GP) |
| 0xD2D2 | AFMFHold | INT16 1 |
| 0xD2DC | AFAreaPosition | UINT32 |
| 0xD2DD | ZoomOperation | INT8 |
| 0xD2CB / 0xD2CC | FocusMagnifier / Cancel | UINT16 1/2 |
| 0xD2CD–0xD2D0 | RemoteKey Up / Down / Left / Right | UINT16 |
| 0xD2E4 / 0xD2E5 | RemoteTouch / RemoteTouchCancel | SAP |
| AF-ON | — | **No dedicated AF-On code found** in GP or RC. Use S1 (D2C1) for AF. D2C4 is AF *lock*. |

---

## 5. Value encodings

**Shutter speed (0xD20D, UINT32)** (GP `_get/_put_Sony_ShutterSpeed`; RC; SAP)
- `value = (numerator << 16) | denominator`. 1/1000 = 0x000103E8; 1/250 = 0x000100FA.
- Long exposures use denominator 10: 1.5″ = (15 << 16) | 10; 30″ = (300 << 16) | 10. GP normalises x/10 when x % 10 == 0; GP's put for whole seconds sends (10·s) / 10.
- **0x00000000 = BULB.** GP put comment: "Docs imply bulb can be set with zero, but this doesn't seem to work...".
- 0xFFFFFFFF = nothing to display (SAP).
- Mode 3: set **absolute with 0x9205 (SetExtDevicePropValue), UINT32**. GP: "Docs say to call SDIO_ControlDevice, but this doesn't work on A7R4."
- Mode 2 (stepping): 0x9207 with a UINT8 step, 0x01 = +1 notch and 0xFF = −1 notch (GP sends a multi-notch jump n or 0x100 − n on the first iteration). Then re-read 0x9209 until the value changes (poll every 200 ms, ≤ 3 s). Stop on overshoot.
- Enum present ⇒ list of allowed u32 values. GP adds "Bulb" separately.

**F-number (0x5007)**: UINT16 = f × 100 (f/2.8 = 280). SAP: 0xFFFD = "Closed"; 0xFFFE, 0xFFFF and 0 = "--".
- Mode 3: GP sets with 0x9205 but packs the data as **UINT32** (`ptp_sony_setdevicecontrolvaluea(..., PTP_DTC_UINT32)`) even though the dpd type is UINT16. This may be a GP quirk. **UNVERIFIED** which size the A7 IV requires; try the dpd datatype (u16) first, then u32.
- Mode 2: stepping as above.

**ISO (0xD21E, UINT32)** (GP `SONY_ISO_MASK`; SAP `format_iso`; RC)
- Bits 0–23 = ISO number; **0x00FFFFFF = AUTO**.
- Bits 24–31 = flags: 0x01 = Multi-Frame NR, 0x02 = MFNR High (GP `noise_reduction << 24`).
- Bit 28 (0x10000000) = "extended" ISO (RC 0x1000 in the high word; SAP mask 0x10).
- Examples: 0x00FFFFFF = Auto, 0x01FFFFFF = MFNR Auto, 0x02FFFFFF = MFNR Hi Auto, 0x00000064 = ISO 100.
- RC reads only the low **16** bits as the ISO number, which breaks above 65535. Use GP's 24-bit mask.
- Mode 3: absolute 0x9205 UINT32.

**Exposure bias (0x5010 / 0xD224)**: INT16 = EV × 1000 (+0.3 EV = 300, −1.7 EV = −1700). GP snaps to the nearest enum value. Mode 3: absolute 0x9205 INT16.

**White balance (0x5005, UINT16)** (GP `whitebalance[]`; RC agrees):
| Value | Mode |
|---|---|
| 0x0002 | Auto |
| 0x0004 | Daylight |
| 0x0006 | Tungsten / Incandescent |
| 0x0007 | Flash |
| 0x8001 | Fluorescent Warm White |
| 0x8002 | Fluorescent Cool White |
| 0x8003 | Fluorescent Day White |
| 0x8004 | Fluorescent Daylight |
| 0x8010 | Cloudy |
| 0x8011 | Shade |
| 0x8012 | Color Temperature (then set 0xD20F) |
| 0x8020 / 0x8021 / 0x8022 | Custom 1 / 2 / 3 |
| 0x8023 | Custom / Preset |
| 0x8030 | Underwater Auto |

Generic values 0x0001 Manual and 0x0005 Fluorescent may also appear. There may be A7 IV values not in this table (e.g. "AWB ambience/white priority"); treat the enum from 0x9209 as authoritative. **UNVERIFIED.**

**Exposure program (0x500E, UINT32, mode 3)** (GP `sony_exposure_program_32_modes`):
| Value | Mode |
|---|---|
| 0x00000001 | M |
| 0x00010002 | P |
| 0x00020003 | A |
| 0x00030004 | S |
| 0x00048000 | iAuto |
| 0x00048001 | Superior Auto |
| 0x00078050 / 0x00078051 / 0x00078052 / 0x00078053 | Movie P / A / S / M |
| 0x00088084–0x00088087 | S&Q P / A / S / M |
| 0x000A8088 | "Movie" |
| 0x000A8089 | "Still" |
| 0x000B808A | "F (Movie or S&Q)" |
| 0x00008070 | Picture Effect |
| 0x00008020 | Memory Recall |

Mode 2 used UINT16 equivalents (low word). The physical dial normally wins; PriorityMode D25A = 1 may allow PC control (**UNVERIFIED**).

---

## 6. Live view (GP `camera_capture_preview` Sony case; SAP `get_liveview_frame_sync`)

1. Optionally call `GetObjectInfo` 0x1008 (0xFFFFC002) first.
   - SAP does this once before streaming.
   - GP calls it on every frame and retries on 0x2009 InvalidObjectHandle with a 50 ms sleep, because the ZV-1 needs "up to 1 second".
2. Call `GetObject` 0x1009, p1 = **0xFFFFC002**, data-in.
   - On **0x200F AccessDenied** ("we get those when we are too fast"), sleep 20 ms and retry. GP allows 50 tries with a 1 s timeout.
   - On 0x2009, live view is not available (camera not in shooting mode, per SAP).
3. Parse the dataset header (SAP; GP only uses the first field):

| Off | Type | Field |
|---|---|---|
| 0 | u32 | Offset of the live-view JPEG |
| 4 | u32 | JPEG size (0 = no frame yet, so retry) |
| 8 | u32 | Offset of FocalFrameInfo (AF frames) |
| 12 | u32 | FocalFrameInfo size |
| … | | Reserved; GP comment mentions a "128 byte header" |

4. Locate the JPEG. GP checks `data[off] == 0xFF && data[off+1] == 0xD8`, otherwise it scans for the first FFD8 and then for FFD9. Do not blind-scan from 0: GP issue #389 notes that the header itself can contain FF D8.

There is no explicit start/stop live-view opcode in GP or SAP; the frames just exist while in shooting mode. Quality is set through 0xD26A. FocalFrameInfo: the first u16 is version ×100 (100 = 1.00, 101 = 1.01); the full structure is in SAP `_parse_focal_frame_info`. Layout: version u16 + 6 reserved, 40 reserved, then a reserved array (u16 count + 6, count × 24). Then the focus, face (≥ 1.01) and tracking (≥ 1.01) sections. Each section is X denominator u32, Y denominator u32, u16 count + 6 reserved, then count × 24-byte entries: type u16, state u16 (1 not focused, 2 focused), priority u8 + 3 reserved, X u32, Y u32, H u32, W u32. X and Y are the centre; divide by the denominators to get 0…1. **Verified on the α7 V (v1.04):** the tracking frame follows the subject after a remote touch (0xD2E4). Parsed by `SonyDatasets.extractFocalFrames`.

---

## 7. Capture and download (GP `camera_sony_capture`, `camera_wait_for_event` Sony branch; RC `TakePicture`)

1. Optional: set 0xD222 = 0x0001 (host only) or 0x0011 (card + host) via 0x9205 so the image is delivered to the host.
2. **Drain stale images.** Loop:
   - Refresh 0x9209.
   - While D215 ≥ 0x8000 and == 0x8001: `GetObjectInfo(0xFFFFC001)`, then `GetObject(0xFFFFC001)` and discard. (GP: "Image may remain in memory…"; DeleteObject is not supported.)
3. Press `0x9207 D2C1 ← u16 2`, then `0x9207 D2C2 ← u16 2`.
4. If FocusMode ≠ 1 (MF), hold for up to 1 s. End early on any of:
   - event 0xC203 with Param1 == 0xD213
   - event 0xC201
   - polled D213 ∈ {2, 3}
5. Release `D2C2 ← 1`, then `D2C1 ← 1`.
6. Wait up to **35 s** for the image. End on event **0xC201 ObjectAdded** (Param1 = handle) or when polled **D215 ≥ 0x8000**, in which case the handle is **0xFFFFC001**.
7. `GetObjectInfo(handle)` 0x1008. Standard ObjectInfo layout:

| Off | Type | Field |
|---|---|---|
| 0 | u32 | StorageID |
| 4 | u16 | ObjectFormat (0x3801 JPEG, **0xB101 Sony ARW**, 0xB110 HEIF, 0xB301 MPO) |
| 6 | u16 | Protection |
| 8 | u32 | ObjectSize |
| 12 | u16 | ThumbFormat |
| 14 | u32 | ThumbSize |
| 18 | u32 | ThumbWidth |
| 22 | u32 | ThumbHeight |
| 26 | u32 | ImageWidth |
| 30 | u32 | ImageHeight |
| 34 | u32 | BitDepth |
| 38 | u32 | Parent |
| 42 | u16 | AssocType |
| 44 | u32 | AssocDesc |
| 48 | u32 | SeqNo |
| 52 | STR | **Filename** (e.g. DSC01234.ARW) |
| … | STR × 3 | CaptureDate, ModDate, Keywords |

8. Download with `GetObject(handle)` 0x1009. RC uses `GetPartialObject` 0x101B (handle, 0, size).
9. **Repeat until the queue is empty.** GP's wait_for_event loops: refresh 0x9209 → if D215 > 0x8000 then GetObjectInfo + GetObject on 0xFFFFC001 → loop again. RAW+JPEG yields two objects in sequence: GP logs "expecting raw+jpeg" for CompressionSetting 0x13 in mode 2. The FIXME says burst mode is unhandled.

**Bulb** (GP `_put_Sony_Bulb`, odd ordering, copied as-is):
- Start: D2C1 ← 1, then D2C7 ← 2.
- Stop: D2C2 ← 1, then D2C1 ← 1.
- **UNVERIFIED** on A7 IV. Pressing and holding D2C2 at shutter = BULB (0) is the more obvious path but is also unverified.

**Movie:** D2C8 ← 2 (start), D2C8 ← 1 (release / stop), via 0x9207. Watch D21D for the state.

---

## 8. Event codes (GP `ptp.h` `PTP_EC_Sony_*`; RC `EventCode`)

| Code | Name | Params |
|---|---|---|
| 0xC201 | ObjectAdded | p1 = object handle (e.g. 0xFFFFC001) |
| 0xC202 | ObjectRemoved | p1 = handle |
| 0xC203 | DevicePropChanged | p1 = prop code (GP compares Param1 to 0xD213). Many bodies send it without per-prop detail; re-fetch 0x9209. |
| 0xC204 / 0xC205 / 0xC207 | RC "unknown1/2/4" | — |
| 0xC206 | CapturedEvent | — |
| 0xC208 | CWBCaptureResult | — |
| 0xC209 | CameraSettingReadResult | — |
| 0xC20A | FTPSettingReadResult | — |
| 0xC20B | MediaFormatResult | — |
| 0xC20C | FTPDisplayNameListChanged | — |
| 0xC20D | ContentsTransferEvent | — |
| 0xC20F | DisplayListChangedEvent | — |
| 0xC218 | FocusPositionResult | — |
| 0xC21B | LensInformationChanged | — |
| 0xC222 | OperationResult | — |
| 0xC223 | AFStatus | — |
| 0xC224 | MovieRecOperationsResult | — |

Standard events: 0x4002 ObjectAdded, 0x4006 DevicePropChanged, 0x400D CaptureComplete (GP synthesises 0x400D itself).

---

## 9. Wi-Fi, pairing, access authentication (confidence in brackets)

**Access Authentication = SSH.** [HIGH: SONY + SAP]
- Sony's A7 IV help guide: with Access Authen. Off, "communication will be performed without authentication or encryption via SSH connection". With it On, the camera shows a username, password and fingerprint at MENU → Network → Network Option → Access Authen. Info. Imaging Edge prompts for the username and password and asks you to confirm the fingerprint.
- SAP implements this as an **SSH local port-forward**: `ssh -c aes128-ctr -N -L <local>:localhost:15740 <user>@<camIP>`, with keyboard-interactive auth, no pubkey auth, host-key checking disabled. Plain PTP/IP then runs over the tunnel: **both** the command and the event TCP connections go through the same forwarded port.
- For iOS: use an SSH library that supports `direct-tcpip` channels, keyboard-interactive or password auth and the aes128-ctr cipher. Examples are swift-nio-ssh / Citadel / NMSSH; check cipher support (**UNVERIFIED**). Open two forwarded channels to `localhost:15740`, one per PTP/IP socket.
- SSH port 22 is implied by SAP (no `-p` flag) [MEDIUM].
- The fingerprint is presumably the SSH host-key fingerprint, compared against the one the camera displays [MEDIUM; the hash algorithm is UNVERIFIED].
- GP has no SSH support. It only defines response codes 0xA101–0xA103 (auth failed / password length / invalid char).

**Turning auth off.** [HIGH: SONY]
- MENU → Network → Network Option → Access Authen. Settings → Access Authen. On/Off.
- With Off over an access point, you must **pair** first: MENU → Network → Cnct./Remote Sht. → Remote Shoot Function → Pairing. The camera then shows "connection permission / pairing confirmation" prompts.
- Pairing information is erased by camera initialisation.
- After pairing, plain PTP/IP on 15740 should work. Pairing likely keys on the GUID or name from InitCommandRequest (**UNVERIFIED**). An unpaired host likely gets InitFail (GP: "likely reason is permission denied") [MEDIUM].
- Third-party note: Capture One's support article says to set "Access Authen. Settings" Off for A7 IV fw 6.00, and lists A7 IV fw 1.05–5.00 as supported [MEDIUM: secondary source, page returned 403, info from search snippet only].

**A7 IV menu path (Sony help guide 2110, ILCE-7M4).** [HIGH]
- **Access point:**
  1. MENU → Network → Wi-Fi → Wi-Fi Connect → On (join the AP; the phone or computer must be on the same AP).
  2. MENU → Network → Cnct./Remote Sht. → Remote Shoot Function → Remote Shooting → On.
  3. Either use Access Authen. On (enter the credentials) or Access Authen. Off plus Pairing.
- **Wi-Fi Direct:** the camera is the AP. MENU → Network → Cnct./Remote Sht. → Remote Shoot Function → Wi-Fi Direct Info. shows the SSID and password; join it from the phone.
- Remote control is not possible while the camera is connected to a smartphone (Creators' App); disconnect that first. [HIGH: SONY]
- Older-firmware menu names were "PC Remote Function / PC Remote". Names differ between firmware versions. [MEDIUM]

**Default IP in Wi-Fi Direct.** Commonly **192.168.122.1** for Sony cameras acting as the AP (seen in ScalarWebAPI-era projects, e.g. matlab-sonyalpha, port 8080 REST) [**UNVERIFIED** for the A7 IV's PC-remote Wi-Fi Direct]. It is better to use the DHCP gateway / router address of the joined network, or discovery.

**SSDP / UPnP.**
- RC discovers older bodies with M-SEARCH to 239.255.255.250:1900, `ST: urn:schemas-sony-com:service:ScalarWebAPI:1`. It then reads the device XML and uses the `urn:schemas-sony-com:service:DigitalImaging:1` service to decide on PTP/IP [HIGH for RC's target cameras].
- **UNVERIFIED** whether the A7 IV in Remote Shooting mode advertises SSDP, or with which ST. A probe with `ST: ssdp:all` would tell you.
- iOS requires `NSLocalNetworkUsageDescription`, plus the multicast entitlement (`com.apple.developer.networking.multicast`) for SSDP.

---

## 10. Field results on the A7 V (ILCE-7M5) and remote transfer (0x923B–0x923E) [HIGH: tested 2026-11-04]

**A7 V connection, observed.**
- Access Authentication cannot be turned off. TCP 15740 is not reachable directly; SSH on port 22 is.
- Negotiated: kex `ecdh-sha2-nistp256`, host key `ecdsa-sha2-nistp256`, cipher `aes128-ctr`, MAC `hmac-sha2-256`, auth `keyboard-interactive` only.
- `direct-tcpip` channels to `localhost:15740` carry the PTP/IP command and event connections (two channels, one SSH session) [A2G: `127.0.0.1` is rejected].
- Wi-Fi Direct gateway: `192.168.122.1`.
- GetDeviceInfo lists 80 operations, including 0x923B–0x923E.
  - Full list (firmware 2.00, remote transfer session, 2026-11-05): 1001–100A, 100D, 101B; 9201–9207, 9209, 920C–9216, 9219–9229, 922B, 922C, 922F–9234, 9238–9240, 9243, 9244, 9247–9249, 924D, 9250–9254; 9801–9803, 9805.
  - **Power-off behaviour** (2026-11-05): when the camera is switched off mid-download it first answers further 0x923D requests with OperationNotSupported for ~0.5 s, then the TCP link drops. The read in flight completes. Treat a run of failures as a disconnect, not as per-file errors.
  - **No 0x100B DeleteObject**: files can't be deleted over Wi-Fi in this mode. 0x101B GetPartialObject and 0x9211 SDIO_GetPartialLargeObject are listed, so a download can resume from an offset.

**Contents Transfer Mode on the A7 V** (0x9210 mode 1 → 0x9212(2,1,0)):
- Works, but only one storage is exposed (`0x00010001`).
- Hierarchical GetObjectHandles returns nothing; flat listing (parent 0) works (1182 objects).
- GetObjectHandles with a format filter works.
- GetThumb returns ~65–74 KB that is not a bare JPEG.
- The camera UI is locked while the mode is on.

**Remote transfer** [A2G, confirmed on A7 V]. Works in the ordinary remote session: OpenSession + SDIO handshake, no 0x9212. The camera UI stays usable and both slots are reachable.

| Op | Params | Reply |
|---|---|---|
| 0x923B | slot | `u32 n`, `n × u64` capture dates (ms) |
| 0x923C | cursor lo, cursor hi, 100, slot, 0 | contents list (header 0x90 bytes, then `u32 count` + contents) |
| 0x923D | content ID, `slot<<24 \| fileID`, offset lo, offset hi, `size \| last<<31` | file bytes |
| 0x923E | content ID, `slot<<24 \| fileID`, 1 thumbnail / 2 screennail | image |

- Content layout: see `SonyContent.parseList` in `Sources/SonyRemoteKit/Sony/SonyRemoteTransfer.swift`. Each file entry has u16 file ID + padding, a NUL-terminated path, u32 format, u64 size, 32-byte UMID, and optional image / video (0x4C bytes) / audio (0x10 bytes) parameter blocks.
- Paging: the cursor is the created-UTC (ms) of the last content on the previous page; a page shorter than 100 is the last one.
- **Always call 0x923B before 0x923C.** On an empty or missing slot, 0x923C never answers and the session dies [A2G].
- **Don't send these operations unless GetDeviceInfo lists them.** 0x923C with guessed parameters crashed an a6700 [A2G].
- A7 V results: slot 1 has 1033 contents / 1183 files; slot 2 has 883 files. Thumbnail (0x923E type 1) is a ~65 KB JPEG with EXIF. Listing slot 1 took < 1 s.

---

## 11. Per-section sources

| § | Files |
|---|---|
| 1 | GP `ptp.h` (PTPIP_* and PTPIPHeader), `ptpip.c` (sendreq, senddata, getdata, getresp, init_command_request/ack, init_event_request/ack, event, connect), `ptpip-private.h` (timeouts); SAP `protocol.py` (packet builders, probe), `client.py` (keepalive); RC `Packets/Packet.swift`, `InitCommandAckPacket.swift`, `PainInTheArsePacket.swift`, `PTPIPClient.swift` |
| 2 | GP `library.c` (`camera_init` OpenSession loop, `fixup_cached_deviceinfo` Sony block), `ptp.c` (`ptp_opensession`, `ptp_sony_sdioconnect`, `ptp_sony_get_vendorpropcodes`, SONY_PROTOCOL_2_00 = 0xC8 and 3_00 = 0x12C), `ptp.h` (RC_Sony_*, OC_SONY_*); RC `SonyPTPIPCamera.swift` (handshake), `PTP.swift`; SAP `client.py` `_establish_sdio_connection` |
| 3 | GP `ptp-pack.c` (`ptp_unpack_Sony_DPD`, `ptp_unpack_DPV`, `ptp_unpack_string`, `ptp_unpack_uint16_t_array`), `ptp.c` (`_ptp_sony_getalldevicepropdesc`, `sony_mode3_controls`, `ptp_generic_getdevicepropdesc`); RC `ByteBuffer+DeviceProperty.swift`, `PTPIPClient+DeviceProps.swift` |
| 4–5 | GP `ptp.h` (DPC_SONY_*), `config.c` (`PUT_SONY_VALUE_` stepping macro, `_put_Sony_ShutterSpeed(Mode2)`, `_put_Sony_FNumber`, `SONY_ISO_MASK` / `_put_Sony_ISO(2)`, `_put_ExpCompensation`, `_put_Sony_ExpCompensation(2)`, `whitebalance[]`, `focusmodes[]`, `sony_exposure_program_32_modes`, `sony3_capturemode`, `sony_prioritymode`, `sony_capturetarget`, `_put_Sony_Movie/Autofocus/Capture/Bulb/ManualFocus`, `_put_Sony_FocusMode`); RC `PropValueConversion/*.swift`; SAP `protocol.py` format_* |
| 6 | GP `library.c` Sony preview case and `save_jpeg_in_data_to_preview`; SAP `client.py` `_init_liveview`, `get_liveview_frame_sync` |
| 7 | GP `library.c` `camera_sony_capture`, `camera_wait_for_event` Sony branch, `ptp-pack.c` PTP_oi_* offsets, `ptp.h` OFC_SONY_*; RC `SonyPTPIPCamera+TakePicture.swift` |
| 8 | GP `ptp.h` EC_Sony_*; RC `PTP.swift` EventCode; GP `library.c` event checks |
| 9 | SONY help guide 2110 TP1000656591 and the d-imaging ILCE-7M4 tutorial; SAP `connection.py`, README; RC `SonyConstants.swift`, `SonyCameraDiscoverer.swift`, `UPnPService.swift`; Capture One support article 5473534946461 (search snippet only) |

**Licensing reminder:**
- libgphoto2 is LGPL-2.1+: reimplement the protocol facts above, don't copy code.
- ROCC is MIT: code reuse is allowed if you keep the copyright notice.
- sony-alpha-python has no license, so you have no rights to its code. Facts only.
