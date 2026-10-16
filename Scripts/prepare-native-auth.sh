#!/bin/zsh
set -euo pipefail
project_dir="${0:A:h:h}"
cd "$project_dir"
swift package resolve
# The pinned static targets omit OpenSSL dependencies and refer to a removed
# include directory. Restore that header layout for the bundled Mac framework.
python3 - <<'PY'
from pathlib import Path
import stat
p = Path('.build/checkouts/AltSign/Package.swift')
s = p.read_text()
patches = [
    ('name: "CAltSign",\n            dependencies: ["AltCrypto", "ldid"],',
     'name: "CAltSign",\n            dependencies: ["AltCrypto", "ldid", "OpenSSL"],'),
    ('name: "ldid",\n            dependencies: ["ldid-core"],',
     'name: "ldid",\n            dependencies: ["ldid-core", "OpenSSL"],'),
]
for old, new in patches:
    if old in s:
        s = s.replace(old, new, 1)
    elif new not in s:
        raise SystemExit('Pinned AltSign manifest changed; review the OpenSSL integration patch.')
headers = p.parent / 'Dependencies/OpenSSL/Frameworks/OpenSSL.xcframework/macos-arm64_x86_64/OpenSSL.framework/Headers'
if not (headers / 'err.h').is_file():
    raise SystemExit('Pinned OpenSSL Mac framework headers are missing.')
include = p.parent / 'Dependencies/OpenSSL/ios/include'
include.mkdir(parents=True, exist_ok=True)
compatibility = include / 'openssl'
if compatibility.is_symlink() or compatibility.exists():
    if compatibility.resolve() != headers.resolve():
        raise SystemExit('Unexpected OpenSSL compatibility header directory; review before replacing it.')
else:
    compatibility.symlink_to(headers.resolve(), target_is_directory=True)
if s != p.read_text():
    mode = p.stat().st_mode
    p.chmod(mode | stat.S_IWUSR)
    try:
        p.write_text(s)
    finally:
        p.chmod(mode)
PY
# AltSign's Swift package needs its bundled corecrypto archive, which AltServer
# normally supplies from its Xcode workspace. No Apple account is used here.
xcodebuild -quiet -project .build/checkouts/AltSign/Dependencies/corecrypto/corecrypto.xcodeproj \
  -target corecrypto_static -configuration Release -sdk macosx \
  ARCHS="$(uname -m)" ONLY_ACTIVE_ARCH=YES CODE_SIGNING_ALLOWED=NO MACOSX_DEPLOYMENT_TARGET=14.0 \
  SYMROOT="$project_dir/.build/native-auth" OBJROOT="$project_dir/.build/native-auth/Intermediates" build
