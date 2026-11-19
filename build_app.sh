#!/bin/bash
set -e

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
cd "$DIR"

VERSION="1.0.0"
UNIVERSAL=false
PACKAGE=false

while [[ $# -gt 0 ]]; do
    case $1 in
        --universal)
            UNIVERSAL=true
            shift
            ;;
        --package)
            PACKAGE=true
            shift
            ;;
        --version)
            VERSION="${2#v}"
            shift 2
            ;;
        v*|[0-9]*)
            VERSION="${1#v}"
            shift
            ;;
        *)
            shift
            ;;
    esac
done

# If GITHUB_REF_NAME is set and looks like a tag, use it
if [[ -n "$GITHUB_REF_NAME" && "$GITHUB_REF_NAME" =~ ^v?[0-9] ]]; then
    VERSION="${GITHUB_REF_NAME#v}"
fi

echo "🔨 [Build] 正在构建 MetalCast v${VERSION} Release 版本..."

APP_NAME="MetalCast.app"
OUTPUT_DIR="$DIR/output"
APP_DIR="$OUTPUT_DIR/$APP_NAME"

rm -rf "$OUTPUT_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"

if [ "$UNIVERSAL" = true ]; then
    echo "🌐 [Universal] 正在编译 arm64 与 x86_64 双架构通用二进制..."
    swift build -c release --triple arm64-apple-macosx
    swift build -c release --triple x86_64-apple-macosx

    echo "🔗 [Lipo] 合并生成 Universal 二进制..."
    lipo -create \
        .build/arm64-apple-macosx/release/MetalCast \
        .build/x86_64-apple-macosx/release/MetalCast \
        -output "$APP_DIR/Contents/MacOS/MetalCast"

    # Copy bundle resource
    if [ -d ".build/arm64-apple-macosx/release/MetalCast_MetalCastMedia.bundle" ]; then
        cp -R .build/arm64-apple-macosx/release/MetalCast_MetalCastMedia.bundle "$APP_DIR/Contents/Resources/"
    elif [ -d ".build/x86_64-apple-macosx/release/MetalCast_MetalCastMedia.bundle" ]; then
        cp -R .build/x86_64-apple-macosx/release/MetalCast_MetalCastMedia.bundle "$APP_DIR/Contents/Resources/"
    fi
else
    echo "⚡️ [Native] 编译当前架构二进制..."
    swift build -c release
    cp .build/release/MetalCast "$APP_DIR/Contents/MacOS/"
    if [ -d ".build/release/MetalCast_MetalCastMedia.bundle" ]; then
        cp -R .build/release/MetalCast_MetalCastMedia.bundle "$APP_DIR/Contents/Resources/"
    fi
fi

# 2. 复制内置通用 adb 与 scrcpy-server
cp Resources/adb "$APP_DIR/Contents/Resources/"
cp Resources/scrcpy-server "$APP_DIR/Contents/Resources/"
chmod +x "$APP_DIR/Contents/Resources/adb"
chmod +x "$APP_DIR/Contents/MacOS/MetalCast"

# 3. 生成 Info.plist
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
    <string>${VERSION}</string>
    <key>CFBundleVersion</key>
    <string>${VERSION}</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
EOF

echo "✅ [Success] 构建完成！原生应用已打包至: $APP_DIR"

if [ "$PACKAGE" = true ]; then
    echo "📦 [Package] 正在生成发布压缩包与 DMG 安装镜像..."
    ARCH_SUFFIX="Universal"
    if [ "$UNIVERSAL" != true ]; then
        ARCH_SUFFIX="$(uname -m)"
    fi

    DMG_NAME="MetalCast-${VERSION}-macOS-${ARCH_SUFFIX}.dmg"
    ZIP_NAME="MetalCast-${VERSION}-macOS-${ARCH_SUFFIX}.zip"

    # 1. 生成保留 macOS 扩展属性的 Release ZIP
    cd "$OUTPUT_DIR"
    ditto -c -k --keepParent "$APP_NAME" "$ZIP_NAME"

    # 2. 生成原生独立 DMG 挂载镜像
    hdiutil create -volname "MetalCast" -srcfolder "$APP_NAME" -ov -format UDZO "$DMG_NAME"

    # 3. 计算 SHA-256 校验和
    shasum -a 256 "$DMG_NAME" "$ZIP_NAME" > SHA256SUMS.txt

    echo "🎉 [Artifacts] 发布制品生成完成:"
    echo "   - $OUTPUT_DIR/$DMG_NAME"
    echo "   - $OUTPUT_DIR/$ZIP_NAME"
    echo "   - $OUTPUT_DIR/SHA256SUMS.txt"
fi
