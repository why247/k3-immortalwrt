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
	# 原理：golang-values.mk 用 GO_ARM:=7 (immediate) 按 CONFIG_CPU_TYPE 的 FPU 推导，
	# 经 golang-package.mk 在 sing-box Makefile 中被 include，会覆盖之前的值。
	# 必须把 GO_ARM:=5 放在 include 之后（last-wins），放在第 1 行无效。
	sed -i '/golang-package\.mk/a GO_ARM:=5' package/sing-box/Makefile
	echo "GO_ARM=5 forced for sing-box (after golang-package.mk include)"
else
	echo "WARNING: package/sing-box/Makefile not found, skipping GO_ARM fix" >&2
fi
# sing-box 精简构建（K3 闪存只有 26MB）
# 只保留 Hysteria2 所需的 with_quic，另含 uTLS 和 Clash API
# 去掉 gVisor/TUN、WireGuard 等 K3 用不上的模块
if [ -f package/sing-box/Makefile ]; then
	sed -i 's/^GO_BUILD_TAGS:=.*/GO_BUILD_TAGS:=with_quic,with_utls,with_clash_api/' package/sing-box/Makefile || \
	echo "GO_BUILD_TAGS:=with_quic,with_utls,with_clash_api" >> package/sing-box/Makefile
	echo "sing-box minimal build tags set"
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
  # 更新描述：TUN -> Redirect+TPROXY (用 sed，比 patch 更稳健)
  sed -i 's|Sing-Box/TUN/AI Edition|Sing-Box/Redirect+TPROXY|g' package/luci-app-homeproxy/Makefile
  sed -i 's|Sing-Box/TUN/AI Edition|Sing-Box/Redirect+TPROXY|g' package/luci-app-homeproxy/htdocs/luci-static/resources/view/homeproxy/server.js
  sed -i 's|Sing-Box/TUN/AI Edition|Sing-Box/Redirect+TPROXY|g' package/luci-app-homeproxy/htdocs/luci-static/resources/view/homeproxy/client.js
  echo "HomeProxy description updated"
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

# 验证中文包在 feeds 里存在（如果不存在，make defconfig 会静默丢掉）
echo "Checking Chinese language packages in feeds..."
for pkg in luci-i18n-base-zh-cn luci-i18n-filemanager-zh-cn luci-i18n-homeproxy-zh-cn; do
  if ./scripts/feeds list -r luci 2>/dev/null | grep -q "^$pkg"; then
    echo "  ✓ $pkg found"
  else
    echo "  ✗ WARNING: $pkg NOT found in luci feed!" >&2
  fi
done

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
# 先删除旧配置，让系统重新检测无线硬件，生成带 path 的配置
rm -f /etc/config/wireless
wifi config
# 动态查找真正的 2.4G 和 5G radio（按 band 属性，不假设 radio 编号）
# 跳过 "unknown" 或无 path 的幽灵 radio
RADIO_2G=""
RADIO_5G=""
for r in $(uci -q show wireless | grep "wireless\..*\.band=" | cut -d. -f2 | cut -d= -f1 | sort -u); do
  # 跳过无 path 的（幽灵设备）
  [ -z "$(uci -q get wireless.$r.path)" ] && continue
  band="$(uci -q get wireless.$r.band)"
  case "$band" in
    2g|2G) [ -z "$RADIO_2G" ] && RADIO_2G="$r" ;;
    5g|5G) [ -z "$RADIO_5G" ] && RADIO_5G="$r" ;;
  esac
done
# 兜底：如果 band 属性没有，用 phy 的频段能力判断
if [ -z "$RADIO_2G" ] || [ -z "$RADIO_5G" ]; then
  for r in $(uci -q show wireless | grep "wireless\..*\.path=" | cut -d. -f2 | sort -u); do
    [ -n "$RADIO_2G" ] && [ -n "$RADIO_5G" ] && break
    # 检查是否已有 band 分配
    [ "$r" = "$RADIO_2G" ] || [ "$r" = "$RADIO_5G" ] && continue
    # 通过 iw phy 信息判断（如果可用）
    phy="$(uci -q get wireless.$r.path | sed 's/.*\///')"
    if iw phy "$phy" info 2>/dev/null | grep -q "2412 MHz"; then
      [ -z "$RADIO_2G" ] && RADIO_2G="$r"
    fi
    if iw phy "$phy" info 2>/dev/null | grep -q "5180 MHz"; then
      [ -z "$RADIO_5G" ] && RADIO_5G="$r"
    fi
  done
fi
if [ -z "$RADIO_2G" ] || [ -z "$RADIO_5G" ]; then
  echo "99-k3-wireless: cannot find real 2G/5G radios (2G=$RADIO_2G 5G=$RADIO_5G), retry next boot" >&2
  rm -f /etc/config/wireless
  exit 1
fi
echo "99-k3-wireless: using 2G=$RADIO_2G 5G=$RADIO_5G"
# 只修改已存在 radio 的属性，不再从零创建 wifi-device
uci -q batch <<EOU
set wireless.$RADIO_2G.channel='6'
set wireless.$RADIO_2G.band='2g'
set wireless.$RADIO_2G.htmode='HT20'
set wireless.$RADIO_2G.country='CN'
set wireless.$RADIO_2G.txpower='20'
set wireless.$RADIO_2G.su_beamformer='0'
set wireless.$RADIO_2G.su_beamformee='0'
set wireless.$RADIO_2G.mu_beamformer='0'
set wireless.$RADIO_2G.mu_beamformee='0'
set wireless.$RADIO_2G.short_gi_20='1'
set wireless.$RADIO_2G.short_gi_40='1'
set wireless.$RADIO_2G.disabled='0'
set wireless.$RADIO_5G.channel='149'
set wireless.$RADIO_5G.band='5g'
set wireless.$RADIO_5G.htmode='VHT80'
set wireless.$RADIO_5G.country='CN'
set wireless.$RADIO_5G.txpower='23'
set wireless.$RADIO_5G.su_beamformer='0'
set wireless.$RADIO_5G.su_beamformee='0'
set wireless.$RADIO_5G.mu_beamformer='0'
set wireless.$RADIO_5G.mu_beamformee='0'
set wireless.$RADIO_5G.short_gi_80='1'
set wireless.$RADIO_5G.tx_stbc='1'
set wireless.$RADIO_5G.rx_stbc='1'
set wireless.$RADIO_5G.disabled='0'
EOU
# 删除所有旧的 wifi-iface，重建两个（SSID jy，无密码）
uci -q show wireless | grep "wireless\..*=wifi-iface" | cut -d. -f2 | cut -d= -f1 | while read -r iface; do
  uci -q delete "wireless.$iface"
done
uci -q batch <<EOU
set wireless.wifi_2g=wifi-iface
set wireless.wifi_2g.device='$RADIO_2G'
set wireless.wifi_2g.mode='ap'
set wireless.wifi_2g.ssid='jy'
set wireless.wifi_2g.encryption='none'
set wireless.wifi_2g.network='lan'
set wireless.wifi_2g.dtim_period='3'
set wireless.wifi_2g.disabled='0'
set wireless.wifi_5g=wifi-iface
set wireless.wifi_5g.device='$RADIO_5G'
set wireless.wifi_5g.mode='ap'
set wireless.wifi_5g.ssid='jy'
set wireless.wifi_5g.encryption='none'
set wireless.wifi_5g.network='lan'
set wireless.wifi_5g.disabled='0'
commit wireless
EOU
# 禁用幽灵 radio（有 path 但无 band 的）
for r in $(uci -q show wireless | grep "wireless\..*\.path=" | cut -d. -f2 | sort -u); do
  [ "$r" = "$RADIO_2G" ] || [ "$r" = "$RADIO_5G" ] || uci -q set "wireless.$r.disabled='1'"
done
uci -q commit wireless
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
cat > files/etc/uci-defaults/99-k3-lang <<'EOF'
#!/bin/sh
# 只有中文翻译文件存在时才设为中文，否则保持 auto（避免设了 zh_cn 但没翻译包导致英文）
if [ -f /usr/lib/lua/luci/i18n/base.zh-cn.lmo ] || [ -f /usr/lib/lua/luci/i18n/base.zh_cn.lmo ]; then
  uci set luci.main.lang='zh_cn'
  uci commit luci
  echo "99-k3-lang: Chinese translation found, set lang=zh_cn"
else
  echo "99-k3-lang: Chinese translation NOT found, keeping auto" >&2
fi
exit 0
EOF
chmod +x files/etc/uci-defaults/99-k3-lang
