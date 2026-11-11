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
- libgphoto2 (LGPL-2.1+)
- ROCC (MIT)
- sony-alpha-python (no license)
- alpha2go (Apache-2.0)
- Sony's public help guides

This project re-implements the protocol independently and contains no code from these projects.

## Jianying draft format reference (no code copied)

`Sources/MiniDiTCore/JianyingDraft.swift` writes 剪映专业版 drafts using the field layout documented by pyJianYingDraft (Apache-2.0, https://github.com/GuanYixuan/pyJianYingDraft). MiniDiT re-implements the writer in Swift and contains no code from that project.
