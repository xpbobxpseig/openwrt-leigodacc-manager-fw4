# DEVLOG — leigod-fw4

## 2026-06-27 — Daemon 自愈 + stop_acc 崩溃循环修复

### 发现
acc-gw 闭源二进制存在内部 bug：每 ~50 秒 unix socket 客户端断开触发 `on_error` → `clear the resource` → `stop_acc`，导致游戏加速被反复停止。

### 修复
`fix_acc_core_conf()` 新增自愈钩子：
- 检测 daemon 最近 20 行日志中 `stop_acc` 次数
- ≥2 次 → 强重启 daemon (stop + kill -9 + start + fix JSON)
- 不触发则静默跳过（正常运行时不干扰）

**涉及文件**: `leigod-fw4.sh`

### 此前已修复 (2026-06-24)

| Bug | 修复方式 |
|-----|---------|
| 离家模式 LuCI checkbox 不生效 | `_ap_manual` 虚拟字段无法触发 CBI `on_commit` → 改为 AJAX 事件委托 (`document.addEventListener('change', ...)`) 直写配置 |
| 离家模式状态表不更新 | `save_autopause_config()` 改为局部更新模式，从已有配置保留未传参数字段 |
| fix-tproxy 重启风暴 | `fix_acc_core_conf()` 不再重启运行中的 daemon，仅修复 JSON |
| fix-tproxy cron 路径缺失 | `install_tproxy_watcher()` 注册 cron 前自部署脚本到 `/usr/sbin/leigod/` |
| 脚本永不更新 | `auto_pause_install()` 始终用内嵌 heredoc 覆写部署 |
| Token 解析失败 | `key, val = line:match("ACCOUNT_TOKEN='(.*)'")` 1捕获→2变量 → 改为单变量 `token_val` |
| CBI Flag formvalue 误取 hidden 值 | `read_cbi_flag()` 改为 `find_flag()` 后缀扫描 `luci.http.formvalues()` |
| conntrack 缺失 | 安装 `conntrack` + `conntrackd` |
| 网络不稳定 | BBR + fq_codel + conntrack_max=65536 |

### 已知未解决

- acc-gw 二进制自身的 ~50s 崩溃循环（自愈钩子缓解但需等最多 5 分钟）
- LuCI CBI `on_commit` 在纯虚拟字段时永不执行（LuCI 框架级限制）
