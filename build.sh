#!/bin/bash
# 构建 Mac 版：./build.sh  产物在 build/清听.app
# 第一次需要先准备第三方库：./setup-deps.sh
set -euo pipefail
cd "$(dirname "$0")"

RNN=ThirdParty/rnnoise
DF=ThirdParty/DeepFilterNet

if [[ "${1:-}" == "deps" ]]; then
    exec ./setup-deps.sh
fi

APP="build/清听.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

swiftc -O -swift-version 5 -parse-as-library \
    -target arm64-apple-macos15.0 \
    -import-objc-header Sources/Shared/Bridging.h -I $RNN/include \
    Sources/Shared/*.swift Sources/Mac/*.swift \
    $RNN/build/librnnoise.a $DF/target/release/libdf.a \
    -framework Security -framework SystemConfiguration \
    -o "$APP/Contents/MacOS/QingTing"

cp Resources/Mac/Info.plist "$APP/Contents/Info.plist"
cp Resources/Mac/AppIcon.icns "$APP/Contents/Resources/"
cp $DF/models/DeepFilterNet3_onnx.tar.gz $DF/models/DeepFilterNet3_ll_onnx.tar.gz "$APP/Contents/Resources/"
codesign --force --sign - "$APP"
echo "✅ $APP"
