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
if [ -f package/sing-box/Makefile ]; then
	sed -i '1i GO_ARM:=5' package/sing-box/Makefile
	echo "GO_ARM=5 forced for sing-box"
else
	echo "WARNING: package/sing-box/Makefile not found, skipping GO_ARM fix" >&2
fi

# HomeProxy 补丁集
HP_RT="$GITHUB_WORKSPACE/homeproxy-rt"
if [ -d "$HP_RT" ]; then
  echo "Applying HomeProxy patch set from $HP_RT ..."
  sh "$HP_RT/apply-patches.sh" package/luci-app-homeproxy || {
    echo "ERROR: apply-patches.sh failed" >&2
    exit 1
  }
  echo "HomeProxy patches applied"
  CN_IP_DIR="package/luci-app-homeproxy/root/etc/homeproxy/resources"
  mkdir -p "$CN_IP_DIR"
  if curl -fsSL --retry 3 --max-time 60 \
      "https://cdn.jsdelivr.net/gh/MetaCubeX/meta-rules-dat@meta/geo/geoip/cn.list" \
      -o "$CN_IP_DIR/cn_ip.list.tmp"; then
    if [ "$(wc -l < "$CN_IP_DIR/cn_ip.list.tmp")" -ge 8000 ]; then
      mv "$CN_IP_DIR/cn_ip.list.tmp" "$CN_IP_DIR/cn_ip.list"
      date -u +%Y-%m-%d > "$CN_IP_DIR/cn_ip.ver"
      echo "Pre-seeded cn_ip.list"
    else
      rm -f "$CN_IP_DIR/cn_ip.list.tmp"
    fi
  else
    rm -f "$CN_IP_DIR/cn_ip.list.tmp"
  fi
else
  echo "WARNING: homeproxy-rt not found" >&2
fi

# 安装 feeds
./scripts/feeds install -a

# K3 专用：移除所有 D-Link 设备（共3个）
BCM53XX_MK="target/linux/bcm53xx/image/Makefile"
if [ -f "$BCM53XX_MK" ]; then
  sed -i 's/^TARGET_DEVICES += dlink_dir-890l/# TARGET_DEVICES += dlink_dir-890l/' "$BCM53XX_MK"
  sed -i 's/^TARGET_DEVICES += dlink_dir-885l/# TARGET_DEVICES += dlink_dir-885l/' "$BCM53XX_MK"
  sed -i 's/^TARGET_DEVICES += dlink_dwl-8610ap/# TARGET_DEVICES += dlink_dwl-8610ap/' "$BCM53XX_MK"
  echo "D-Link devices removed"
fi
# TEST FIX
