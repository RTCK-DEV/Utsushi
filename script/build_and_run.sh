#!/bin/bash
# 単一の .app を常に同じ場所に作り、build / run / verify / test / logs を1本で回す。
set -euo pipefail
export PATH=/opt/homebrew/bin:/usr/bin:/bin
export DEVELOPER_DIR=${DEVELOPER_DIR:-$(ls -d /Applications/Xcode*.app 2>/dev/null | head -1)/Contents/Developer}

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="Utsushi"
BUNDLE_ID="app.rtck.Utsushi"
CONFIG="${CONFIG:-Debug}"
APP_BUNDLE="$ROOT/build/$CONFIG/$APP_NAME.app"
MODE="${1:-run}"

quit_running() {
  osascript -e "tell application \"$APP_NAME\" to quit" >/dev/null 2>&1 || true
  pkill -x "$APP_NAME" >/dev/null 2>&1 || true
  sleep 0.4
}

build() {
  cd "$ROOT"
  [ -f "$ROOT/$APP_NAME.xcodeproj/project.pbxproj" ] || xcodegen generate
  xcodebuild -project "$APP_NAME.xcodeproj" -scheme "$APP_NAME" \
    -configuration "$CONFIG" -destination 'platform=macOS,arch=arm64' build
}

case "$MODE" in
  build) build ;;
  run)   quit_running; build; open -n "$APP_BUNDLE" ;;
  verify)
    quit_running; build; open -n "$APP_BUNDLE"; sleep 3
    if pgrep -x "$APP_NAME" >/dev/null; then
      echo "OK: $APP_NAME は起動して動作している"
    else
      echo "NG: ビルドは通ったが $APP_NAME が起動していない"; exit 1
    fi
    codesign -dv --verbose=2 "$APP_BUNDLE" 2>&1 | sed -n '1,8p'
    ;;
  test)
    cd "$ROOT"
    [ -f "$ROOT/$APP_NAME.xcodeproj/project.pbxproj" ] || xcodegen generate
    xcodebuild -project "$APP_NAME.xcodeproj" -scheme "$APP_NAME" \
      -configuration Debug -destination 'platform=macOS,arch=arm64' test
    ;;
  logs)
    quit_running; build; open -n "$APP_BUNDLE"
    log stream --predicate "process == \"$APP_NAME\"" --level debug
    ;;
  release)
    CONFIG=Release
    APP_BUNDLE="$ROOT/build/Release/$APP_NAME.app"
    quit_running; build
    echo "できたもの: $APP_BUNDLE"
    codesign -dv --verbose=2 "$APP_BUNDLE" 2>&1 | sed -n '1,6p'
    ;;
  install)
    # /Applications に置く。既存があれば置き換える。
    CONFIG=Release
    APP_BUNDLE="$ROOT/build/Release/$APP_NAME.app"
    quit_running; build
    rm -rf "/Applications/$APP_NAME.app"
    cp -R "$APP_BUNDLE" "/Applications/$APP_NAME.app"
    echo "/Applications/$APP_NAME.app に入れた"
    ;;
  dist)
    # 配布用の .dmg を作る。
    #
    # 注意: ad-hoc 署名なので、他の Mac に渡すと Gatekeeper に止められる。
    # 受け取る側は Finder で右クリック →「開く」か、
    #   xattr -dr com.apple.quarantine /Applications/Utsushi.app
    # が要る。これを消すには Apple Developer Program（有償）の
    # Developer ID 証明書と公証が要るので、ここでは対応しない。
    CONFIG=Release
    APP_BUNDLE="$ROOT/build/Release/$APP_NAME.app"
    quit_running; build
    VER=$(defaults read "$APP_BUNDLE/Contents/Info" CFBundleShortVersionString)
    OUT="$ROOT/build/$APP_NAME-$VER-arm64.dmg"
    STAGE="$ROOT/build/dmg-stage"

    rm -rf "$STAGE" "$OUT"
    mkdir -p "$STAGE"
    cp -R "$APP_BUNDLE" "$STAGE/"
    # ドラッグ＆ドロップで入れられるように /Applications への近道を置く
    ln -s /Applications "$STAGE/Applications"
    # 初回に読ませたい注意書き。Gatekeeper の回避手順が要るため。
    cat > "$STAGE/はじめにお読みください.txt" <<'NOTE'
Utsushi — ローカル完結の文字起こしアプリ（Apple Silicon / macOS 26 以降）

導入
  Utsushi.app を隣の Applications へドラッグする。

初回起動
  そのままダブルクリックすると「開発元を確認できないため開けません」と出る。
  Finder で Utsushi.app を右クリック →「開く」→「開く」で起動できる。
  （Apple Developer Program に加入していないため署名が ad-hoc になっている。
   アプリが何かをしているわけではない）

モデルについて
  音声認識モデルは同梱していない。初回実行時に
  ~/Library/Application Support/Utsushi/Models へダウンロードする。
  どれだけ落ちるかは開始前に画面に出る。

音声はこの Mac の外に出ない。
https://github.com/RTCK-DEV/Utsushi
NOTE

    hdiutil create -volname "$APP_NAME" -srcfolder "$STAGE" \
      -ov -format UDZO -fs HFS+ "$OUT" >/dev/null
    rm -rf "$STAGE"
    echo "できたもの: $OUT ($(du -h "$OUT" | cut -f1))"
    echo "受け取る側は初回だけ右クリック →「開く」が要る（ad-hoc 署名のため）"
    ;;
  icon)
    python3 "$ROOT/script/make_icon.py"
    ;;
  clean) rm -rf "$ROOT/build" "$ROOT/$APP_NAME.xcodeproj" ;;
  *) echo "usage: $0 {build|run|verify|test|logs|release|install|dist|icon|clean}"; exit 2 ;;
esac
