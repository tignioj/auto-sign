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

def write_if_changed(path, content):
    if content == path.read_text():
        return
    mode = path.stat().st_mode
    path.chmod(mode | stat.S_IWUSR)
    try:
        path.write_text(content)
    finally:
        path.chmod(mode)

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
write_if_changed(p, s)

# BOOL is a signed char on Intel Macs. The upstream failure callback passes nil
# (a pointer); use NO only in this Boolean-returning method, not object callbacks.
api = p.parent / 'AltSign/Apple API/ALTAppleAPI.m'
source = api.read_text()
start = source.index('- (void)enableModernFeaturesForAppID:')
end = source.index('\n- (void)', start + 1)
method = source[start:end]
old = 'completionHandler(nil, error);'
new = 'completionHandler(NO, error);'
if method.count(old) == 1:
    method = method.replace(old, new, 1)
elif old in method or new not in method:
    raise SystemExit('Pinned AltSign Boolean callback changed; review the Intel compatibility patch.')
write_if_changed(api, source[:start] + method + source[end:])
PY
# AltSign's Swift package needs its bundled corecrypto archive, which AltServer
# normally supplies from its Xcode workspace. No Apple account is used here.
xcodebuild -quiet -project .build/checkouts/AltSign/Dependencies/corecrypto/corecrypto.xcodeproj \
  -target corecrypto_static -configuration Release -sdk macosx \
  ARCHS="$(uname -m)" ONLY_ACTIVE_ARCH=YES CODE_SIGNING_ALLOWED=NO MACOSX_DEPLOYMENT_TARGET=14.0 \
  SYMROOT="$project_dir/.build/native-auth" OBJROOT="$project_dir/.build/native-auth/Intermediates" build
