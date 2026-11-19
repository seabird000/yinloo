#!/bin/bash
# Builds 音录.app (universal: Apple silicon + Intel) and a drag-to-install .dmg.
# 1.4.0 起应用改名「音录」（原名「E1录音助手」）；bundle id、设置域、钥匙串条目都不变。
set -euo pipefail
cd "$(dirname "$0")"
VERSION="${VERSION:-1.5.0}"
NAME="音录"
DMG="build/Yinloo-$VERSION.dmg"
APP="build/$NAME.app"

# 本机转写组件：sherpa-onnx（Apache-2.0）的 C 接口和 onnxruntime（MIT），通用二进制动态库。不进 Git：
# 第一次打包时从官方发布页下载，核对官方公布的 sha256，解压到 .vendor/（Package.swift 从这里链接）。
SHERPA="sherpa-onnx-v2.0.1-osx-universal2-shared-no-tts-lib"
SHERPA_SHA="242b0593a033456e9344a76a11713d1c55da794d0e37eabf6acabaf7beeb2b36"
if [ ! -f ".vendor/$SHERPA/lib/libsherpa-onnx-c-api.dylib" ]; then
  mkdir -p .vendor/dl
  curl -fsSL -o ".vendor/dl/$SHERPA.tar.bz2" "https://github.com/k2-fsa/sherpa-onnx/releases/download/v2.0.1/$SHERPA.tar.bz2"
  echo "$SHERPA_SHA  .vendor/dl/$SHERPA.tar.bz2" | shasum -a 256 -c -
  tar xjf ".vendor/dl/$SHERPA.tar.bz2" -C .vendor
fi

# PREVIEW=1 ./build.sh makes a build whose screenshot mode (-uiPreview YES …) works; release builds leave it out.
FLAGS=(); [ "${PREVIEW:-0}" = "1" ] && FLAGS=(-Xswiftc -DE1_PREVIEW)
swift build -c release --arch arm64 --arch x86_64 ${FLAGS[@]+"${FLAGS[@]}"}
BIN="$(swift build -c release --arch arm64 --arch x86_64 ${FLAGS[@]+"${FLAGS[@]}"} --show-bin-path)/E1Recorder"

rm -rf build && mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/E1Recorder"
# SwiftPM records the deployment target as the SDK version; macOS would then draw the app with the old look.
# Stamp the real SDK so the system applies the current design (glass toolbar, menu bar panel, sidebar).
xcrun vtool -set-build-version macos 15.0 "$(xcrun --sdk macosx --show-sdk-version)" -replace \
  -output "$APP/Contents/MacOS/E1Recorder" "$APP/Contents/MacOS/E1Recorder"
# Drop debug symbols: they record the build machine's source paths (and so the user name).
xcrun strip -S -x "$APP/Contents/MacOS/E1Recorder"

# 本机识别子程序和它的动态库。开发时用的 rpath（指向 .vendor、.build）删掉，只留 Contents/Frameworks
mkdir -p "$APP/Contents/Frameworks"
cp "$(dirname "$BIN")/yinloo-asr" "$APP/Contents/MacOS/yinloo-asr"
for rp in $(otool -l "$APP/Contents/MacOS/yinloo-asr" | awk '/LC_RPATH/{getline; getline; print $2}' | sort -u); do
  [ "$rp" = "@executable_path/../Frameworks" ] || install_name_tool -delete_rpath "$rp" "$APP/Contents/MacOS/yinloo-asr"
done
xcrun strip -S -x "$APP/Contents/MacOS/yinloo-asr"
cp ".vendor/$SHERPA/lib/libsherpa-onnx-c-api.dylib" ".vendor/$SHERPA/lib/libonnxruntime.dylib" "$APP/Contents/Frameworks/"
# 许可证和 onnxruntime 1.28.2 的第三方组件声明（取自 sherpa 编译用的 onnxruntime-osx-universal2-1.28.2.zip）；
# sherpa 动态库里静态编入的组件（OpenFst、kaldi-native-fbank 等）的声明；本机转写模型的出处和许可（「关于」页有链接）
cp Resources/licenses/sherpa-onnx-LICENSE.txt Resources/licenses/sherpa-onnx-ThirdPartyNotices.txt \
   Resources/licenses/onnxruntime-LICENSE.txt Resources/licenses/onnxruntime-ThirdPartyNotices.txt \
   Resources/licenses/models-NOTICE.txt "$APP/Contents/Resources/"

# adb (Android platform-tools, Apache-2.0) is bundled so the app works on a fresh Mac
ADB="$(python3 -c 'import os,shutil;print(os.path.realpath(shutil.which("adb")))')"
cp "$ADB" "$APP/Contents/Resources/adb"
cp "$(dirname "$ADB")/NOTICE.txt" "$APP/Contents/Resources/adb-NOTICE.txt"
cp ../pen/e1sync.sh ../pen/auto_reboot.sh "$APP/Contents/Resources/"
# WiFi uploader for the pen (Linux arm64, static). Needs Go: brew install go
(cd ../pen/e1wifi && GOOS=linux GOARCH=arm64 CGO_ENABLED=0 go build -trimpath -buildvcs=false -ldflags "-s -w" -o build/e1wifi-arm64 .)
cp ../pen/e1wifi/build/e1wifi-arm64 "$APP/Contents/Resources/"
WIFI_VERSION="$(grep -o 'const version = "[^"]*"' ../pen/e1wifi/main.go | cut -d'"' -f2)"
# App icon: Icon Composer file → Assets.car (macOS 26+ glass icon) + AppIcon.icns (older systems)
xcrun actool "$PWD/Resources/AppIcon.icon" --compile "$PWD/$APP/Contents/Resources" --platform macosx \
  --minimum-deployment-target 15.0 --app-icon AppIcon --output-partial-info-plist "$PWD/build/icon-partial.plist" >/dev/null
rm -f build/icon-partial.plist

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>app.e1recorder.mac</string>
  <key>CFBundleDevelopmentRegion</key><string>zh-Hans</string>
  <key>CFBundleLocalizations</key><array><string>zh-Hans</string></array>
  <key>CFBundleName</key><string>$NAME</string>
  <key>CFBundleDisplayName</key><string>$NAME</string>
  <key>CFBundleExecutable</key><string>E1Recorder</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleIconName</key><string>AppIcon</string>
  <key>CFBundleDocumentTypes</key><array><dict>
    <key>CFBundleTypeName</key><string>录音</string>
    <key>CFBundleTypeRole</key><string>Viewer</string>
    <key>LSHandlerRank</key><string>Alternate</string>
    <key>LSItemContentTypes</key><array><string>public.audio</string><string>public.mpeg-4-audio</string><string>public.movie</string></array>
  </dict></array>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>E1WifiVersion</key><string>$WIFI_VERSION</string>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <key>LSUIElement</key><true/>
  <key>NSMicrophoneUsageDescription</key><string>用于在菜单栏面板里直接录音，录完自动转写成会议纪要。</string>
  <key>NSHumanReadableCopyright</key><string>© 2026 seabird000 · MIT 许可</string>
</dict></plist>
PLIST

# Declare Chinese so system panels (Finder open/save dialogs, menus) appear in Chinese
mkdir -p "$APP/Contents/Resources/zh-Hans.lproj"
printf '"CFBundleDisplayName" = "%s";\n"CFBundleName" = "%s";\n' "$NAME" "$NAME" > "$APP/Contents/Resources/zh-Hans.lproj/InfoPlist.strings"

# Signing: with a local self-signed "E1Recorder Local Signing" certificate (made once in Keychain Access ›
# Certificate Assistant › Create a Certificate…, type "Code Signing") every build keeps the same identity, so macOS
# asks for Keychain access only once instead of after every rebuild. Without it, ad-hoc signing as before.
# The certificate's name can be overridden per machine in app/.signing-identity (not in git).
SIGN_ID="${SIGN_ID:-$(cat .signing-identity 2>/dev/null || echo "E1Recorder Local Signing")}"
if ! security find-certificate -c "$SIGN_ID" >/dev/null 2>&1; then
  echo "signed ad-hoc (no \"$SIGN_ID\" certificate in the keychain)"
  SIGN_ID="-"
fi
# 先签里面的动态库和子程序，再签整个应用
codesign --force --sign "$SIGN_ID" "$APP/Contents/Frameworks/"*.dylib "$APP/Contents/MacOS/yinloo-asr"
codesign --force --sign "$SIGN_ID" "$APP"
[ "$SIGN_ID" = "-" ] || echo "signed with: $SIGN_ID"

STAGE="build/dmg"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/应用程序"
cat > "$STAGE/安装说明.txt" <<'TXT'
音录 安装说明（官网 https://yinloo.com）

1. 把「音录」拖到「应用程序」文件夹。
   从旧版升级：先点菜单栏图标退出旧版，再拖进新版。设置、转写记录和密钥都沿用，原来用什么转写还用什么。
2. 第一次打开会被 macOS 拦住（这个应用没经过苹果公证）：在提示里点「完成」，
   再打开「系统设置 › 隐私与安全性」，往下找到「仍要打开」，点它，输入登录密码确认。
   只要这一次。图文步骤：https://yinloo.com/install
3. 装好就能用本机转写：录音在这台 Mac 上转成文字，不上传，不花钱。
   第一次要下载一个语音模型，约 136 MB。引导第一页点「下载」就行，边下边往后设置。
4. 想要更好的纪要（摘要、要点、待办）：引导第二页选 DeepSeek 或千问，填上你自己的访问密钥。
   不填也能用，纪要里只有逐字稿。以后在「偏好 › 转写 › 服务选项」里随时能改。
5. 有搜狗 E1 录音笔：在笔上打开 adb（通用设置 › 关于本机 › 连续点「MAC 地址」› 开发者模式 › 基本设置 › adb），
   用数据线连到 Mac，以后插上就自动拷新录音。
   有搜狗 C1 Max：直接用数据线连到 Mac 就行，不用设置；音录只读取，不改动笔上的文件。
   用语音备忘录录音的，在引导的「设备」页打开开关。
6. 填过密钥的，每次升级后第一次打开，macOS 会问能不能读钥匙串里的密钥，点「始终允许」。
7. 换电脑：菜单栏图标 › 偏好… › 通用 › 导出配置，到新电脑上导入，再重新填密钥（密钥不跟着配置走）。

源代码和问题反馈：https://github.com/seabird000/yinloo
TXT
hdiutil create -volname "$NAME" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"
echo "built: $APP"
echo "built: $DMG"
