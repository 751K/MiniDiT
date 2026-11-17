#!/bin/sh
# 在有完整 Xcode 的 Mac 上运行；仅使用调用者给出的临时测试卡。
set -eu
FEATURE_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
FEATURE_BUILD=${MINIDIT_CHECK_BUILD:-/tmp/minidit-feature-xcode}
export FEATURE_ROOT FEATURE_BUILD
case " $* " in
  *" --live-photo "*) FEATURE_SOURCE=LivePhotoChecks.swift ;;
  *" --premiere "*) FEATURE_SOURCE=PremiereBridgeChecks.swift ;;
  *" --look-packs "*) FEATURE_SOURCE=LookPackChecks.swift ;;
  *" --video-delivery "*) FEATURE_SOURCE=VideoDeliveryChecks.swift ;;
  *" --handoff-pdf "*) FEATURE_SOURCE=HandoffPDFChecks.swift ;;
  *" --disk-identity "*) FEATURE_SOURCE=PhysicalDiskChecks.swift ;;
  *" --multi-backup "*) FEATURE_SOURCE=MultiBackupChecks.swift ;;
  *" --agent "*) FEATURE_SOURCE=AgentChecks.swift ;;
  *" --identity "*) FEATURE_SOURCE=IdentityChecks.swift ;;
  *" --journal "*) FEATURE_SOURCE=JournalChecks.swift ;;
  *" --project-layout "*) FEATURE_SOURCE=ProjectLayoutChecks.swift ;;
  *" --project-import "*) FEATURE_SOURCE=ProjectImportChecks.swift ;;
  *" --organization "*) FEATURE_SOURCE=OrganizationChecks.swift ;;
  *" --workflow "*) FEATURE_SOURCE=WorkflowChecks.swift ;;
  *" --dji-card "*) FEATURE_SOURCE=DJICardChecks.swift ;;
  *" --canon-card "*) FEATURE_SOURCE=CanonCardChecks.swift ;;
  *" --tether "*) FEATURE_SOURCE=TetherChecks.swift ;;
  *" --show-ui "*) FEATURE_SOURCE=FeaturePreview.swift ;;
  *) FEATURE_SOURCE=FeatureChecks.swift ;;
esac
export FEATURE_SOURCE
xcodebuild -project "$FEATURE_ROOT/Apps/MiniDiT/MiniDiT.xcodeproj" -scheme MiniDiT \
  -configuration Debug -derivedDataPath "$FEATURE_BUILD" CODE_SIGNING_ALLOWED=NO build \
  > /tmp/minidit-feature-xcode.log 2>&1
python3 - <<'PY'
import os, pathlib, subprocess
root=pathlib.Path(os.environ['FEATURE_ROOT'])
build=pathlib.Path(os.environ['FEATURE_BUILD'])
product=build/'Build/Products/Debug'
objects=build/'Build/Intermediates.noindex/MiniDiT.build/Debug/MiniDiT.build/Objects-normal/arm64'
files=[str(p) for p in sorted(objects.glob('*.o')) if p.name != 'MiniDiTApp.o']
source=os.environ['FEATURE_SOURCE']
cmd=['xcrun','swiftc','-parse-as-library','-swift-version','6','-module-name','MiniDiTFeatureChecks',
     '-I',str(product),'-I',str(root/'Vendor/CLibssh2.xcframework/macos-arm64/Headers'),
     # App 链接了 Sparkle（自动更新）：检查程序也要能找到并加载它。
     '-F',str(product),'-framework','Sparkle','-Xlinker','-rpath','-Xlinker',str(product),
     str(root/'Tests/AppFeatureChecks'/source),*files,
     str(product/'SonyRemoteKit.o'),str(product/'MiniDiTCore.o'),
     str(root/'Vendor/CLibssh2.xcframework/macos-arm64/libCLibssh2.a'),
     '-o',str(build/'feature-checks')]
subprocess.run(cmd,check=True)
PY
exec "$FEATURE_BUILD/feature-checks" "$@"
