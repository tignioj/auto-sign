#!/bin/zsh
set -euo pipefail

project_dir="${0:A:h:h}"
cd "$project_dir"
"$project_dir/Scripts/prepare-native-auth.sh"
swift build -c release

dist_dir="$project_dir/dist"
app_dir="$dist_dir/AutoSign.app"
mkdir -p "$dist_dir"
# Build and sign fresh files. Overwriting a running Mach-O with cp preserves
# its inode and can invalidate the process's cached signature/keychain access.
staging_dir="$(mktemp -d "$dist_dir/.AutoSign-build.XXXXXX")"
staged_app="$staging_dir/AutoSign.app"
previous_app="$staging_dir/Previous.app"
cleanup() {
    # Restore the previous bundle if publishing the new one failed.
    if [[ -d "$previous_app" && ! -e "$app_dir" ]]; then
        mv "$previous_app" "$app_dir" || return
    fi
    rm -rf "$staging_dir"
}
trap cleanup EXIT
contents_dir="$staged_app/Contents"
mkdir -p "$contents_dir/MacOS" "$contents_dir/Resources"
mkdir -p "$contents_dir/Frameworks"
/usr/bin/ditto "$project_dir/.build/checkouts/AltSign/Dependencies/OpenSSL/Frameworks/OpenSSL.xcframework/macos-arm64_x86_64/OpenSSL.framework" "$contents_dir/Frameworks/OpenSSL.framework"
chmod -R u+w "$contents_dir/Frameworks/OpenSSL.framework"
cp "$project_dir/.build/release/AutoSign" "$contents_dir/MacOS/AutoSign"
cp "$project_dir/.build/release/AutoSignDeviceHelper" "$contents_dir/MacOS/AutoSignDeviceHelper"
cp "$project_dir/.build/release/AutoSignRemoteHelper" "$contents_dir/MacOS/AutoSignRemoteHelper"
cp "$project_dir/Resources/AppInfo.plist" "$contents_dir/Info.plist"
cp "$project_dir/Resources/Brand/AutoSign.icns" "$contents_dir/Resources/AutoSign.icns"
/usr/bin/ditto "$project_dir/.build/release/AutoSign_AutoSignLocalization.bundle" "$contents_dir/Resources/AutoSign_AutoSignLocalization.bundle"
for language in en zh-Hans; do
    /usr/bin/ditto "$project_dir/Resources/$language.lproj" "$contents_dir/Resources/$language.lproj"
done
/usr/bin/ditto "$project_dir/ProvisioningHelper" "$contents_dir/Resources/ProvisioningHelper"
signing_identity="${AUTOSIGN_MAC_SIGNING_IDENTITY:-}"
if [[ -z "$signing_identity" ]]; then
    signing_identity="$(security find-identity -v -p codesigning | awk '/"Apple Development:/ {print $2; exit}')"
    signing_identity="${signing_identity:--}"
fi
codesign --force --deep --sign "$signing_identity" "$staged_app"
codesign --verify --deep --strict "$staged_app"

if [[ -e "$app_dir" ]]; then
    mv "$app_dir" "$previous_app"
fi
mv "$staged_app" "$app_dir"

echo "$app_dir"
if pgrep -f -x "$app_dir/Contents/MacOS/AutoSign" >/dev/null; then
    echo "AutoSign is running. Quit and reopen it to use the new build." >&2
fi
