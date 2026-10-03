#!/bin/bash
set -e

# 更新 feeds
./scripts/feeds update -a

# HomeProxy：使用 VIKINGYFY/packages 的源码
rm -rf /tmp/viking-packages package/luci-app-homeproxy package/sing-box
git clone --depth=1 https://github.com/VIKINGYFY/packages /tmp/viking-packages
cp -r /tmp/viking-packages/luci-app-homeproxy package/luci-app-homeproxy
cp -r /tmp/viking-packages/sing-box package/sing-box
rm -rf /tmp/viking-packages

# K3 (BCM4709/Cortex-A9) 无 VFP/NEON, Go 必须软浮点编译, 否则 illegal instruction
# 在 sing-box Makefile 开头强制 GOARM=5
sed -i '1i GOARM:=5' package/sing-box/Makefile

# HomeProxy 补丁集：redirect/tproxy 改造 + 防火墙去重 + 原子回滚
HP_RT="$GITHUB_WORKSPACE/homeproxy-rt"
if [ -d "$HP_RT" ]; then
  echo "Applying HomeProxy patch set from $HP_RT ..."
  sh "$HP_RT/apply-patches.sh" package/luci-app-homeproxy
else
  echo "WARNING: homeproxy-rt patch set not found at $HP_RT, building unpatched HomeProxy" >&2
fi

# 安装 feeds
./scripts/feeds install -a
