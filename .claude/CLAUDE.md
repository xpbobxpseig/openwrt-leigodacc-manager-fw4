# Leigod FW4 — OpenWrt 雷神加速器管理器

OpenWrt 24.10+ fw4/nftables 适配的 LeigodAcc 管理脚本。基于 [miaoermua/openwrt-leigodacc-manager](https://github.com/miaoermua/openwrt-leigodacc-manager) 改造。

## 项目文件索引

| 文件 | 用途 |
|------|------|
| `leigod-fw4.sh` | 主管理脚本（~158KB），安装/卸载/配置/诊断 |
| `auto-pause.sh` | 自动暂停辅助脚本（token 过期检测） |
| `luci-fw4-patch/` | LuCI 界面补丁（controller/model/view） |
| `leigod-fw4-install-guide.md` | 安装指南 |
| `leigod-accelerator-tech-reference.md` | 技术参考文档 |
| `CHANGELOG.md` / `UPDATE.md` | 变更日志与更新说明 |

## 脚本架构

- **Shell (POSIX sh)**，目标平台 OpenWrt 24.10+
- 防火墙检测: `detect_firewall()` → fw3(iptables) vs fw4(nftables)
- 关键函数: `install_leigodacc()`, `uninstall_leigodacc()`, `ensure_fw4_tproxy()`, `setup_fw4_integration()`, `switch_mode()`, `fix_acc_core_conf()`
- UCI 配置: `ensure_uci_config()` 管理 `/etc/config/leigod`
- LuCI 补丁: `apply_luci_fw4_patch()` → `luci-fw4-patch/luasrc/`

## 编码约定

- Shell 脚本，用 `#!/bin/sh`（不用 bashism）
- 函数用小写下划线命名: `check_network()`, `safe_opkg_install()`
- 条件检查: `[ ]` 而非 `[[ ]]`（POSIX 兼容）
- 错误处理: `|| { echo "[ERROR] ..."; exit 1; }` 模式
- 日志标签: `[INFO]`, `[ERROR]`, `[WARN]`, `[OK]`

## 已知问题

- 假 tproxy_ip `10.20.30.40` 导致高延迟 → 见 memory: [[acc-gw-tproxy-debug]]
- ImmortalWrt 24.10 上 auto-pause token 过期问题
