# 兆能 M2 (ZN M2) —— iStoreOS 25.12 原生 + NSS 硬件加速 云编译工程

## 目标
- **iStoreOS 25.12 原生**（内核 6.12，保留原生界面 + iStore 商店）
- **NSS 硬件加速**（IPQ6000 网络卸载：NAT / PPPoE / 流量卸载，CPU 占用降至个位数）
- **无 WiFi**（用户不需要，省体积）
- 默认地址 `192.168.12.1`，root / password，网口 `wan + lan1 lan2 lan3`

## 与 LibWrt 备份的关系
- 本工程是**主线**（iStoreOS 原生 + NSS）。
- `no-duke/zn-m2-libwrt-nss`（LibWrt 25.12-nss，run `35944637064`）作为**对照/备用**，验证 NSS 本身可用。

## 移植原理（为什么能成）
iStoreOS 25.12 与 LibWrt 25.12-nss 共享 OpenWrt 25.12 的 `qualcommax` 基础：
- 两者 102/103 个 `patches-6.12` 完全相同 → 内核基础一致。
- iStoreOS 已自带 `0135-ipq6018-add-NSS-reserved-memory`（NSS reserved-memory 地基已在）。
- 缺失的只是 **23 个 NSS 内核补丁** + `ipq6018-nss.dtsi` + zn_m2 设备定义，由 `diy-part1.sh` 步骤 B 从 `qosmio/openwrt-ipq`（权威 NSS 源，LibWrt 亦源于此）拉取注入。

## 文件结构
```
.github/workflows/build.yml   编译工作流（克隆 iStoreOS 25.12 → 注入 → 编译 → 发布）
scripts/diy-part1.sh          步骤 A：zn_m2 设备/网口/LED 注入；步骤 B：NSS 使能（feeds+补丁+dtsi+DTS）
scripts/diy-part2.sh          默认 IP / 首次启动 uci-defaults
configs/zn-m2.config          包选择（NSS 全开 + iStore + 无 WiFi + Docker 默认不装 + 温度/代理前端补齐）
patch/ipq6000-m2.dts          fallback 设备树（上游拉取失败时使用）
```

## 关键风险点
1. **NSS 补丁/DTS 拉取依赖 CI 网络**：步骤 B 克隆 `qosmio/openwrt-ipq`（退路 `LiBwrt/LibWrt`）。CI 网络可靠；若失败，构建日志会明确报 `ipq6018-nss.dtsi 缺失`。
2. **reserved-memory 不重复**：iStoreOS 已有 `0135`，步骤 B 复制补丁时显式跳过 `reserved-memory`，避免重复打补丁。
3. **设备 DTS 来源**：优先用上游 `qcom-ipq6018-cmiot-ax18.dts` 改编为 `zn,m2`；该 DTS 自带 board 节点（mdio/switch/dp/edma），仅需 `ipq6018-nss.dtsi` 在场即可编译。
4. **代理前端依赖（24.10 教训）**：`luci-app-homeproxy` 仅是前端，真正的 `homeproxy` 后端由 `diy-part1.sh` 步骤 B 注入的 `immortalwrt/homeproxy` feed 提供。若只选前端、缺后端 feed，defconfig 会因依赖缺失**静默丢弃**前端——故 config 中显式 `CONFIG_PACKAGE_homeproxy=y`，CI 校验也会 grep 该后端。
5. **温度前端**：CPU 实时温度由 `luci-app-cpufreq` 主页显示；历史趋势图由 `luci-app-statistics` + `collectd-mod-thermal`（rrdtool 约 +1~1.5MB）提供。若需极致精简可注释掉统计段。
6. **NSS 客户端补丁与 6.12.94 的上下文漂移**：qosmio 的 `25.12-nss` 与 iStoreOS 25.12 同为 `KERNEL_PATCHVER:=6.12`，但内核小版本不同。实测 `0603-5-qca-nss-clients-add-vxlan-support.patch` 在 `linux-6.12.94` 的 `vxlan_core.c` 上 Hunk #5 上下文漂移、打补丁失败（首个失败点即中断整套补丁应用）。步骤 B 因此**排除**与所选 kmod 无关的客户端补丁：`vxlan`(0603-5)、`tls-mgr`(0603-8)、`ipsec`(0607-2)——本机 config 未选 `kmod-qca-nss-drv-vxlanmgr/tlsmgr/ipsecmgr`，删除无副作用。若日后需要 VXLAN/TLS/IPsec 卸载，需将对应补丁 `git apply` 刷新到 6.12.94 后再加入。
7. **skb_recycler 必需补丁已刷新**：`0981-1-qca-skb_recycler-support.patch` 同为 6.12.94 漂移补丁（Hunk #29 在 `net/core/skbuff.c:7070` 失败），但它**不可排除**——`kmod-qca-nss-drv` 依赖它。因此本仓库自带刷新版 `patch/patches-6.12/0981-1-qca-skb_recycler-support.patch`（基于 linux-6.12.94 真身 `git diff` 生成，已通过 `git apply --check` 严格校验），步骤 B2.4 用它**覆盖** qosmio 原始拷贝。切勿恢复为 qosmio 原始版。

## 使用
在 GitHub Actions 手动触发 `Build-ZN-M2-iStoreOS-NSS`（workflow_dispatch）。
产物发布到 Releases：`ZN-M2-iStoreOS-25.12-NSS`。
刷机：暗云 U-Boot 网页 → 只点「固件」→ 用 `*nand-factory.ubi` 或 `*squashfs-factory.ubi`。
