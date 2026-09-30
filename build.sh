#!/bin/bash
# 构建 Apple Container.app
#
# 本机情况：只有 CommandLineTools + Xcode-beta，且 CLT 的编译器与 SDK 版本不匹配。
# 因此固定使用 Xcode-beta 的 toolchain，并显式加载 SwiftUI 宏插件
# （libSwiftUIMacros.dylib 在 Platform 目录里、不在 toolchain 里，不加载会报
#  "external macro implementation type 'SwiftUIMacros.StateMacro' could not be found"）。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_NAME="Apple Container"
EXEC_NAME="AppleContainer"
BUILD_DIR="$ROOT/build"
APP_DIR="$BUILD_DIR/$APP_NAME.app"
MODULE_CACHE="$BUILD_DIR/modulecache"

XCODE_DEV="/Applications/Xcode-beta.app/Contents/Developer"
PLATFORM_DIR="$XCODE_DEV/Platforms/MacOSX.platform/Developer"

if [ ! -d "$XCODE_DEV" ]; then
  echo "错误：找不到 $XCODE_DEV" >&2
  exit 1
fi

echo "==> 清理"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources" "$MODULE_CACHE"

# 收集需要加载的宏插件（SwiftUI 的 State/Binding、Observation 的 Observable 等）
PLUGIN_FLAGS=()
for lib in libSwiftUIMacros libSwiftMacros libObservationMacros; do
  for dir in "$PLATFORM_DIR/usr/lib/swift/host/plugins" "$XCODE_DEV/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/host/plugins"; do
    if [ -f "$dir/$lib.dylib" ]; then
      PLUGIN_FLAGS+=("-load-plugin-library" "$dir/$lib.dylib")
      break
    fi
  done
done

echo "==> 编译 Swift 源码"
SOURCES=("$ROOT"/Sources/ContainerGUI/*.swift)

DEVELOPER_DIR="$XCODE_DEV" xcrun swiftc \
  -module-cache-path "$MODULE_CACHE" \
  "${PLUGIN_FLAGS[@]}" \
  -parse-as-library \
  -O \
  -target arm64-apple-macosx14.0 \
  -framework SwiftUI \
  -framework AppKit \
  -framework Combine \
  -o "$APP_DIR/Contents/MacOS/$EXEC_NAME" \
  "${SOURCES[@]}"

echo "==> 组装 bundle"
cp "$ROOT/Resources/Info.plist" "$APP_DIR/Contents/Info.plist"

# ---- 图标：可随时用 make-icon.swift 现场重绘 ----
ICON_DIR="$BUILD_DIR/icon"
if [ -f "$ROOT/make-icon.swift" ]; then
  echo "==> 生成图标"
  rm -rf "$ICON_DIR"
  mkdir -p "$ICON_DIR"
  DEVELOPER_DIR="$XCODE_DEV" xcrun swiftc \
    -module-cache-path "$BUILD_DIR/iconmc" -O \
    -o "$BUILD_DIR/make-icon" "$ROOT/make-icon.swift" 2>&1 | grep -E "error" || true
  if [ -x "$BUILD_DIR/make-icon" ]; then
    "$BUILD_DIR/make-icon" "$ICON_DIR" || true
  fi
fi

# .icns：macOS 15 及更早通过 CFBundleIconFile 读取
ICNS_SRC="$ROOT/Resources/AppIcon.icns"
[ -f "$ICON_DIR/AppIcon.icns" ] && ICNS_SRC="$ICON_DIR/AppIcon.icns"

# Assets.car：macOS 26+ 的分层图标来源（深色/着色适配也在这里）。
# 只有真的编译出 Assets.car 才写 CFBundleIconName —— 写了却找不到 catalog 图标，
# 旧系统会连 .icns 一起放弃，变成白图标。
HAS_CAR=0
ICON_NAME="AppIcon"
if [ -d "$ICON_DIR/$ICON_NAME.icon" ]; then
  echo "==> 编译分层图标（actool）"
  rm -rf "$BUILD_DIR/iconcar"
  mkdir -p "$BUILD_DIR/iconcar"
  if DEVELOPER_DIR="$XCODE_DEV" xcrun actool "$ICON_DIR/$ICON_NAME.icon" \
      --compile "$BUILD_DIR/iconcar" \
      --platform macosx \
      --minimum-deployment-target 15.0 \
      --app-icon "$ICON_NAME" \
      --include-all-app-icons \
      --output-partial-info-plist "$BUILD_DIR/iconcar/partial.plist" \
      > "$BUILD_DIR/iconcar/actool.log" 2>&1; then
    if [ -f "$BUILD_DIR/iconcar/Assets.car" ]; then
      HAS_CAR=1
      echo "    Assets.car: $(du -h "$BUILD_DIR/iconcar/Assets.car" | cut -f1)"
    fi
  else
    echo "    !! actool 失败，退回纯 .icns" >&2
    sed 's/^/    /' "$BUILD_DIR/iconcar/actool.log" >&2 | head -20
  fi
fi

if [ -f "$ICNS_SRC" ]; then
  cp "$ICNS_SRC" "$APP_DIR/Contents/Resources/AppIcon.icns"
else
  /usr/libexec/PlistBuddy -c "Delete :CFBundleIconFile" "$APP_DIR/Contents/Info.plist" 2>/dev/null || true
fi

if [ "$HAS_CAR" = "1" ]; then
  cp "$BUILD_DIR/iconcar/Assets.car" "$APP_DIR/Contents/Resources/Assets.car"
  /usr/libexec/PlistBuddy -c "Add :CFBundleIconName string $ICON_NAME" "$APP_DIR/Contents/Info.plist" 2>/dev/null || \
    /usr/libexec/PlistBuddy -c "Set :CFBundleIconName $ICON_NAME" "$APP_DIR/Contents/Info.plist"
fi

printf 'APPL????' > "$APP_DIR/Contents/PkgInfo"

echo "==> 签名（ad-hoc）"
codesign --force --deep --sign - "$APP_DIR" >/dev/null 2>&1 || \
  codesign --force --deep --sign - "$APP_DIR" 2>&1 | tail -3

echo "==> 完成: $APP_DIR"
du -sh "$APP_DIR"
