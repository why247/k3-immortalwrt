#!/bin/bash
set -e

# 更新 feeds
./scripts/feeds update -a

# 安装 feeds（必须在拷贝本地包之前，否则会覆盖本地包）
./scripts/feeds install -a

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
  # Fix math module bug (ucode has no math)
  sed -i "s/import { isnan } from 'math';/const isnan = (x) => x !== x;/" package/luci-app-homeproxy/root/etc/homeproxy/scripts/generate_client.uc
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
# K3 无线配置 v3：自愈式，不管当前是什么状态，最终都要达到正确配置
# - 没有配置：等系统生成后配置
# - 配置错误：强制修正
# - 有幽灵 radio：禁用

[ -f /etc/config/wireless ] || {
  echo "99-k3-wireless: no wireless config, generating..." >&2
  wifi config 2>/dev/null
    sleep 2
  }
  [ -f /etc/config/wireless ] || {
    echo "99-k3-wireless: still no config, abort" >&2
    exit 0
}

# 找真硬件（有 path + 有 band）
RADIO_2G=""
RADIO_5G=""
for r in $(uci -q show wireless 2>/dev/null | grep -o "wireless\.[^.]*\.band=" | cut -d. -f2 | sort -u); do
  [ -z "$(uci -q get wireless.$r.path 2>/dev/null)" ] && continue
  case "$(uci -q get wireless.$r.band 2>/dev/null)" in
    2g|2G) [ -z "$RADIO_2G" ] && RADIO_2G="$r" ;;
    5g|5G) [ -z "$RADIO_5G" ] && RADIO_5G="$r" ;;
  esac
done

[ -n "$RADIO_2G" ] && [ -n "$RADIO_5G" ] || {
  echo "99-k3-wireless: cannot find 2G/5G radios, skip" >&2
  exit 0
}

echo "99-k3-wireless: 2G=$RADIO_2G 5G=$RADIO_5G, enforcing config..."

# 强制设置正确的 radio 参数（不管当前是什么）
uci -q batch <<EOU
set wireless.$RADIO_2G.channel='6'
set wireless.$RADIO_2G.band='2g'
set wireless.$RADIO_2G.htmode='HT20'
set wireless.$RADIO_2G.country='CN'
set wireless.$RADIO_2G.txpower='20'
set wireless.$RADIO_2G.disabled='0'
set wireless.$RADIO_5G.channel='36'
set wireless.$RADIO_5G.band='5g'
set wireless.$RADIO_5G.htmode='VHT160'
set wireless.$RADIO_5G.country='US'
set wireless.$RADIO_5G.txpower='25'
set wireless.$RADIO_5G.disabled='0'
EOU

# 删除所有 wifi-iface，重建（确保 SSID jy、无密码、启用）
for iface in $(uci -q show wireless 2>/dev/null | grep -o "wireless\.[^.]*=wifi-iface" | cut -d. -f2 | cut -d= -f1); do
  uci -q delete "wireless.$iface" 2>/dev/null
done
uci -q batch <<EOU
set wireless.k3_2g=wifi-iface
set wireless.k3_2g.device='$RADIO_2G'
set wireless.k3_2g.mode='ap'
set wireless.k3_2g.ssid='jy'
set wireless.k3_2g.encryption='none'
set wireless.k3_2g.network='lan'
set wireless.k3_2g.disabled='0'
set wireless.k3_5g=wifi-iface
set wireless.k3_5g.device='$RADIO_5G'
set wireless.k3_5g.mode='ap'
set wireless.k3_5g.ssid='jy'
set wireless.k3_5g.encryption='none'
set wireless.k3_5g.network='lan'
set wireless.k3_5g.disabled='0'
commit wireless
EOU

# 禁用所有非真硬件的 radio
for r in $(uci -q show wireless 2>/dev/null | grep -o "wireless\.[^.]*\.path=" | cut -d. -f2 | sort -u); do
  if [ "$r" != "$RADIO_2G" ] && [ "$r" != "$RADIO_5G" ]; then
    uci -q set "wireless.$r.disabled='1'" 2>/dev/null
    echo "99-k3-wireless: disabled phantom $r"
  fi
done
uci -q commit wireless 2>/dev/null

echo "99-k3-wireless: done"
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

# K3 5G txpower via iw on boot (brcmfmac ignores UCI txpower)
mkdir -p files/etc/uci-defaults
cat > files/etc/uci-defaults/98-k3-txpower <<'TXEOF'
#!/bin/sh
for i in 1 2 3 4 5 6 7 8 9 10; do
  sleep 3
  WDEV=$(iw dev 2>/dev/null | grep -B1 "channel 36" | grep Interface | awk '{print $2}')
  [ -n "$WDEV" ] && break
done
[ -n "$WDEV" ] && iw dev "$WDEV" set txpower fixed 2500 2>/dev/null
exit 0
TXEOF
chmod +x files/etc/uci-defaults/98-k3-txpower
