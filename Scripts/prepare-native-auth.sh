#!/bin/zsh
set -euo pipefail
project_dir="${0:A:h:h}"
cd "$project_dir"
swift package resolve
# The pinned upstream manifest omits OpenSSL from CAltSign's dependencies in
# its static product. Add the binary dependency so SwiftPM supplies its headers.
python3 - <<'PY'
from pathlib import Path
import stat
p = Path('.build/checkouts/AltSign/Package.swift')
s = p.read_text()
old = 'name: "CAltSign",\n            dependencies: ["AltCrypto", "ldid"],'
new = 'name: "CAltSign",\n            dependencies: ["AltCrypto", "ldid", "OpenSSL"],'
if old in s:
    mode = p.stat().st_mode
    p.chmod(mode | stat.S_IWUSR)
    try:
        p.write_text(s.replace(old, new, 1))
    finally:
        p.chmod(mode)
elif new not in s:
    raise SystemExit('Pinned AltSign manifest changed; review the OpenSSL integration patch.')
PY
# AltSign's Swift package needs its bundled corecrypto archive, which AltServer
# normally supplies from its Xcode workspace. No Apple account is used here.
xcodebuild -quiet -project .build/checkouts/AltSign/Dependencies/corecrypto/corecrypto.xcodeproj \
  -target corecrypto_static -configuration Release -sdk macosx \
  ARCHS="$(uname -m)" ONLY_ACTIVE_ARCH=YES CODE_SIGNING_ALLOWED=NO MACOSX_DEPLOYMENT_TARGET=14.0 \
  SYMROOT="$project_dir/.build/native-auth" OBJROOT="$project_dir/.build/native-auth/Intermediates" build
