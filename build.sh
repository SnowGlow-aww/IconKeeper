#!/bin/zsh
# 编译 IconKeeper（arm64 + x86_64 通用二进制）。
#   ./build.sh            编译、签名，装到 /Applications，并按当前列表写好后台守护
#   ./build.sh --package  只编译打包出 IconKeeper.zip 和 IconKeeper.dmg，不安装（GitHub Actions 用这个）
#
# 环境变量：
#   ICONKEEPER_SIGN_IDENTITY  签名身份。没设就自动用钥匙串里第一张 Apple Development 证书，
#                             都没有就临时签名（-）。用证书签名，重新编译后「App 管理」权限不会失效；
#                             临时签名每次编译后都要在系统设置里重新允许。
#   ICONKEEPER_BUILD_DIR      编译产物目录，默认是仓库里的 .build
#   ICONKEEPER_VERSION        写进 Info.plist 的版本号（可带 v 前缀），默认用 Info.plist 里的
set -e
DIR="${0:A:h}"
BUILD="${ICONKEEPER_BUILD_DIR:-$DIR/.build}"
APP=/Applications/IconKeeper.app
PACKAGE=0
[[ "${1:-}" == "--package" ]] && PACKAGE=1
IDENTITY="${ICONKEEPER_SIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null | awk '/Apple Development/ { print $2; exit }')}"
IDENTITY="${IDENTITY:--}"

mkdir -p "$BUILD"

# App 图标已经提交在仓库里；删掉 AppIcon.icns 再跑会重新生成
if [[ ! -f "$DIR/AppIcon.icns" ]]; then
  swiftc -O -module-cache-path "$BUILD/module-cache" -o "$BUILD/make-icon" "$DIR/make-icon.swift"
  "$BUILD/make-icon" "$BUILD/icon-1024.png"
  iconset="$BUILD/AppIcon.iconset"
  rm -rf "$iconset" && mkdir "$iconset"
  for s in 16 32 128 256 512; do
    sips -z $s $s "$BUILD/icon-1024.png" --out "$iconset/icon_${s}x${s}.png" >/dev/null
    sips -z $((s * 2)) $((s * 2)) "$BUILD/icon-1024.png" --out "$iconset/icon_${s}x${s}@2x.png" >/dev/null
  done
  iconutil -c icns -o "$DIR/AppIcon.icns" "$iconset"
fi

for arch in arm64 x86_64; do
  swiftc -O -parse-as-library -target "$arch-apple-macos14" -module-cache-path "$BUILD/module-cache" \
    -o "$BUILD/IconKeeper-$arch" "$DIR"/Sources/*.swift
done
lipo -create -output "$BUILD/IconKeeper" "$BUILD/IconKeeper-arm64" "$BUILD/IconKeeper-x86_64"

STAGE="$BUILD/IconKeeper.app"
rm -rf "$STAGE"
mkdir -p "$STAGE/Contents/MacOS" "$STAGE/Contents/Resources"
cp "$DIR/Info.plist" "$STAGE/Contents/"
cp "$BUILD/IconKeeper" "$STAGE/Contents/MacOS/"
cp "$DIR/AppIcon.icns" "$STAGE/Contents/Resources/"
if [[ -n "${ICONKEEPER_VERSION:-}" ]]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${ICONKEEPER_VERSION#v}" \
    -c "Set :CFBundleVersion ${ICONKEEPER_VERSION#v}" "$STAGE/Contents/Info.plist"
fi
[[ "$IDENTITY" == "-" ]] && echo "使用临时签名"
codesign --force --sign "$IDENTITY" "$STAGE"

if (( PACKAGE )); then
  rm -f "$BUILD/IconKeeper.zip" "$BUILD/IconKeeper.dmg"
  ditto -c -k --keepParent "$STAGE" "$BUILD/IconKeeper.zip"
  dmgroot="$BUILD/dmg"
  rm -rf "$dmgroot" && mkdir "$dmgroot"
  ditto "$STAGE" "$dmgroot/IconKeeper.app"
  ln -s /Applications "$dmgroot/Applications"
  hdiutil create -volname IconKeeper -srcfolder "$dmgroot" -ov -format UDZO "$BUILD/IconKeeper.dmg" >/dev/null
  echo "已打包 $BUILD/IconKeeper.zip 和 $BUILD/IconKeeper.dmg"
  exit 0
fi

pkill -x IconKeeper || true
rm -rf "$APP"
ditto "$STAGE" "$APP"
"$APP/Contents/MacOS/IconKeeper" --install-agent
echo "已安装 $APP"
