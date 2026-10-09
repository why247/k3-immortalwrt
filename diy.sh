#!/bin/bash
set -e

# 更新 feeds
./scripts/feeds update -a

# HomeProxy + sing-box：仓库内固化版本，不再跟随上游（必须在 feeds install 之前）
#   luci-app-homeproxy = VIKINGYFY/packages 23b2ec21 + homeproxy-rt/patches 01-15（已打好）
#   sing-box           = 1.15.0-alpha.10，下面再改成 GO_ARM=7,softfloat + 精简 tags，固定在固件里
rm -rf package/luci-app-homeproxy package/sing-box
for HP_PKG in luci-app-homeproxy sing-box; do
	tar -xzf "$GITHUB_WORKSPACE/homeproxy-rt/vendor/$HP_PKG.tar.gz" -C package || {
		echo "ERROR: vendored $HP_PKG extract failed" >&2
		exit 1
	}
done
grep -m1 "PKG_UPSTREAM_VERSION" package/sing-box/Makefile

# 安装 feeds（本地 package/ 已有 HomeProxy，feeds install 会跳过）
./scripts/feeds install -a

# K3 (BCM4709/Cortex-A9) 无 VFP/NEON, Go 必须软浮点, 否则 illegal instruction
# 用 GOARM=7,softfloat(Go>=1.22)：保留软浮点, 但原子操作/内存屏障改用 ARMv7 原生 LDREX/STREX/DMB, 不再走 GOARM=5 的内核辅助函数
if [ -f package/sing-box/Makefile ]; then
	sed -i '/golang-package\.mk/a GO_ARM:=7,softfloat' package/sing-box/Makefile
	echo "GO_ARM=7,softfloat forced for sing-box (after golang-package.mk include)"
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
		|| { echo "ERROR: sing-box GO_PKG_TAGS not changed" >&2; exit 1; }
fi

# HomeProxy 定制（补丁已在 vendor 包里打好；GOGC/GOMEMLIMIT 由 init 按内存自动设置）
sed -i 's|Sing-Box/TUN/AI Edition|Sing-Box/Redirect+TPROXY|g' \
  package/luci-app-homeproxy/Makefile \
  package/luci-app-homeproxy/htdocs/luci-static/resources/view/homeproxy/server.js \
  package/luci-app-homeproxy/htdocs/luci-static/resources/view/homeproxy/client.js
CN_IP_DIR="package/luci-app-homeproxy/root/etc/homeproxy/resources"
mkdir -p "$CN_IP_DIR"
if curl -fsSL --retry 3 --max-time 60 \
    "https://cdn.jsdelivr.net/gh/MetaCubeX/meta-rules-dat@meta/geo/geoip/cn.list" \
    -o "$CN_IP_DIR/cn_ip.list.tmp" && [ "$(wc -l < "$CN_IP_DIR/cn_ip.list.tmp")" -ge 8000 ]; then
  mv "$CN_IP_DIR/cn_ip.list.tmp" "$CN_IP_DIR/cn_ip.list"
  date -u +%Y-%m-%d > "$CN_IP_DIR/cn_ip.ver"
  echo "Pre-seeded fresh cn_ip.list"
else
  rm -f "$CN_IP_DIR/cn_ip.list.tmp"
  echo "cn_ip.list download failed, keeping vendored copy"
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
