#!/bin/bash
# 把清听装到 iPhone 上：./install-ios.sh
# 免费 Apple ID 签的 App 7 天后失效，到时再跑一次即可，设置不会丢。
# 不用插线也行：手机用数据线配对过一次之后，只要和 Mac 在同一个能互相发现的网络里（手机解锁、亮屏），
# 这个脚本就能通过 Wi-Fi 安装。校园网会隔离设备，不行；用 iPhone 个人热点（Mac 连上去）或自己的路由器热点可以。
# 第一次需要先运行 ./setup-deps.sh 准备第三方库，并在 Xcode → Settings → Accounts 登录 Apple ID。
set -euo pipefail
cd "$(dirname "$0")"
# 开发者团队 ID 等本机配置（不进仓库）
[[ -f local.env ]] && source local.env
export QINGTING_TEAM_ID="${QINGTING_TEAM_ID:?请在 local.env 里写 QINGTING_TEAM_ID=你的开发者团队ID}"
# 终端里配的本地代理没开时会让 Xcode 连不上苹果服务器
unset HTTPS_PROXY HTTP_PROXY https_proxy http_proxy

# 只要真正连得上的 iPhone：状态是 connected（数据线）或 available (paired)（无线）。
# 注意 "unavailable" 里也含有 "available"，必须先排除掉。
UDIDS=$(xcrun devicectl list devices 2>/dev/null | grep physical | grep -i "iphone" | grep -v "unavailable" \
    | grep -E "connected|available" | grep -oE "[0-9A-F]{8}-[0-9A-F]{16}" || true)
if [[ -z "$UDIDS" ]]; then
    echo "没找到连得上的 iPhone：请解锁手机，并用数据线连上；或让 Mac 和手机连同一个热点（校园网不行）"
    exit 1
fi

xcodegen generate >/dev/null
APP=build/DerivedData/Build/Products/Debug-iphoneos/QingTing.app
# 连着几台就装几台
for UDID in $UDIDS; do
    NAME=$(xcrun devicectl list devices 2>/dev/null | grep "$UDID" | sed -E 's/ {2,}.*//')
    echo "→ $NAME"
    xcodebuild -project QingTing.xcodeproj -scheme QingTingPhone -configuration Debug \
        -destination "id=$UDID" -derivedDataPath build/DerivedData -allowProvisioningUpdates build 2>/dev/null \
        | grep -E "error:|BUILD (SUCCEEDED|FAILED)"
    xcrun devicectl device install app --device "$UDID" "$APP" | grep -E "bundleID|error" || true
    if xcrun devicectl device process launch --device "$UDID" com.zhoujingxuan.qingting >/dev/null 2>&1; then
        echo "  ✅ 已安装并打开清听（正在收音的话被关掉了，需要重新点开始）"
    else
        echo "  ✅ 已安装。打不开的话：先解锁手机；首次安装要到 设置 → 通用 → VPN 与设备管理 里信任开发者"
    fi
done
