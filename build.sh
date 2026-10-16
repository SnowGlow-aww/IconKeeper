#!/bin/zsh
# 编译 IconKeeper 并装到 /Applications，然后按当前列表写好后台守护。
#
# 签名：优先用环境变量 ICONKEEPER_SIGN_IDENTITY；没设就自动用钥匙串里第一张
# Apple Development 证书；都没有就临时签名（-）。用证书签名，重新编译后
# 「App 管理」权限不会失效；临时签名每次编译后都要在系统设置里重新允许。
#
# 编译产物放在 ICONKEEPER_BUILD_DIR，默认是仓库里的 .build。
set -e
DIR="${0:A:h}"
BUILD="${ICONKEEPER_BUILD_DIR:-$DIR/.build}"
APP=/Applications/IconKeeper.app
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

swiftc -O -parse-as-library -module-cache-path "$BUILD/module-cache" -o "$BUILD/IconKeeper" "$DIR"/Sources/*.swift

STAGE="$BUILD/IconKeeper.app"
rm -rf "$STAGE"
mkdir -p "$STAGE/Contents/MacOS" "$STAGE/Contents/Resources"
cp "$DIR/Info.plist" "$STAGE/Contents/"
cp "$BUILD/IconKeeper" "$STAGE/Contents/MacOS/"
cp "$DIR/AppIcon.icns" "$STAGE/Contents/Resources/"
[[ "$IDENTITY" == "-" ]] && echo "没有找到 Apple Development 证书，使用临时签名"
codesign --force --sign "$IDENTITY" "$STAGE"

pkill -x IconKeeper || true
rm -rf "$APP"
ditto "$STAGE" "$APP"
"$APP/Contents/MacOS/IconKeeper" --install-agent
echo "已安装 $APP"
