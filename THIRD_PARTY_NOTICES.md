# Third-party notices

`Vendor/CLibssh2.xcframework` contains static builds of the following libraries. `Scripts/build-libssh2-xcframework.sh` builds them from the official source releases. Versions and checksums are in `Vendor/CLibssh2.VERSION`.

## OpenSSL 3.5.9

Licensed under the Apache License, Version 2.0: https://www.openssl.org/source/license.html

Copyright (c) 1998-2025 The OpenSSL Project Authors
Copyright (c) 1995-1998 Eric A. Young, Tim J. Hudson

## libssh2 1.11.1

Licensed under the BSD 3-Clause License: https://libssh2.org/license.html

Copyright (C) The libssh2 project and its contributors.

The full license texts ship with each source release. A shipped app must include them, for example on an in-app "Acknowledgements" page.

## Protocol references (no code copied)

The protocol facts in `docs/PROTOCOL.md` were collected from:
- libgphoto2 (LGPL-2.1+), including issue #1314 for the Nikon Z Wi-Fi pairing handshake and the Canon EOS PTP/IP sequence in `camlibs/ptp2`
- libfuji (MIT) and Fudge (GPL-3.0, read only for protocol facts), for the Fujifilm Wi-Fi handshake and session setup
- "Paparazzi over IP" (Daniel Mende, Pascal Turbing, Troopers 2013), for the Canon EOS Wi-Fi pairing behaviour
- ROCC (MIT)
- sony-alpha-python (no license)
- alpha2go (Apache-2.0)
- Sony's public help guides

This project re-implements the protocol independently and contains no code from these projects.

## Jianying draft format reference (no code copied)

`Sources/MiniDiTCore/JianyingDraft.swift` writes 剪映专业版 drafts using the field layout documented by pyJianYingDraft (Apache-2.0, https://github.com/GuanYixuan/pyJianYingDraft). MiniDiT re-implements the writer in Swift and contains no code from that project.

## DJI Osmo wireless transfer

`Sources/SonyRemoteKit/DJI/` re-implements in Swift the DJI DUML pairing, datalink and media-list protocol as documented and implemented by:

- osmosis, Copyright (c) 2026 Konrad Iturbe, MIT License: https://github.com/KonradIT/osmosis (`MEDIA_PROTOCOL.md`, protocol constants and the file-list decoding rules)
- OsmoOffload, MIT License: https://github.com/intermittech/OsmoOffload (Python reference for the BLE bring-up, datalink transport and session order)

`Tests/SonyRemoteKitTests/Fixtures/DJI/*.bin` are Osmo Pocket 3 file-list captures from osmosis, used under its MIT License (copy in that folder).

MIT License: Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions: The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software. THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND.

## Sony property and control names (camctl)

`Sources/SonyRemoteKit/Sony/SonySDKNames.swift` is transcribed from `sony/props_gen.go` and `sony/controls_gen.go` of:

- ptp v0.1.0, Copyright (c) 2026 mikefsq, MIT License: https://github.com/mikefsq/ptp

It maps Sony wire property / control codes to Camera Remote SDK `CrDeviceProperty` / control names. Value meanings are not taken from it.

MIT License: Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions: The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software. THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
