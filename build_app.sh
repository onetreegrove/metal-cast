#!/bin/bash
set -e

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
cd "$DIR"

echo "🔨 [Build] 正在构建 Release 版本..."
swift build -c release

APP_NAME="MetalCast.app"
OUTPUT_DIR="$DIR/output"
APP_DIR="$OUTPUT_DIR/$APP_NAME"

rm -rf "$OUTPUT_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"

# 1. 复制主程序二进制
cp .build/release/MetalCast "$APP_DIR/Contents/MacOS/"

# 2. 复制内置 adb 与 scrcpy-server
cp Resources/adb "$APP_DIR/Contents/Resources/"
cp Resources/scrcpy-server "$APP_DIR/Contents/Resources/"
chmod +x "$APP_DIR/Contents/Resources/adb"

# 3. 复制资源 Bundle (Metal Shaders)
if [ -d ".build/release/MetalCast_MetalCastMedia.bundle" ]; then
    cp -R .build/release/MetalCast_MetalCastMedia.bundle "$APP_DIR/Contents/Resources/"
fi

# 4. 生成 Info.plist
cat <<EOF > "$APP_DIR/Contents/Info.plist"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>MetalCast</string>
    <key>CFBundleIdentifier</key>
    <string>com.justonetree.MetalCast</string>
    <key>CFBundleName</key>
    <string>MetalCast</string>
    <key>CFBundleDisplayName</key>
    <string>MetalCast</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
EOF

echo "✅ [Success] 构建完成！原生应用已打包至: $APP_DIR"
echo "👉 运行命令体验: open \"$APP_DIR\""
