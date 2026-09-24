#!/bin/bash
# ============================================================================
# diy-part2.sh —— 【定制】在 feeds install 之后、make 之前执行
# 工作目录：openwrt/
#
# 干三件事：
#   1. 默认 IP 改为 192.168.12.1（对齐现有网段）
#   2. 预置首次启动配置（ZeroTier / nlbwmon / cpufreq / NSS 卸载 / 代理）
#   3. 精简与体检（打印体积相关项，便于判断 overlay 空间）
# ============================================================================
set -e

echo "=============================================================="
echo "  ZN-M2 定制开始"
echo "=============================================================="

# ----------------------------------------------------------------------------
# 1. 默认 IP → 192.168.12.1
# ----------------------------------------------------------------------------
echo ""
echo "[1/4] 设置默认 LAN IP = 192.168.12.1"

CG=""
for c in package/base-files/files/bin/config_generate \
         package/base-files/files/lib/functions/uci-defaults.sh; do
    [ -f "$c" ] && CG="$c" && break
done

if [ -n "$CG" ]; then
    echo "    目标文件: $CG"
    sed -i 's/192\.168\.1\.1/192.168.12.1/g' "$CG"
    sed -i 's/192\.168\.100\.1/192.168.12.1/g' "$CG"
    grep -n '192\.168\.12\.1' "$CG" | head -5 || echo "    ⚠ 未匹配，将由 uci-defaults 兜底"
else
    echo "    ⚠ 未找到 config_generate，由 uci-defaults 兜底"
fi

# ----------------------------------------------------------------------------
# 2. 预置首次启动配置
# ----------------------------------------------------------------------------
echo ""
echo "[2/4] 预置首次启动配置"
mkdir -p files/etc/uci-defaults

cat > files/etc/uci-defaults/99-zn-m2-init <<'UCIEOF'
#!/bin/sh
# ============================================================
# 兆能 M2 首次启动初始化
# ============================================================

# --- LAN IP ---
uci -q set network.lan.ipaddr='192.168.12.1'
uci -q set network.lan.netmask='255.255.255.0'
uci -q commit network

# --- 主机名 / 时区 / 主题 ---
uci -q set system.@system[0].hostname='ZN-M2'
uci -q set system.@system[0].timezone='CST-8'
uci -q set system.@system[0].zonename='Asia/Shanghai'
uci -q commit system

# --- NSS 硬件加速（IPQ6000 的命根子）---
uci -q set firewall.@defaults[0].flow_offloading='1'
uci -q set firewall.@defaults[0].flow_offloading_hw='1'
uci -q commit firewall

# --- CPU 调频 ---
if [ -f /etc/config/cpufreq ]; then
    uci -q set cpufreq.settings.governor0='ondemand'
    uci -q set cpufreq.settings.minfreq0='864000'
    uci -q set cpufreq.settings.maxfreq0='1608000'
    uci -q commit cpufreq
fi

# --- ZeroTier（迁移原固件的网络 ID；留空由用户自行 join）---
# uci -q set zerotier.sample_config.enabled='1'
# uci -q set zerotier.sample_config.nat='1'
# uci -q set zerotier.sample_config.join='12ac4a1e718b634a' '166359304e4665e2'
# uci -q commit zerotier

# --- nlbwmon（流量监控）---
if [ -f /etc/config/nlbwmon ]; then
    uci -q set nlbwmon.@nlbwmon[0].refresh_interval='30s'
    uci -q set nlbwmon.@nlbwmon[0].commit_interval='4h'
    uci -q commit nlbwmon
fi

exit 0
UCIEOF
chmod +x files/etc/uci-defaults/99-zn-m2-init
echo "    ✓ uci-defaults/99-zn-m2-init 已写入"

# 关闭 extroot 误触发：不带 USB 盘时不自动挂 overlay
mkdir -p files/etc/config
cat > files/etc/config/fstab <<'FSTABEOF'
config global
	option anon_swap '0'
	option anon_mount '0'
	option auto_swap '0'
	option auto_mount '1'
	option delay_root '5'
	option check_fs '0'

config mount
	option target '/overlay'
	option uuid ''
	option enabled '0'
FSTABEOF
echo "    ✓ fstab 已写入（extroot 预留但默认关闭）"

# ----------------------------------------------------------------------------
# 3. 精简：打印可能体积较大的包，便于人工判断
# ----------------------------------------------------------------------------
echo ""
echo "[3/4] 体积体检（这些包偏大，确认是否真要）"
for p in luci-app-dockerman dockerd docker luci-app-nfs-kernel-server \
         transmission-daemon aria2 qbittorrent adguardhome luci-app-adguardhome \
         luci-app-ssr-plus luci-app-passwall luci-app-openclash openclash \
         python3 node coreutils-full ffmpeg; do
    if grep -q "CONFIG_PACKAGE_${p}=y" .config 2>/dev/null; then
        echo "    [!] $p 被选中"
    fi
done
echo "    (以上为提示，控制权在 configs/zn-m2.config)"

# ----------------------------------------------------------------------------
# 4. 关键项自检
# ----------------------------------------------------------------------------
echo ""
echo "[4/4] 定制自检"
echo "    默认IP文件  : $CG"
echo "    uci-defaults: $(ls files/etc/uci-defaults/ 2>/dev/null | tr '\n' ' ')"
echo "    fstab       : $([ -f files/etc/config/fstab ] && echo '✓' || echo '✗')"
echo "    files 树    :"
find files -type f 2>/dev/null | sed 's/^/      /'

echo ""
echo "=============================================================="
echo "  ZN-M2 定制完成"
echo "=============================================================="
