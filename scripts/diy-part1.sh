#!/bin/bash
# ============================================================================
# diy-part1.sh —— iStoreOS 25.12 + NSS 移植注入（feeds update 之前执行）
# 工作目录：openwrt/
#
# 两步：
#   A. zn_m2 设备注入（DTS + 设备定义 + 网口 + LED + 去 source-only）
#   B. NSS 硬件加速使能（feeds + 内核补丁 + nss.dtsi + 设备 DTS）
#
# 设计要点：iStoreOS 25.12 用非版本化 files 目录（files/arch/arm64/boot/dts/qcom），
#           内核补丁在 patches-6.12。NSS 使能所需的 nss.dtsi / 设备 DTS / 内核补丁
#           在 iStoreOS 主线缺失，统一从 qosmio/openwrt-ipq（权威 NSS 源）拉取，
#           退路再试 LibWrt 25.12-nss；CI 网络可靠，拉取稳定。
# ============================================================================
set -e

echo "=============================================================="
echo "  ZN-M2 + NSS 移植注入开始 (iStoreOS 25.12, kernel 6.12)"
echo "  工作目录: $(pwd)"
echo "=============================================================="

PATCH_SRC="${GITHUB_WORKSPACE}/patch"
QCA="target/linux/qualcommax"
DTS_DIR="$QCA/files/arch/arm64/boot/dts/qcom"   # 25.12 用非版本化 files 目录
PATCHDIR="$QCA/patches-6.12"
MK="$QCA/image/ipq60xx.mk"
NET="$QCA/ipq60xx/base-files/etc/board.d/02_network"
LED="$QCA/ipq60xx/base-files/etc/board.d/01_leds"
TMK="$QCA/ipq60xx/target.mk"

# ---------------------------------------------------------------------------
# A. zn_m2 设备注入
# ---------------------------------------------------------------------------
if [ ! -d "$QCA" ]; then
    echo "!! 致命错误：找不到 $QCA，源码结构可能已变"
    exit 1
fi
mkdir -p "$DTS_DIR"

echo ""
echo "[A1/5] 注入 DTS：ipq6000-m2.dts（fallback 版，B 步会用上游 NSS 版覆盖）"
if [ -f "$PATCH_SRC/ipq6000-m2.dts" ]; then
    cp "$PATCH_SRC/ipq6000-m2.dts" "$DTS_DIR/"
    echo "    ✓ 已复制 fallback DTS"
else
    echo "    !! patch/ipq6000-m2.dts 缺失"
    exit 1
fi

echo ""
echo "[A2/5] 注入设备定义：define Device/zn_m2"
if [ ! -f "$MK" ]; then
    echo "    !! $MK 不存在"
    exit 1
fi
if grep -q "define Device/zn_m2" "$MK"; then
    echo "    ✓ 已存在，跳过"
else
    cat >> "$MK" <<'MKEOF'

define Device/zn_m2
	$(call Device/FitImage)
	$(call Device/UbiFit)
	DEVICE_VENDOR := ZN
	DEVICE_MODEL := M2
	BLOCKSIZE := 128k
	PAGESIZE := 2048
	SOC := ipq6000
	DEVICE_DTS_CONFIG := config@cp03-c1
	# 无 WiFi 精简版；NSS 硬件加速已在 kernel patches 中开启
	DEVICE_PACKAGES :=
endef
TARGET_DEVICES += zn_m2
MKEOF
    echo "    ✓ 已追加设备定义"
fi
echo "    --- 当前 ipq60xx.mk 设备列表 ---"
grep -o 'define Device/[A-Za-z0-9_-]*' "$MK" | sed 's|define Device/|      |'

echo ""
echo "[A3/5] 注入网口配置：02_network"
if [ ! -f "$NET" ]; then
    echo "    !! $NET 不存在"
    exit 1
fi
if grep -q 'zn,m2' "$NET"; then
    echo "    ✓ 已含 zn,m2，跳过"
else
    if grep -q 'Unsupported hardware' "$NET"; then
        sed -i '/echo "Unsupported hardware/i\\tzn,m2)\n\t\tucidef_set_interfaces_lan_wan "lan1 lan2 lan3" "wan"\n\t\t;;' "$NET"
        echo "    ✓ 已在 Unsupported hardware 前插入 zn,m2 分支"
    else
        sed -i '/^esac/i\\nzn,m2)\n\tucidef_set_interfaces_lan_wan "lan1 lan2 lan3" "wan"\n\t;;\n' "$NET"
        echo "    ✓ 已兜底插入 zn,m2 分支"
    fi
fi
echo "    --- 校验 ---"
grep -B1 -A3 'zn,m2' "$NET" || echo "      (未匹配到)"

echo ""
echo "[A4/5] 注入 LED 配置：01_leds"
if [ -f "$LED" ]; then
    if grep -q 'zn,m2' "$LED"; then
        echo "    ✓ 已含 zn,m2，跳过"
    else
        sed -i '/^esac/i\\nzn,m2)\n\tucidef_set_led_netdev "wan" "WAN" "blue:wan" "wan"\n\tucidef_set_led_netdev "lan" "LAN" "blue:lan" "br-lan"\n\tucidef_set_led_netdev "wlan2g" "WLAN2G" "blue:wlan2g" "phy1-ap0"\n\tucidef_set_led_netdev "wlan5g" "WLAN5G" "blue:wlan5g" "phy0-ap0"\n\t;;\n' "$LED"
        echo "    ✓ 已插入 zn,m2 LED 配置"
    fi
    echo "    --- 校验 ---"
    grep -A5 'zn,m2' "$LED" || echo "      (未匹配到)"
else
    echo "    ⚠ $LED 不存在，跳过（非致命）"
fi

echo ""
echo "[A5/5] 移除 source-only（否则不产 factory 镜像）"
if [ -f "$TMK" ]; then
    sed -i 's/^FEATURES += source-only/# FEATURES += source-only   # 已由 ZN-M2 移植移除/' "$TMK"
    echo "    --- 处理后 ---"
    grep -n 'source-only' "$TMK" || echo "      已移除 ✓"
else
    echo "    ⚠ $TMK 不存在"
fi

# ---------------------------------------------------------------------------
# B. NSS 硬件加速使能
# ---------------------------------------------------------------------------
echo ""
echo "=============================================================="
echo "  NSS 硬件加速使能"
echo "=============================================================="

# B1. 追加 NSS feeds
echo "[B1] 追加 NSS feeds (nss-packages + sqm-scripts-nss + istore)"
if [ -f feeds.conf.default ]; then
    grep -q 'nss-packages' feeds.conf.default || \
        echo 'src-git nss_packages https://github.com/qosmio/nss-packages.git;NSS-12.5-K6.x' >> feeds.conf.default
    grep -q 'sqm-scripts-nss' feeds.conf.default || \
        echo 'src-git sqm_nss https://github.com/qosmio/sqm-scripts-nss.git' >> feeds.conf.default
    grep -q 'linkease/istore' feeds.conf.default || \
        echo 'src-git istore https://github.com/linkease/istore.git' >> feeds.conf.default
    # HomeProxy 后端 feed（immortalwrt/homeproxy 同时提供 homeproxy 后端 + luci-app-homeproxy 前端）
    # 24.10 教训：仅选 luci-app-homeproxy 而缺后端 homeproxy feed → 前端因依赖缺失被静默丢弃
    grep -q 'immortalwrt/homeproxy' feeds.conf.default || \
        echo 'src-git homeproxy https://github.com/immortalwrt/homeproxy.git;master' >> feeds.conf.default
    echo "    ✓ feeds 已追加"
else
    echo "    !! feeds.conf.default 不存在"
fi

# B2. 拉取 NSS 内核补丁 + nss.dtsi + 设备 DTS（CI 网络可靠）
NSS_TMP=$(mktemp -d)
QOSMIO_OK=0
QBR=""
for br in 25.12-nss main-nss 24.10-nss; do
    echo "    尝试克隆 qosmio/openwrt-ipq @ $br ..."
    rm -rf "$NSS_TMP/q" 2>/dev/null || true
    if git clone --depth 1 -b "$br" https://github.com/qosmio/openwrt-ipq "$NSS_TMP/q" 2>/dev/null; then
        QOSMIO_OK=1; QBR="$br"; break
    fi
done

if [ $QOSMIO_OK -eq 1 ]; then
    echo "    ✓ qosmio/openwrt-ipq @ $QBR 已克隆"

    # 复制 NSS 内核补丁（按文件名匹配 nss/ecm/skb_recycler/mcs/cfi；排除 reserved-memory 避免与 iStoreOS 已有 0135 重复）
    SP="$NSS_TMP/q/target/linux/qualcommax/patches-6.x"
    [ -d "$SP" ] || SP="$NSS_TMP/q/target/linux/qualcommax/patches-6.12"
    if [ -d "$SP" ]; then
        cnt=0
        for f in "$SP"/*; do
            n=$(basename "$f")
            # 仅复制 NSS 相关，且跳过已存在的同名补丁、跳过 reserved-memory（iStoreOS 已有 0135）
            if echo "$n" | grep -qiE 'nss|ecm|skb_recycler|mcs|cfi'; then
                echo "$n" | grep -qi 'reserved-memory' && continue
                [ -f "$PATCHDIR/$n" ] && { echo "      ~ 跳过已存在: $n"; continue; }
                cp "$f" "$PATCHDIR/" && cnt=$((cnt+1))
            fi
        done
        echo "    ✓ 已复制 $cnt 个 NSS 内核补丁到 $PATCHDIR"
    else
        echo "    ⚠ 未找到 qosmio 的 patches 目录: $SP"
    fi

    # 复制 nss.dtsi
    nd=$(find "$NSS_TMP/q" -name 'ipq6018-nss.dtsi' | head -1)
    if [ -n "$nd" ]; then
        cp "$nd" "$DTS_DIR/" && echo "    ✓ nss.dtsi: $(basename "$nd")"
    else
        echo "    ⚠ 未找到 ipq6018-nss.dtsi"
    fi

    # 复制设备 DTS（优先 cmiot-ax18 的 NSS 版，改编为 zn,m2）
    dev=$(find "$NSS_TMP/q" -name 'qcom-ipq6018-cmiot-ax18.dts' | head -1)
    if [ -n "$dev" ]; then
        sed -e 's/CMIOT-AX18/ZN M2/' -e 's/"cmiot,ax18"/"zn,m2"/' -e 's/"cig,cmiot-ax18"/"zn,m2"/' "$dev" > "$DTS_DIR/ipq6000-m2.dts"
        echo "    ✓ 设备 DTS: 由 cmiot-ax18 改编为 zn,m2（覆盖 fallback）"
    fi
else
    echo "    ⚠ qosmio/openwrt-ipq 克隆失败，转 LibWrt 退路"
fi

# B3. 退路：从 LibWrt 25.12-nss 补充 nss.dtsi / 设备 DTS（若 qosmio 没拿到）
if [ ! -f "$DTS_DIR/ipq6018-nss.dtsi" ] || { [ ! -f "$DTS_DIR/ipq6000-m2.dts" ] && [ -f "$PATCH_SRC/ipq6000-m2.dts" ]; }; then
    echo "    从 LibWrt 25.12-nss 补充 ..."
    LT=$(mktemp -d)
    if git clone --depth 1 -b 25.12-nss https://github.com/LiBwrt/LibWrt "$LT" 2>/dev/null; then
        if [ ! -f "$DTS_DIR/ipq6018-nss.dtsi" ]; then
            nd=$(find "$LT" -name 'ipq6018-nss.dtsi' | head -1)
            [ -n "$nd" ] && cp "$nd" "$DTS_DIR/" && echo "    ✓ LibWrt nss.dtsi"
        fi
        if [ ! -f "$DTS_DIR/ipq6000-m2.dts" ]; then
            dd=$(find "$LT" -name 'ipq6000-m2.dts' | head -1)
            [ -n "$dd" ] && cp "$dd" "$DTS_DIR/" && echo "    ✓ LibWrt zn_m2 DTS"
        fi
    else
        echo "    ⚠ LibWrt 克隆也失败"
    fi
fi

# B4. 致命检查：nss.dtsi 缺失则 DTS 编译必败
if [ ! -f "$DTS_DIR/ipq6018-nss.dtsi" ]; then
    echo "    !!! 致命：ipq6018-nss.dtsi 未能获取，DTS 编译将失败"
fi

# B5. NSS 自检
echo ""
echo "[B5] NSS 注入自检"
echo "    nss.dtsi       : $([ -f "$DTS_DIR/ipq6018-nss.dtsi" ] && echo '✓' || echo '✗ 缺失')"
echo "    ipq6000-m2.dts : $([ -f "$DTS_DIR/ipq6000-m2.dts" ] && echo '✓' || echo '✗ 缺失')"
echo "    NSS 补丁数     : $(ls "$PATCHDIR" 2>/dev/null | grep -ciE 'nss|ecm|skb_recycler|mcs|cfi')"
echo "    设备定义       : $(grep -q 'define Device/zn_m2' "$MK" && echo '✓' || echo '✗')"
echo "    02_network     : $(grep -q 'zn,m2' "$NET" && echo '✓' || echo '✗')"

echo ""
echo "=============================================================="
echo "  ZN-M2 + NSS 移植注入完成"
echo "=============================================================="
