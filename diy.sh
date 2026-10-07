#!/bin/bash
set -e

# 更新 feeds
./scripts/feeds update -a

# HomeProxy：使用 VIKINGYFY/packages 的源码（必须在 feeds install 之前，否则会被官方版覆盖）
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

# 安装 feeds（本地 package/ 已有 HomeProxy，feeds install 会跳过）
./scripts/feeds install -a

# K3 (BCM4709/Cortex-A9) 无 VFP/NEON, Go 必须软浮点编译, 否则 illegal instruction
if [ -f package/sing-box/Makefile ]; then
	sed -i '/golang-package\.mk/a GO_ARM:=5' package/sing-box/Makefile
	echo "GO_ARM=5 forced for sing-box (after golang-package.mk include)"
else
	echo "WARNING: package/sing-box/Makefile not found, skipping GO_ARM fix" >&2
fi
# sing-box 精简构建：只跑 HY2 -> 只要 QUIC (+clash_api 给面板)
# 旧 sed 匹配的是 ^GO_BUILD_TAGS，Makefile 里实际叫 GO_PKG_TAGS，等于一直在编 full 版
# (tailscale/gvisor/wireguard/acme 全带上，体积和常驻内存都大很多)
if [ -f package/sing-box/Makefile ]; then
	sed -i 's/^\([[:space:]]*GO_PKG_TAGS:=\)http2legacy,with_acme.*/\1http2legacy,with_clash_api,with_quic/' package/sing-box/Makefile
	grep -q 'GO_PKG_TAGS:=http2legacy,with_clash_api,with_quic' package/sing-box/Makefile \
		&& echo "sing-box tags: http2legacy,with_clash_api,with_quic" \
		|| echo "WARNING: sing-box GO_PKG_TAGS not changed" >&2
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
  sed -i "s/import { isnan } from 'math';/const isnan = (x) => x !== x;/" package/luci-app-homeproxy/root/etc/homeproxy/scripts/generate_client.uc
  sed -i 's|Sing-Box/TUN/AI Edition|Sing-Box/Redirect+TPROXY|g' package/luci-app-homeproxy/Makefile
  sed -i 's|Sing-Box/TUN/AI Edition|Sing-Box/Redirect+TPROXY|g' package/luci-app-homeproxy/htdocs/luci-static/resources/view/homeproxy/server.js
  sed -i 's|Sing-Box/TUN/AI Edition|Sing-Box/Redirect+TPROXY|g' package/luci-app-homeproxy/htdocs/luci-static/resources/view/homeproxy/client.js
  echo "HomeProxy description updated"
  # sing-box Go 运行时：双核 A9 上 GC 是 HY2 的大头开销
  # GOGC=200 少一半 GC 次数；GOMEMLIMIT 兜底防止 512MB 被吃爆
  HP_INIT=package/luci-app-homeproxy/root/etc/init.d/homeproxy
  sed -i 's/^\([[:space:]]*\)\(.*QUIC_GO_DISABLE_GSO.*\)$/\1\2\n\1procd_append_param env GOGC=200 GOMEMLIMIT=160MiB/' "$HP_INIT"
  grep -q 'GOGC=200' "$HP_INIT" && echo "sing-box GOGC/GOMEMLIMIT set" || echo "WARNING: GOGC not injected" >&2
  CN_IP_DIR="package/luci-app-homeproxy/root/etc/homeproxy/resources"
  mkdir -p "$CN_IP_DIR"
  # geolocation-!cn 规则集：已知国外域名直接走代理，跳过国内 DNS 二次解析
  NONCN_URL='https://cdn.jsdelivr.net/gh/MetaCubeX/meta-rules-dat@sing/geo/geosite/geolocation-!cn.srs'
  if curl -fsSL --retry 3 --max-time 60 "$NONCN_URL" -o "$CN_IP_DIR/geosite_noncn.srs.tmp" && [ "$(wc -c < "$CN_IP_DIR/geosite_noncn.srs.tmp")" -gt 10000 ]; then
    mv "$CN_IP_DIR/geosite_noncn.srs.tmp" "$CN_IP_DIR/geosite_noncn.srs"
    echo "Pre-seeded geosite_noncn.srs"
  else
    rm -f "$CN_IP_DIR/geosite_noncn.srs.tmp"
  fi
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

# 验证中文包在 feeds 里存在
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
