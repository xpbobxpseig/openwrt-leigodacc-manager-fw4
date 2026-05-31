# Session Log — LeigodAcc Manager fw4 适配版

> **原始仓库**: [miaoermua/openwrt-leigodacc-manager](https://github.com/miaoermua/openwrt-leigodacc-manager)
> **目标**: 将雷神加速器插件适配到 OpenWrt 24.10+ fw4/nftables 防火墙
> **产出目录**: `C:\Users\Administrator\leigod-fw4\`

## 版本时间线

| 版本 | 日期 | 关键变更 |
|------|------|----------|
| v2.0.0 | 05-18 | fw4 适配基础 |
| v2.1.0 | 05-19 | 自动暂停功能 |
| v2.1.1 | 05-20 | 29 项代码审计修复 |
| v2.2.0 | 05-20 | LuCI 补丁 + 诊断页 |
| v2.2.1 | 05-21 | fw4 防火墙误判修复 |
| v2.3.0 | 05-27 | fix_acc_core_conf + 延迟诊断 |
| v2.3.2 | 05-30 | 诊断增强 + 自动暂停重构 + LuCI 全中文化 |
| **v2.4.0** | **05-31** | **单文件部署 + 全部内嵌 + 最终方案** |

---

## v2.3.0-v2.4.0 核心发现

### 1. acc-gw 二进制行为完整分析 (v1.2.2.13 router.arm64)

**acc_mode 实测矩阵**：
| acc_mode | 结果 | 说明 |
|----------|------|------|
| 0 | exit 255 崩溃 | 二进制不识别 |
| 1 | exit 0 崩溃 | TUN 不支持 |
| **2** | **稳定** ✅ | TPROXY，唯一值 |

**关键发现**：
- 二进制硬编码默认 `tproxy_ip: "10.20.30.40"`，每次 daemon 启动重新生成 JSON 覆盖手动修复
- `"unknow acc mode:2"` 是**非致命警告**，仅在规则清理时打印，不影响功能
- 此二进制**仅支持 TPROXY**，不支持 TUN 模式
- GAMEACC 规则由手机 APP 发起加速后**动态注入**（不是预创建的）
- daemon 不写 UCI state，设备加速状态在 `acc_core_conf.json` 中
- `user.token` 是加速会话 token，**不适用于 pause API**（返回 400006）

### 2. CloudWAF 登录封锁（不可逾越）

雷神登录 API `/wap/login/bind/v1` 从**所有网络来源**返回 418：
- ❌ 家庭宽带
- ❌ Cloudflare Worker 边缘节点
- ❌ GitHub Actions 数据中心 IP
- ❌ 本地开发机

Pause API `/api/user/pause` **无此限制**，有有效 token 即可。

**尝试过的自动化方案**（全部失败）：
| 方案 | 失败原因 |
|------|----------|
| curl 直接调用 | 418 CloudWAF |
| Cloudflare Worker 代理 | 418（即使是 CF 边缘 IP） |
| GitHub Actions | 418（即使是数据中心 IP） |
| Playwright + Edge | 极验验证码 + 浏览器自动化检测 |
| daemon token 复用 | 返回 400006（会话 token vs 账号 token） |
| 用户名密码自动登录 | 登录 API 被封锁 |

### 3. BusyBox 兼容性陷阱

| 问题 | 表现 | 修复 |
|------|------|------|
| `ps` 截断命令行 | mode 显示 `tp` 而非 `tproxy` | `ps ww` |
| `ps` 无 RSS 列 | 内存显示 `S KB` (STAT 列) | 用 VSZ ($3) |
| `ss` 不存在 | 端口检测永远 No | netstat fallback |
| `grep -oP` 不支持 | Perl regex 报错 | 基础 grep |
| 中文 `.-` 正则 | 跨嵌套 JSON 不匹配 | `find() + sub()` |

### 4. Lua 注入检测模式失败根因

设备状态从 JSON 读取时，初始正则 `"(Phone|PC)":[^{]-"state":(%d+)` 中的 `[^{]` 被嵌套 JSON 内部的 `{` 截断。改用两段式：
```lua
local pos = raw:find('"PC":')
local st = raw:sub(pos):match('"state":(%d+)')
```

---

## v2.4.0 最终架构

### 文件自包含（单文件部署）

`leigod-fw4.sh` 内嵌了所有组件：

| 内嵌组件 | 数量 | 部署方式 |
|----------|------|----------|
| LuCI 文件 | 12 个 | `apply_luci_fw4_patch()` 内联 heredoc |
| auto-pause.sh v2.5 | 1 个 | `auto_pause_install()` 内联 heredoc |
| hotplug 脚本 | 1 个 | 内联 |

**不再需要 `luci-fw4-patch/` 目录或 `auto-pause.sh` 独立文件。**

### Token 最终方案：浏览器书签

| 环节 | 方式 | 频率 |
|------|------|------|
| 获取 token | 书签一键推送 (bookmarklet) | 每 7 天 5 秒 |
| 空闲检测 | cron + GAMEACC + UCI | 全自动 |
| 暂停 API | curl POST | 全自动 |

**架构**：用户登录 leigod.com → 点书签 → token 自动 POST 到路由器 `save_token` 端点 → 写入配置文件 → cron 自动使用。

### LuCI 页面清单

| 页面 | 中文标签 | 类型 |
|------|----------|------|
| 服务配置 | 服务配置 | CBI Form |
| 设备管理 | 设备管理 | CBI + DHCP/ARP |
| APP下载 | APP下载 | 静态页 |
| 使用须知 | 使用须知 | 静态页 |
| 自动暂停 | 自动暂停 | CBI + JS 轮询 |
| 网络诊断 | 网络诊断 | JS 轮询 |

### 诊断页功能

- 系统/进程/Init/配置/网络/GAMEACC/依赖包/设备/自动暂停 — 12 项
- 延迟诊断：网关/DNS/TURN 三项 ping 对齐表
- 加速节点列表（从 acc_core_conf.json 提取）
- 自动分析（网关 >10ms → 本地；TURN-网关 >50ms → 服务器端）
- 书签一键获取 Token
- 自定义空闲检测间隔（1-30 分钟）

---

## 关键文件索引

| 文件 | 用途 | 行数 |
|------|------|------|
| `leigod-fw4.sh` | **单文件部署** (全部内嵌) | ~5030 |
| `auto-pause.sh` | 自动暂停独立脚本 (cron) | 176 |
| `CHANGELOG.md` | 完整变更日志 | ~690 |
| `UPDATE.md` | 安装与使用指南 | ~220 |
| `SESSION-LOG.md` | 本文件 | — |
| `luci-fw4-patch/luasrc/controller/acc.lua` | LuCI 控制器 | 1213 |
| `luci-fw4-patch/luasrc/view/leigod/debug.htm` | 诊断页模板 | 184 |
| `luci-fw4-patch/luasrc/view/leigod/autopause.htm` | 自动暂停模板 (书签UI) | 151 |
| `luci-fw4-patch/luasrc/model/cbi/leigod/autopause.lua` | 自动暂停配置 | 155 |
| `luci-fw4-patch/luasrc/model/cbi/leigod/debug.lua` | 诊断页 CBI wrapper | 7 |

## 已知限制与风险

| 限制 | 影响 | 缓解 |
|------|------|------|
| token 有效期 ~7 天 | 自动暂停到期失效 | 书签 5 秒手动刷新 |
| 此 acc-gw 仅支持 TPROXY | 不能切 TUN | fix_acc_core_conf 强制 mode=2 |
| daemon 不写 UCI state | 设备状态需从 JSON 读 | 已实现 JSON 解析 |
| 登录 API 完全封锁 | 无法自动化 token 刷新 | 浏览器书签 |
| `fix_acc_core_conf` 强制 mode=2 | 未来二进制支持 TUN 会误杀 | 需更新逻辑 |

## 部署速查

```powershell
scp C:\Users\Administrator\leigod-fw4\leigod-fw4.sh root@192.168.10.1:/root/
```

```bash
chmod +x /root/leigod-fw4.sh
echo "3" | /root/leigod-fw4.sh    # 重装（自动部署全部 LuCI）
# 菜单 9 → 1 → 回车 → 回车（自动部署自动暂停）
/etc/init.d/acc enable
rm -rf /tmp/luci-*
```
