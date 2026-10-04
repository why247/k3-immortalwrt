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
	# 注意：上游 golang-values.mk 会用 GO_ARM:=7 覆盖此值（immediate assignment）
	# 如果构建出的 sing-box 在 K3 上仍报 illegal instruction，需检查 CI 日志中 go build 的 GOARM 实际值
	# 备选方案：patch feeds/packages/lang/golang/golang-values.mk
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

# --- K3 无线 + LAN (2026-10-04) ---
mkdir -p files/etc/uci-defaults
cat > files/etc/uci-defaults/99-k3-wireless <<'EOF'
#!/bin/sh
uci -q batch <<'EOU'
set wireless.radio0=wifi-device
set wireless.radio0.type='mac80211'
set wireless.radio0.channel='auto'
set wireless.radio0.band='2g'
set wireless.radio0.htmode='HT20'
set wireless.radio0.country='CN'
set wireless.radio0.disabled='0'
set wireless.radio1=wifi-device
set wireless.radio1.type='mac80211'
set wireless.radio1.channel='149'
set wireless.radio1.band='5g'
set wireless.radio1.htmode='VHT80'
set wireless.radio1.country='CN'
set wireless.radio1.disabled='0'
set wireless.default_radio0=wifi-iface
set wireless.default_radio0.device='radio0'
set wireless.default_radio0.mode='ap'
set wireless.default_radio0.ssid='jy'
set wireless.default_radio0.encryption='none'
set wireless.default_radio0.network='lan'
set wireless.default_radio1=wifi-iface
set wireless.default_radio1.device='radio1'
set wireless.default_radio1.mode='ap'
set wireless.default_radio1.ssid='jy'
set wireless.default_radio1.encryption='none'
set wireless.default_radio1.network='lan'
commit wireless
EOU
exit 0
EOF
chmod +x files/etc/uci-defaults/99-k3-wireless
cat > files/etc/uci-defaults/99-k3-lanip <<'EOF'
#!/bin/sh
uci -q set network.lan.ipaddr='192.168.1.1'
uci -q commit network
exit 0
EOF
chmod +x files/etc/uci-defaults/99-k3-lanip
