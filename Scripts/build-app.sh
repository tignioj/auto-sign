#!/bin/zsh
set -euo pipefail

project_dir="${0:A:h:h}"
cd "$project_dir"
swift build -c release

app_dir="$project_dir/dist/AutoSign.app"
contents_dir="$app_dir/Contents"
mkdir -p "$contents_dir/MacOS" "$contents_dir/Resources"
cp "$project_dir/.build/release/AutoSign" "$contents_dir/MacOS/AutoSign"
cp "$project_dir/.build/release/AutoSignDeviceHelper" "$contents_dir/MacOS/AutoSignDeviceHelper"
cp "$project_dir/.build/release/AutoSignRemoteHelper" "$contents_dir/MacOS/AutoSignRemoteHelper"
cp "$project_dir/Resources/AppInfo.plist" "$contents_dir/Info.plist"
cp "$project_dir/Resources/Brand/AutoSign.icns" "$contents_dir/Resources/AutoSign.icns"
/usr/bin/ditto "$project_dir/ProvisioningHelper" "$contents_dir/Resources/ProvisioningHelper"
codesign --force --deep --sign - "$app_dir"

echo "$app_dir"
