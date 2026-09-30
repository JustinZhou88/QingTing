#!/bin/bash
# 准备第三方降噪库：下载指定版本的源码、打补丁、编译出 Mac / iPhone / 模拟器三套库。
# 只需要在第一次、或换电脑后运行一次：./setup-deps.sh
# 需要：Xcode 命令行工具、Rust（rustup）、约 3GB 磁盘空间。
set -euo pipefail
cd "$(dirname "$0")"

DF_REPO=https://github.com/Rikorose/DeepFilterNet.git
DF_COMMIT=d375b2d8309e0935d165700c91da9de862a99c31
RNN_REPO=https://github.com/xiph/rnnoise.git
RNN_COMMIT=70f1d256acd4b34a572f999a05c87bf00b67730d
DF=ThirdParty/DeepFilterNet
RNN=ThirdParty/rnnoise

# 只取指定的那一个提交，不拉完整历史
fetch() { # repo commit dir
    if [[ ! -d "$3/.git" ]]; then
        git init -q "$3"
        git -C "$3" remote add origin "$1"
        git -C "$3" fetch -q --depth 1 origin "$2"
        git -C "$3" checkout -q FETCH_HEAD
        return 0
    fi
    return 1
}

mkdir -p ThirdParty
if fetch $DF_REPO $DF_COMMIT $DF; then
    # 清听的改动：工作区只保留 libDF、去掉训练用的 hdf5 依赖；C API 增加 df_set_gain_release（增益释放平滑）
    git -C $DF apply "$PWD/Patches/deepfilternet-qingting.patch"
    cp Patches/DeepFilterNet-Cargo.lock $DF/Cargo.lock
fi
fetch $RNN_REPO $RNN_COMMIT $RNN || true

# RNNoise 的模型数据：按 model_version 里的哈希下载并校验
(cd $RNN && hash=$(cat model_version) && [[ -f src/rnnoise_data.c ]] || {
    curl -sSfLO "https://media.xiph.org/rnnoise/models/rnnoise_data-$hash.tar.gz"
    echo "$hash  rnnoise_data-$hash.tar.gz" | shasum -a 256 -c
    tar xzf "rnnoise_data-$hash.tar.gz"
})

RNN_SRC="denoise rnn pitch kiss_fft celt_lpc nnet nnet_default parse_lpcnet_weights rnnoise_data rnnoise_tables"

echo "== Mac 版库"
mkdir -p $RNN/build
for f in $RNN_SRC; do
    clang -O3 -arch arm64 -mmacosx-version-min=15.0 -I$RNN/include -I$RNN/src -DRNNOISE_BUILD -c $RNN/src/$f.c -o $RNN/build/$f.o
done
ar rcs $RNN/build/librnnoise.a $RNN/build/*.o
(cd $DF && MACOSX_DEPLOYMENT_TARGET=15.0 cargo build --release -p deep_filter --features capi --lib)

echo "== iPhone 版库"
rustup target add aarch64-apple-ios
IOS_SDK=$(xcrun --sdk iphoneos --show-sdk-path)
mkdir -p $RNN/build-ios
for f in $RNN_SRC; do
    xcrun --sdk iphoneos clang -O3 -target arm64-apple-ios18.0 -isysroot "$IOS_SDK" -I$RNN/include -I$RNN/src -DRNNOISE_BUILD -c $RNN/src/$f.c -o $RNN/build-ios/$f.o
done
ar rcs $RNN/build-ios/librnnoise.a $RNN/build-ios/*.o
(cd $DF && IPHONEOS_DEPLOYMENT_TARGET=18.0 cargo build --release -p deep_filter --features capi --lib --target aarch64-apple-ios)

echo "== 模拟器用的空实现（只用来看界面，不做降噪）"
SIM_SDK=$(xcrun --sdk iphonesimulator --show-sdk-path)
xcrun --sdk iphonesimulator clang -target arm64-apple-ios18.0-simulator -isysroot "$SIM_SDK" -c ThirdParty/sim-stubs/stubs.c -o ThirdParty/sim-stubs/stubs.o
ar rcs ThirdParty/sim-stubs/libqtstubs.a ThirdParty/sim-stubs/stubs.o

echo "✅ 第三方库准备好了。Mac 版：./build.sh    iPhone 版：./install-ios.sh"
