#!/bin/bash
set -e

# 更新 feeds
./scripts/feeds update -a

# HomeProxy：使用 VIKINGYFY/packages 的源码
rm -rf /tmp/viking-packages package/luci-app-homeproxy package/sing-box
git clone --depth=1 https://github.com/VIKINGYFY/packages /tmp/viking-packages || {
	echo "ERROR: Failed to clone VIKINGYFY/packages" >&2
	exit 1
}
[ -d /tmp/viking-packages/luci-app-homeproxy ] || {
	echo "ERROR: luci-app-homeproxy not found in cloned repo" >&2
	exit 1
}
[ -d /tmp/viking-packages/sing-box ] || {
	echo "ERROR: sing-box not found in cloned repo" >&2
	exit 1
}
cp -r /tmp/viking-packages/luci-app-homeproxy package/luci-app-homeproxy
cp -r /tmp/viking-packages/sing-box package/sing-box
rm -rf /tmp/viking-packages

# K3 (BCM4709/Cortex-A9) 无 VFP/NEON, Go 必须软浮点编译, 否则 illegal instruction
# OpenWrt golang-package.mk 用 GO_ARM (带下划线) 做 Makefile 变量, 传给 Go 时才叫 GOARM
# 在 sing-box Makefile 开头强制 GO_ARM=5
if [ -f package/sing-box/Makefile ]; then
	sed -i '1i GO_ARM:=5' package/sing-box/Makefile
	echo "GO_ARM=5 forced for sing-box"
else
	echo "WARNING: package/sing-box/Makefile not found, skipping GO_ARM fix" >&2
fi

# HomeProxy 补丁集：redirect/tproxy 改造 + 防火墙去重 + 原子回滚
HP_RT="$GITHUB_WORKSPACE/homeproxy-rt"
if [ -d "$HP_RT" ]; then
  echo "Applying HomeProxy patch set from $HP_RT ..."
  echo "Patches found:"
  ls -1 "$HP_RT/patches/"*.patch 2>/dev/null || echo "  (no .patch files found!)"
  sh "$HP_RT/apply-patches.sh" package/luci-app-homeproxy || {
    echo "ERROR: apply-patches.sh failed with exit code $?" >&2
    exit 1
  }
  echo "HomeProxy patches applied successfully"
else
  echo "WARNING: homeproxy-rt patch set not found at $HP_RT, building unpatched HomeProxy" >&2
fi

# 安装 feeds
./scripts/feeds install -a
