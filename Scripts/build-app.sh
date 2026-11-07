#!/bin/bash
set -euo pipefail
if [ "$#" -ne 1 ] || [[ "$1" != /* ]] || [[ "$1" != *.app ]]; then
  echo "用法：Scripts/build-app.sh /绝对路径/魔兽插件管理器.app" >&2
  exit 2
fi
app_dir="$1"
if [ -e "$app_dir" ]; then
  echo "目标已存在，请选择新路径：$app_dir" >&2
  exit 1
fi
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_dir"
build_root="${WOW_ADDON_BUILD_ROOT:-$project_dir/.build}"
swift build -c release --product AddonManager --scratch-path "$build_root"
bin_dir="$(swift build -c release --product AddonManager --scratch-path "$build_root" --show-bin-path)"
mkdir -p "$app_dir/Contents/MacOS"
cp "$bin_dir/AddonManager" "$app_dir/Contents/MacOS/AddonManager"
cat > "$app_dir/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>AddonManager</string>
<key>CFBundleIdentifier</key><string>io.tigerio.wowaddonmanager</string>
<key>CFBundleName</key><string>魔兽插件管理器</string>
<key>CFBundleDisplayName</key><string>魔兽插件管理器</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.1.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --sign - "$app_dir" >/dev/null
printf '已生成：%s\n' "$app_dir"
