# 雷神加速器 OpenWrt 路由器插件 — 技术参考文档

> **整理日期**: 2026-05-26
> **源码仓库**: [miaoermua/openwrt-leigodacc-manager](https://github.com/miaoermua/openwrt-leigodacc-manager)
> **当前适配版本**: v2.3.3 (2026-05-31)
> **实测固件**: ImmortalWrt 24.10 / 路由器: Xiaomi Redmi Router AX6000

---

## 1. 项目概述

### 1.1 产品形态

雷神加速器 OpenWrt 插件由两部分组成:

| 层级 | 说明 |
|------|------|
| **雷神二进制 (acc-gw)** | 闭源，由雷神官方 CDN (`119.3.40.126`) 下发。负责实际的游戏流量劫持和加速转发。 |
| **第三方管理器 (leigod-fw4.sh)** | 开源 Shell 管理器，基于 [miaoermua/leigodacc-manager](https://github.com/miaoermua/openwrt-leigodacc-manager) 适配 fw4/nftables。提供安装/卸载/切换模式/诊断/LuCI 界面。 |

### 1.2 版本历史

| 版本 | 日期 | 关键变更 |
|------|------|----------|
| v2.0.0 | 2026-05-18 | 初始 fw4/nftables 适配 |
| v2.1.0 | 2026-05-19 | 新增 auto-pause.sh 自动暂停时长计费 |
| v2.1.1 | 2026-05-20 | 安全加固 (命令注入修复) + 29项 Bug 修复 |
| v2.2.1 | 2026-05-21 | fw4 误判修复 + init 脚本 `--mode tun` 长格式 bug + 诊断页面 |
| v2.3.0 | 2026-05-27 | 延迟诊断 + SQM 安装 + tproxy_ip/acc_mode 三层守护 + 诊断页重写 |
| v2.3.1 | 2026-05-30 | 自动暂停四层 token 策略 + 二进制逆向分析 + 10+ Bug 修复 |
| v2.3.2 | 2026-05-30 | 自动暂停精简为书签方案 + LuCI 全中文化 + 一键获取 Token |
| v2.3.3 | 2026-05-31 | auto_pause_install 语法修复 + 延迟诊断 6 步重写 + 内核网络调优 + CLI diagnose/tune-network |

---

## 2. 文件结构

```
leigod-fw4/
├── leigod-fw4.sh              (2890行) 核心 Shell 管理器
├── auto-pause.sh              (177行)  自动暂停时长计费 (cron 调用)
├── leigod-fw4-install-guide.md         用户安装指南
├── CHANGELOG.md                        完整变更日志
├── SESSION-LOG.md                      开发会话记录
└── luci-fw4-patch/                     LuCI Web 界面 fw4 适配补丁
    └── luasrc/
        ├── controller/
        │   └── acc.lua       (685行)  控制器——路由注册 + 所有 API 端点
        ├── model/cbi/leigod/
        │   ├── service.lua   (66行)   服务配置页 (防火墙显示/TUN开关)
        │   ├── device.lua    (157行)  设备管理页 (ARP/DHCP 扫描+分类)
        │   ├── app.lua       (7行)    APP 下载页
        │   ├── notice.lua    (19行)   公告页
        │   └── autopause.lua (123行)  自动暂停配置页
        └── view/leigod/
            ├── service.htm   (30行)   服务状态 JS 轮询模板
            ├── autopause.htm (85行)   自动暂停状态 JS 轮询 (10s)
            ├── debug.htm     (205行)  诊断页面 (15+项检查)
            ├── app.htm                APP 下载模板
            └── notice.htm             公告模板
```

---

## 3. 核心架构

### 3.1 加速模式: TPROXY (L4 透明代理)

雷神 acc-gw 二进制使用 **TPROXY** 而非 TUN:

```
游戏设备 (PC/手机/主机)
    │
    ▼
路由器 nftables/iptables mangle 表 PREROUTING
    │  └─ GAMEACC 链 (动态创建)
    │     ├─ RETURN: 本地/广播/局域网流量 (不走代理)
    │     └─ TPROXY redirect: 匹配的游戏设备流量
    │         └─ 重定向到 acc-gw 进程端口
    ▼
acc-gw 进程 (用户态)
    │  └─ 读取透明代理 Socket
    │  └─ 通过雷神 TURN 中继服务器转发
    ▼
雷神 TURN 中继服务器 (route-turn.xxghh.biz:5588)
    │  └─ 专线/优化路由
    ▼
游戏服务器
```

### 3.2 进程模型

acc-gw 采用 **多进程架构**:

```
/etc/init.d/acc (procd 管理)
    │
    ├─ acc-gw.router.<arch> -r daemon -m tproxy -p 5588 -l <LAN_IP>
    │   └─ 守护进程，管理子进程生命周期
    │   └─ 读写 /tmp/acc/acc_core_conf.json (核心配置源)
    │   └─ 通过 Unix Socket 与 web 进程通信
    │
    ├─ acc-gw.router.<arch> -r web -m tproxy -p 5588 -l <LAN_IP>
    │   └─ Web/API 进程，监听 TCP 5588
    │   └─ 处理手机 APP 的加速指令
    │   └─ 由 daemon fork，参数从 acc_core_conf.json 读取
    │
    ├─ acc-gw.router.<arch> -r acc -t <Type> -m tproxy (按需 fork)
    │   └─ 加速子进程，每种设备类型一个
    │   └─ 例: -t PC, -t Phone, -t Game
    │   └─ 每个子进程管理自己设备的 TPROXY 规则
    │
    └─ acc_upgrade_monitor -r upgrade
        └─ 升级检查进程
```

**关键发现 (v2.2.1)**: daemon 从 `/tmp/acc/acc_core_conf.json` 读取配置来 fork web 子进程，**不是从 init 脚本 args 读取**。init 脚本的 `-l` 参数仅在首次运行时用于初始化 JSON。

### 3.3 acc_core_conf.json 格式

```json
{"acc_mode":2, "acceleration":[], "owner_type":1, "tproxy_ip":"192.168.10.1"}
```

| 字段 | 含义 | 值 |
|------|------|-----|
| `acc_mode` | 加速模式 | `1` = TUN (v1.2.2.13 不支持), `2` = TPROXY |
| `acceleration` | 当前加速设备列表 | 运行时动态填充 |
| `owner_type` | 所有者类型 | `1` = OpenWrt 路由器 |
| `tproxy_ip` | TPROXY 绑定的 IP | **必须是路由器 LAN IP**，错误值会导致 web 子进程崩溃 |

---

## 4. 安装流程

### 4.1 安装依赖链

#### fw3 (iptables) 依赖
```
iptables
kmod-ipt-nat
kmod-ipt-tproxy
iptables-mod-tproxy
kmod-ipt-ipset
ipset
```

#### fw4 (nftables) 依赖
```
iptables-nft          ← 替代 iptables，提供翻译层
kmod-nft-nat          ← 替代 kmod-ipt-nat
kmod-nft-tproxy       ← 可能已编译进内核 (CONFIG_NFT_TPROXY=y)
(ipset 内置)          ← nftables 原生 set 支持
(TPROXY 用户态内置)   ← nftables 原生
```

#### 通用依赖 (两种防火墙都需要)
```
libpcap tc-full conntrack kmod-tun luci-compat
```

### 4.2 防火墙检测 (detect_firewall)

```bash
detect_firewall() {
    if [ -x /usr/sbin/fw4 ] || [ -x /usr/sbin/nft ]; then
        FW_TYPE="fw4"
    else
        FW_TYPE="fw3"
    fi
}
```

**v2.2.1 修复**: ImmortalWrt 24.10 使用 nftables 但未安装 `firewall4` 包，导致仅检查 `/usr/sbin/fw4` 会误判为 fw3。增加 `[ -x /usr/sbin/nft ]` 作为备选条件。

### 4.3 安装方式

| 方式 | 菜单选项 | 说明 |
|------|----------|------|
| 官方安装 | 1 | 执行雷神官方 `plugin_install.sh`，下载闭源二进制 |
| Lean IPKG 版 | 8 | 从 GitHub Releases 安装 `luci-app-leigod-acc` IPK 包 |

### 4.4 官方安装后自动修复 (关键)

安装后管理器自动执行:
1. **格式修正**: `--mode tun` → `-m tun` (短格式，二进制才能识别)
2. **iptables-nft 兼容**: 创建 `iptables → iptables-nft` 软链接
3. **fw4 hotplug**: 安装 `99-leigodacc-restart` 脚本 (fw4 reload 时自动恢复规则)
4. **LuCI 恢复**: 重新应用 fw4 补丁 (官方安装脚本的 uninstall 步骤会删除 LuCI 文件)
5. **acc_core_conf.json 修复**: v2.2.1+ 自动检测并修复错误的 `tproxy_ip`

---

## 5. fw4/nftables 适配方案

### 5.1 兼容层架构

```
acc-gw 二进制
    │
    ▼
iptables 命令调用
    │
    ▼
/usr/sbin/iptables → iptables-nft (symlink)
    │
    ▼
nftables 内核 API (翻译层)
    │
    ▼
Linux Netfilter 框架
```

### 5.2 包映射表

| 功能 | fw3 (iptables) | fw4 (nftables) |
|------|---------------|----------------|
| iptables 命令 | `iptables` | `iptables-nft` |
| NAT 内核模块 | `kmod-ipt-nat` | `kmod-nft-nat` |
| TPROXY 内核 | `kmod-ipt-tproxy` | `kmod-nft-tproxy` (4级 fallback) |
| TPROXY 用户态 | `iptables-mod-tproxy` | nftables 内置 |
| IP 集合 | `kmod-ipt-ipset` + `ipset` | nftables 内置 (nft sets) |

### 5.3 TPROXY 4 级 Fallback 检测 (ensure_fw4_tproxy)

```
1. lsmod | grep nft_tproxy          → 已加载? 返回成功
2. modprobe nft_tproxy              → 尝试手动加载
3. opkg install kmod-nft-tproxy     → 尝试安装 kmod
4. zcat /proc/config.gz | grep CONFIG_NFT_TPROXY=y → 已编译进内核?
```

### 5.4 Hotplug 脚本

**路径**: `/etc/hotplug.d/firewall/99-leigodacc-restart`

**作用**: fw4 执行 `fw4 reload` 时会清空所有运行时注入的 iptables-nft 规则（包括 GAMEACC 链和 TPROXY 重定向规则）。此脚本在防火墙重载后自动重启 acc 服务，恢复被清空的规则。

**防抖机制**: 30 秒内重复 fw4 reload 不会触发多次 restart。

### 5.5 防火墙规则 (TCP 5588)

手机 APP 通过 TCP 5588 与路由器上的 acc-gw web 进程通信。fw4 默认规则会丢弃 LAN 到非标准端口的入站流量。

**自动配置** (`check_service_status`):
```bash
uci add firewall rule
uci set firewall.@rule[-1].name='LeigodAcc'
uci set firewall.@rule[-1].src='lan'
uci set firewall.@rule[-1].dest_port='5588'
uci set firewall.@rule[-1].proto='tcp'
uci set firewall.@rule[-1].target='ACCEPT'
```

---

## 6. GAMEACC 链 — 加速规则详解

### 6.1 规则结构

```
mangle PREROUTING
  └─ GAMEACC (自定义链)
       │
       ├─ RETURN  255.255.255.255       (广播)
       ├─ RETURN  223.255.255.255       (特殊广播)
       ├─ RETURN  224.0.0.0/24          (组播)
       ├─ RETURN  127.0.0.1             (本地回环)
       ├─ RETURN  tcp → 10.0.0.0/8      (TCP 内网)
       ├─ RETURN  tcp → 192.168.0.0/16  (TCP 内网)
       ├─ RETURN  udp !53 → 10.0.0.0/8  (UDP 内网非DNS)
       ├─ RETURN  udp !53 → 192.168.0.0/16 (UDP 内网非DNS)
       │
       ├─ RETURN  match-set target_PC src match-set direct_PC dst  (白名单直连)
       ├─ TPROXY  udp dport 53 → 192.168.10.1:XXXXX  (DNS 劫持)
       ├─ TPROXY  tcp → 192.168.10.1:XXXXX            (TCP 加速)
       └─ TPROXY  udp → 192.168.10.1:XXXXX            (UDP 加速)
```

### 6.2 nftables 规则注入

规则最终是通过 iptables-nft 翻译层注入 nftables:

```bash
# iptables-nft 命令
iptables -t mangle -N GAMEACC
iptables -t mangle -A PREROUTING -j GAMEACC
iptables -t mangle -A GAMEACC -m set --match-set target_PC src \
    -p tcp -j TPROXY --on-port 40723 --on-ip 192.168.10.1 --tproxy-mark 0x99/0x99
```

翻译后在 nftables 中体现为:
```
chain GAMEACC {
    ip saddr @target_PC ip daddr @direct_PC counter return
    ip saddr @target_PC tcp dport != 53 counter tproxy to 192.168.10.1:40723 meta mark set 0x99
}
```

---

## 7. 已知严重 Bug 及其修复

### 7.1 `--mode tun` 长格式被忽略 (v2.2.1)

**严重程度**: 致命 — 导致加速完全无效

**原因**: 雷神官方安装脚本写入 `args="--mode tun ..."` (GNU 长格式)，但 acc-gw 二进制仅识别短格式 `-m tun`/`-m tproxy`。`--mode tun` 被静默忽略后二进制回退默认 TPROXY 模式。

**在 fw4/nftables 下**: TPROXY 规则无法被 nftables 正确处理 → **加速完全无效**。

**修复**:
```bash
# 官方/Lean 安装后自动标准化
sed -i 's|--mode tun|-m tun|g' /etc/init.d/acc
sed -i 's|--mode tproxy|-m tproxy|g' /etc/init.d/acc
```

### 7.2 tproxy_ip 伪造值导致子进程崩溃 (v2.3.0)

**严重程度**: 致命 — web 子进程崩溃循环 (exit 255)，加速几秒后断开

**原因**: `/tmp/acc/acc_core_conf.json` 中 `tproxy_ip` 为 `"10.20.30.40"` — 不存在的伪造 IP。daemon 从 JSON 读取此值 fork web 子进程，子进程尝试绑定 TPROXY 到这个不存在的地址 → 崩溃。

**同时影响**: init 脚本中 `args="... -l 10.20.30.40"` 是同一伪造 IP。

**修复**:
```bash
# 修复 JSON
sed -i "s|\"tproxy_ip\":\"[^\"]*\"|\"tproxy_ip\":\"$LAN_IP\"|" /tmp/acc/acc_core_conf.json
# 修复 init 脚本
sed -i "s|-l 10.20.30.40|-l $LAN_IP|g" /etc/init.d/acc
```

### 7.3 kmod-netem 在 kernel 6.x 不存在 (v2.2.1)

**原因**: kernel 6.x 将 `CONFIG_NET_SCH_NETEM` 编译进内核而非独立模块，`kmod-netem` 包不存在 → `opkg install` 报错。

**修复**: 新增 `has_netem()` 函数三重检查: `lsmod sch_netem` → `/proc/config.gz` → 检查包是否存在。

### 7.4 fw4 防火墙误判 (v2.2.1)

**影响范围**: ImmortalWrt 24.10 等 nftables 衍生固件

**原因**: 仅检查 `/usr/sbin/fw4` 存在性，但 ImmortalWrt 未装 `firewall4` 包 → 误判为 fw3 → 安装错误的 iptables 包 → 规则不被 nftables 处理。

### 7.5 switch_mode() 丢失启动参数 (v2.2.1)

**原因**: 非 IPK 版切换时 `sed 's|${args}|--mode tun|'` 将整行替换为仅 `--mode tun`，丢弃了 `-p 5588` 和 `-l` 参数 → acc-gw 不在正确端口监听。

**修复**: 仅替换模式标志 (`-m tun` ↔ `-m tproxy`)，保留其他参数。

### 7.6 命令注入漏洞 (v2.1.1 → v2.2.1)

**位置**:
- `schedule_pause()` — username/password 直接拼入 `echo '...' >> /etc/crontabs/root`
- `trigger_autopause()` — account_token 直接拼入 `curl -d '...'`

**修复**: 调用前对值做 shell 转义 (`gsub("'", "'\\''")` / `gsub('"', '\\"')`)

### 7.7 /etc/hotplug.d/firewall/ 目录不存在 (v2.2.1)

**原因**: ImmortalWrt 24.10 未预创建此目录 → `cat >` 写入报 `nonexistent directory`

**修复**: 写入前 `mkdir -p /etc/hotplug.d/firewall`

### 7.8 autopause.lua 第 30 行 nil 错误 (v2.2.1)

**原因**: `if existing_token ~= ""` 在 Lua 中 `nil ~= ""` 为 **true** → 对 nil 调用 `:sub()`

**修复**: `if existing_token and existing_token ~= ""`

---

## 8. acc-gw 二进制技术特征

### 8.1 版本信息

```
实测版本: v1.2.2.13
架构: arm64 (aarch64)
运行模式: release
加速模式: TUN (acc_mode:1) — 此版本不支持
          TPROXY (acc_mode:2) — 唯一可用模式
```

### 8.2 子进程参数

| 角色 | 参数示例 | 管理方式 |
|------|----------|----------|
| daemon | `-r daemon -m tproxy -p 5588 -l 192.168.10.1` | procd |
| web | `-r web -m tproxy -p 5588 -l 192.168.10.1` | daemon fork |
| acc (设备) | `-r acc -t PC -m tproxy` | daemon fork (按需) |
| upgrade | `-r upgrade` | procd |

### 8.3 日志文件

| 文件 | 内容 |
|------|------|
| `/tmp/acc/log/acc_daemon.log` | daemon 主日志 (进程管理/错误) |
| `/tmp/acc/log/acc_PC.log` | PC 加速日志 |
| `/tmp/acc/log/acc_Game.log` | 游戏主机加速日志 |
| `/tmp/acc/log/web_api.log` | API 请求日志 |
| `/tmp/acc/log/acc_upgrade.log` | 升级检查日志 |

### 8.4 错误码含义

| 日志消息 | 含义 | 严重程度 |
|----------|------|----------|
| `unknow acc mode:1` | TUN 模式不被此版本支持 | Warning |
| `create iptables chain failed` | GAMEACC 链创建失败 (已经存在) | Error (可忽略) |
| `child process exit, status:255` | web 子进程崩溃 | Fatal |
| `acc_objs is empty` | 无活跃加速设备 (正常初始状态) | Info |
| `delete iptables rule failed` | 清理旧规则失败 (首次启动正常) | Info |

### 8.5 全局配置 API

acc-gw 从雷神后端拉取全局配置:
```
URL: https://opapi.xxghh.biz/common/comm/dict/getDictItems/LeigodBox_GlobalConfig/
频率: 每 5 分钟
```

配置项包括:
- MatchMAC: 游戏设备 MAC 地址匹配表
- DirectCIDR: 直连 IP 段 (不走代理)
- ProxyCIDR: 代理 IP 段 (走代理)
- ApiTurnServer: TURN 中继地址
- RouterApiTurnServer: 路由器专用 TURN 中继 (route-turn.xxghh.biz:5588)
- TokenCheckURL: Token 验证地址
- NetOption: DNS 配置 (114.114.114.114 / 223.5.5.5)

---

## 9. 自动暂停时长计费

### 9.1 工作流程

```
cron (每 2 分钟)
    │
    ▼
/usr/sbin/leigod-auto-pause.sh
    │
    ├─ 读取 UCI accelerator.*.state
    │   Phone: 1=加速中, 2=停止, 3=暂停
    │   PC: 同上
    │   Game: 同上
    │   Unknown: 同上
    │
    ├─ 全部为 0/空 → 空闲
    │   └─ fallback: acc-gw 日志 mtime > 5分钟 → 空闲
    │
    ├─ 连续 N 次空闲 (默认 3 次, 即 ~6 分钟)
    │   └─ 调用 POST https://webapi.leigod.com/api/user/pause
    │       Body: {"account_token":"<TOKEN>","lang":"zh_CN"}
    │
    └─ 10 分钟冷却期 (防重复调用)
```

### 9.2 配置文件

```
/etc/leigod-auto-pause.conf  (权限 600)
    ACCOUNT_TOKEN='...'        ← 从浏览器 F12 获取，每 7 天过期
    IDLE_CHECKS_BEFORE_PAUSE=3
    API_TIMEOUT=10
    API_ENDPOINT="https://webapi.leigod.com"
    NOTIFY_ON_PAUSE=1
```

### 9.3 API 响应码

| code | 含义 |
|------|------|
| `0` | 暂停成功 |
| `400803` | 已经处于暂停状态 |
| 空/无响应 | token 过期或网络问题 |

### 9.4 状态文件

```
/tmp/leigod-auto-pause.state
    idle_count=2859          ← 累计空闲检测次数 (异常时不增长)
    last_pause_epoch=<ts>    ← 上次成功暂停的 Unix 时间戳
```

---

## 10. LuCI Web 界面

### 10.1 页面路由

| 路径 | 页面 | 入口 |
|------|------|------|
| `/admin/services/acc/service` | 服务配置 | cbi("leigod/service") |
| `/admin/services/acc/device` | 设备管理 | cbi("leigod/device") |
| `/admin/services/acc/app` | APP 下载 | template("leigod/app") |
| `/admin/services/acc/notice` | 公告 | cbi("leigod/notice") |
| `/admin/services/acc/autopause` | 自动暂停 | cbi("leigod/autopause") |
| `/admin/services/acc/debug` | 诊断 | template("leigod/debug") |

### 10.2 API 端点

| 端点 | 方法 | 用途 |
|------|------|------|
| `status` | XHR.poll | 获取加速状态 (JSON) + 防火墙类型 |
| `start_acc_service` | call | 启用 + 重启服务 |
| `stop_acc_service` | call | 停止 + 禁用服务 |
| `schedule_pause` | call | 配置定时暂停 (crontab) |
| `ap_status` | XHR.get | 自动暂停运行时状态 |
| `ap_save` | call | 保存自动暂停配置 |
| `ap_trigger` | call | 手动触发一次暂停 |
| `ap_toggle` | call | 启用/禁用 cron |
| `debug_status` | XHR.get | 完整诊断数据 (JSON) |

### 10.3 诊断页面检查项

| 类别 | 检查项 | 严重程度 |
|------|--------|----------|
| **进程** | acc-gw 是否运行 | error |
| **进程** | API 端口 5588 是否监听 | error |
| **进程** | 服务是否开机自启 | warning |
| **Init 脚本** | 文件是否存在 | error |
| **Init 脚本** | 模式标志是否为短格式 (`-m`) | error |
| **Init 脚本** | 是否包含 `-p` 端口参数 | error |
| **Init 脚本** | 进程运行模式与 init 脚本是否一致 | warning |
| **网络** | TUN 接口是否存在 (TUN 模式时) | warning |
| **网络** | 防火墙规则是否放行 TCP 5588 | warning |
| **网络** | fw4 hotplug 脚本是否安装 | warning |
| **系统** | kmod-tun 是否安装 | warning |
| **系统** | iptables-nft 是否安装 (fw4) | warning |
| **系统** | kmod-nft-nat 是否安装 (fw4) | warning |
| **设备** | 是否有设备在加速 (info) | info |

### 10.4 技术栈

```
基础框架: LuCI1 Lua CBI
兼容层: luci-compat (OpenWrt 24.10 需要)
前端交互: JavaScript XHR.poll() / XHR.get() (非 ucode)
令牌缓存: 浏览器端 (非 RPCD)
```

---

## 11. 关键技术约束与经验教训

### 11.1 二进制限制

| 约束 | 影响 |
|------|------|
| v1.2.2.13 **不支持** TUN 模式 (acc_mode:1) | 必须使用 TPROXY，即使 fw4 下兼容性差 |
| 仅识别短格式 `-m tun`/`-m tproxy` | `--mode tun` 被静默忽略 |
| `acc_core_conf.json` 优先级高于 init 脚本 args | 修复 JSON 比修复 init 脚本更重要 |
| `/tmp` 重启后清空 | JSON 在重启后由 init 脚本 args 重建 |

### 11.2 `/tmp` 持久化问题

`/tmp/acc/acc_core_conf.json` 在路由器重启后会丢失。修复策略:
1. 确保 init 脚本 args 中的 `-l` 参数正确 — 这是重启后 JSON 的数据源
2. 在 `fix_acc_core_conf()` 中同时修复 JSON 和 init 脚本
3. 诊断页面自动检测并修复

### 11.3 运维检查清单

加速不生效时按此顺序排查:

1. **acc_core_conf.json tproxy_ip 是否正确?** — 最常见根因
2. **init 脚本 args 是否为短格式?** — `--mode` 长格式被忽略
3. **GAMEACC 链是否有 TPROXY 规则?** — `iptables-nft -t mangle -L GAMEACC -n`
4. **web 子进程是否正常?** — `ps | grep acc-gw`，不应有 Z (僵尸)
5. **daemon 日志有无 "exit 255"?** — web 子进程崩溃标志
6. **是否为 fw4 但误判为 fw3?** — `[ -x /usr/sbin/nft ]`
7. **是否有 fw4 hotplug 脚本?** — 防火墙重载后规则丢失

---

## 12. 官方插件生态

### 12.1 官方安装方式 (手机 APP 驱动)

雷神加速器官方的路由器插件安装是 **手机 APP 引导的自动化流程**，与 SSH 手动安装不同:

```
手机连接路由器 WiFi
    │
    ▼
雷神加速器 APP → 硬件加速页 → 路由器插件模块 → [安装]
    │
    ▼
APP 自动识别 WiFi 和设备信息
    │
    ▼
输入路由器管理员账号密码
    │
    ├─ 需要 SSH 的路由器 (华硕/小米/OpenWrt):
    │   └─ 需手动开启 SSH → APP 通过 SSH 执行安装脚本
    │
    └─ 已集成插件的路由器 (雷神电竞路由器等):
        └─ APP 直接通过厂商 API 安装插件
```

### 12.2 官方安装脚本 (plugin_install.sh)

**下载地址**: `http://119.3.40.126/router_plugin/plugin_install.sh`

**脚本执行流程 (基于社区分析)**:

```
1. 检测路由器架构 (armv7l / aarch64 / x86_64 / mips)
2. 下载对应架构的 acc-gw 二进制文件
3. 部署 LuCI Web 界面文件到 /usr/lib/lua/luci/
4. 创建 /etc/init.d/acc (procd 服务)
5. 配置 UCI /etc/config/accelerator
6. 开启并启动服务
```

**注意**: 安装脚本包含 `uninstall openwrt luasrc` 步骤，会删除所有已安装的 LuCI 文件（然后只写入 5 个自己的文件）。这就是 fw4 适配版需要在安装后重新调用 `apply_luci_fw4_patch()` 恢复 10 个完整文件的原因。

### 12.3 官方支持的路由器

| 类别 | 型号 |
|------|------|
| **雷神自有** | 雷神战斧加速盒 Pro、雷神战斧加速盒、雷系电竞路由器 A8000 |
| **华硕** | RT-AC86U、RT-AX86U、GT-AX6000 等 (需手动开启 SSH) |
| **小米/Redmi** | Redmi AX6000、AX5400 等 (需米家 App 安装) |
| **OpenWrt** | 通用 OpenWrt 固件 (需开启 UPnP + SSH 安装) |
| **其他** | 更多型号持续增加中 (官方称) |

### 12.4 UPnP — 设备发现的关键

**UPnP 是官方安装的必需前置条件**，不是可选项:

1. 安装 `luci-app-upnp` (约 4.4KB)
2. 在 LuCI → 服务 → UPnP 中开启 "启动 UPnP 与 NAT-PMP 服务"
3. APP 通过 UPnP SSDP 组播发现路由器上的雷神插件
4. 没有 UPnP → APP 无法识别设备 → 无法完成绑定

**底层机制**: 手机 APP 发送 SSDP M-SEARCH 请求，路由器上的 miniupnpd 响应，APP 从中获取路由器 IP 和插件端口信息。

### 12.5 官方帮助中心资源

| 资源 | 地址 |
|------|------|
| 路由器插件安装及使用教程 | https://www.leigod.com/help-center/84683 |
| OpenWrt 插件安装前准备 | https://www.leigod.com/help/84685.html |

---

## 13. 社区生态与工具

### 13.1 社区管理器

| 项目 | 作者 | 说明 |
|------|------|------|
| [openwrt-leigodacc-manager](https://github.com/miaoermua/openwrt-leigodacc-manager) | miaoermua (喵二) | Shell 管理器 (上游，仅支持 fw3) |
| [luci-app-leigod-acc](https://github.com/miaoermua/luci-app-leigod-acc) | miaoermua | Lean LEDE 剥离的 LuCI IPK 包 |
| **leigod-fw4.sh** (本项目) | fw4 适配版 | 在上游基础上增加 fw4/nftables 兼容 + 诊断 + 自动暂停 |

### 13.2 第三方 API 封装

| 项目 | 语言 | 说明 |
|------|------|------|
| [leigod-api](https://github.com/jiajiaxd/leigod-api) | Node.js (ES) | npm 包，封装雷神用户 API (暂停/恢复时长等)，含 JSDoc 类型注解 |

### 13.3 社区讨论活跃区

| 平台 | 链接 |
|------|------|
| 恩山无线论坛 (right.com.cn) | OpenWrt 专版，多篇雷神插件安装帖 |
| 喵二博客 (miaoer.net) | 使用指南 + 原理分析 |
| 喵二交流群 (QQ) | 口令码 `miaoer` 可兑换 50 小时体验时长 |

---

## 14. 雷神 API 接口参考

### 14.1 用户服务 API (webapi.leigod.com)

基于 leigod-api (Node.js) 和 auto-pause.sh 分析:

| 端点 | 方法 | 用途 |
|------|------|------|
| `/api/user/pause` | POST | 暂停时长计费 |
| (推测) `/api/user/resume` | POST | 恢复时长计费 |
| (推测) `/api/user/info` | GET | 用户信息/时长查询 |

**请求格式**:
```json
POST /api/user/pause
Content-Type: application/json
User-Agent: LeigodAcc-AutoPause/1.0

{
  "account_token": "<TOKEN>",
  "lang": "zh_CN"
}
```

**响应码**:
| code | 含义 |
|------|------|
| `0` | 操作成功 |
| `400803` | 已经处于暂停状态 |

**Token 获取方式**: 浏览器登录 leigod.com → F12 → Application → Local Storage → `account_token`。有效期约 7 天。

### 14.2 盒子后端 API (opapi.xxghh.biz)

**全局配置接口** (acc-gw 每 5 分钟调用):
```
GET https://opapi.xxghh.biz/common/comm/dict/getDictItems/LeigodBox_GlobalConfig/
```

**返回结构**:
```json
{
  "retCode": "100",
  "retMsg": "操作成功",
  "success": true,
  "retData": [
    {"text": "MatchMAC", "value": "https://dfs01.nn.com/v2/.../mac.json"},
    {"text": "DirectCIDR", "value": "https://dfs01.nn.com/v2/.../cidrs_direct.txt"},
    {"text": "ProxyCIDR", "value": "https://dfs01.nn.com/v2/.../cidrs.txt"},
    {"text": "Interval", "value": "300"},
    {"text": "RouterApiTurnServer", "value": "{\"udp\":\"route-turn.xxghh.biz:5588\", ...}"},
    {"text": "RouterTokenCheckURL", "value": "https://opapi1.xxghh.biz/speed/router/plug/check"},
    {"text": "NetOption", "value": "{\"resolver\":{\"prefer\":1, \"addr\":[\"114.114.114.114:53\"]}}"}
  ]
}
```

**Token 验证接口**:
```
POST https://opapi1.xxghh.biz/speed/router/plug/check
(用于验证盒子/路由器插件的 token 有效性)
```

### 14.3 CDN/文件服务 (dfs01.nn.com)

| 文件 | 用途 |
|------|------|
| `mac.json` | 游戏设备 MAC 地址匹配表 (设备识别) |
| `cidrs_direct.txt` | 直连 IP 段 (不走加速通道) |
| `cidrs.txt` | 代理 IP 段 (走加速通道) |
| `shellrun.sh` | 远程命令执行脚本 |

### 14.4 TURN 中继服务器

| 服务器 | 用途 | 端口 |
|--------|------|------|
| `box-turn.xxghh.biz` | 加速盒 TURN 中继 (非路由器) | UDP 5588 |
| `route-turn.xxghh.biz` | **路由器专用** TURN 中继 | UDP 5588 |
| (同域名) | WebSocket 设备发现 | TCP 5443 (`/dev`, `/ws`) |

**TURN 为路由器分配规则**: 由 `RouterApiTurnServer` JSON 配置下发，包含 UDP 中继地址和 WSS 信令地址。

---

## 15. 与其他代理插件共存

### 15.1 已知冲突

雷神加速器 **不支持与任何代理类插件共存**，同时启用会**直接断网**:

| 冲突插件 | 冲突原因 | 解决方案 |
|----------|----------|----------|
| OpenClash | 共享 TPROXY mangle 规则，GAMEACC 链冲突 | 雷神切 TUN 模式 + Clash 用 TPROXY (错开)，或关闭 Clash |
| PassWall | 同上 | 同上 |
| SSR-Plus | 同上 | 同上 |
| ShellClash | 同上 | 同上 |

### 15.2 共存方案 (TUN 模式)

当必须共存时，社区推荐方案:

1. 雷神使用 TUN 模式 (创建虚拟网卡，不依赖 mangle 表)
2. 代理插件使用 TPROXY 或 Redir 模式
3. 两者通过不同路由表分流，互不干扰

**但**: v1.2.2.13 版本的 acc-gw **不支持 TUN 模式** (`unknow acc mode:1`)，因此此方案对新版二进制不可用。

### 15.3 OpenClash 特定冲突

OpenClash 在 redir-host 兼容模式 (不代理 UDP) 时，雷神仍然会报告"本地网络异常"。原因:
- 雷神插件会检测网络环境
- OpenClash 即使是兼容模式也会修改路由表和 DNS 设置
- 雷神的网络检测脚本可能被 OpenClash 的修改触发误报

---

## 16. 网络拓扑与延迟

### 16.1 主路由 vs 旁路由

| 部署方式 | 延迟表现 | 原因 |
|----------|----------|------|
| **主路由** | 正常 (50ms) | TPROXY 在数据包进入时立即拦截，零额外跳数 |
| **旁路由** | 偏高 (120ms+) | 数据包需经过旁路由网关转发，额外一跳 + 路由策略处理 |

**强烈建议在主路由上安装**。

### 16.2 TURN 中继延迟组成

```
总延迟 = 设备→路由器 (WiFi/有线)
       + TPROXY 拦截开销 (~1ms)
       + 路由器→中继 (你实测 32ms)
       + 中继→游戏服务器 (不确定，取决于雷神机房到游戏服路径)
       + 游戏服务器处理延迟
```

**可优化部分**:
- 设备→路由器: 有线 > 5GHz WiFi > 2.4GHz WiFi
- TPROXY 开销: 极小 (内核态)
- 路由器→中继: 取决于你到雷神机房的物理距离，无法改变

### 16.3 bufferbloat 与延迟波动

即使加速器链路正常，以下因素仍可导致延迟波动:

1. **上行带宽打满**: 游戏上传 + 其他设备上传 = WAN 口缓冲区堆积
2. **无 QoS/SQM**: 数据包 FIFO 排队，游戏包被大文件传输包阻塞
3. **WiFi 干扰**: 2.4GHz 频段拥塞

**缓解方案**:
```bash
opkg update && opkg install sqm-scripts luci-app-sqm
# 在 LuCI → 网络 → SQM QoS 中配置:
# Interface: eth0 (WAN), Download/Upload 设为实际带宽的 85-95%
```

**自动化方案 (v2.3.3+)**：
- 菜单 `L` — 6 步延迟诊断（含自动修复：add fq_codel、扩大 conntrack、PPPoE MSS clamping）
- 菜单 `T` — 一键内核网络调优（fq_codel + BBR + conntrack 优化）
- CLI `leigod-fw4.sh diagnose` — 非交互式诊断报告
- CLI `leigod-fw4.sh tune-network` — 命令行直接调优

### 16.4 内核网络调优参数 (v2.3.3)

`apply_network_tuning()` 写入 `/etc/sysctl.d/99-leigod-latency.conf`：

| 参数 | 默认值 | 调优值 | 原因 |
|------|--------|--------|------|
| `net.core.default_qdisc` | pfifo_fast | `fq_codel` | 公平队列 + AQM，防止 bufferbloat |
| `net.ipv4.tcp_congestion_control` | cubic | `bbr` | BBR 不会将每次丢包当拥塞，适合抖动链路 |
| `net.core.rmem_max` | ~212992 | `4194304` | 防止突发流量丢包 |
| `net.core.wmem_max` | ~212992 | `4194304` | 同上 |
| `net.ipv4.tcp_fastopen` | 1 | `3` | 省 1 RTT 连接建立 |
| `net.netfilter.nf_conntrack_max` | ~16384 | `65536` | 防止表满导致新连接延迟 |
| `net.netfilter.nf_conntrack_tcp_timeout_established` | 432000 (5d) | `3600` (1h) | 更快释放过期连接 |
| `net.ipv4.tcp_keepalive_time` | 7200 | `120` | 快速检测断连 |

> **注意**：BBR 需要内核编译支持 `CONFIG_TCP_CONG_BBR=y`。调优后脚本会自动验证 BBR 是否实际激活。

### 16.5 延迟诊断 6 步流程 (v2.3.3)

```
[1/6] QoS 队列管理 → 检测 SQM/cake/fq_codel, 无 qdisc 时建议安装
[2/6] GAMEACC 流量分析 → 统计 TPROXY 包数, >50000 警告非游戏流量劫持
[3/6] conntrack 压力 → 使用率 >80% 主动询问扩大 2×
[4/6] DNS 中继延迟 → 统计 DNS 劫持包数
[5/6] TURN 中继稳定性 → ping + mdev 抖动测量, >15ms 警告, >50ms 失败
[6/6] PPPoE MTU/分片 → 检查 TCP MSS clamping + MTU 合理性, 缺失时一键添加
```

与 v2.3.0 原始 5 步版本相比的改进：
- **iptables-nft/iptables 自动回退** — 兼容最小构建（仅有 iptables symlink）
- **auto-conntrack 扩展** — 不再仅打印建议，主动提供一键扩大
- **TURN mdev 抖动测量** — 量化中继抖动，区分"中继问题"和"本地问题"
- **PPPoE 分片检查** — 检测 MSS clamping 缺失（常见于 PPPoE 用户，分片显著增加延迟抖动）

---

## 17. 安全注意事项

| 风险 | 说明 | 缓解 |
|------|------|------|
| **curl | sh 管道执行** | 雷神官方和社区脚本都通过 `curl <url> | sh` 安装，以 root 权限执行远程代码 | 审查脚本或使用开源管理器 |
| **HTTP 明文下载** | 官方脚本 URL 为 `http://119.3.40.126/...` (非 HTTPS)，存在 MITM 风险 | v2.1.1+ 优先 HTTPS 并 fallback HTTP |
| **account_token 泄露** | token 存储在 `/etc/leigod-auto-pause.conf` (权限600)，但通过 UCI 明文传递 | 使用权限 600 + 脱敏显示 |
| **命令注入** | 用户输入 (UCI 值) 直接拼入 shell 命令 | v2.1.1+ 对输入做 shell 转义 |
| **`cat >` 覆盖系统文件** | 脚本多处使用 `cat > /path` 写入系统配置文件 | 写入前备份，路径硬编码 |

---

## 18. 故障案例 (补充社区案例)

### 案例 3: Redmi AX6000 加速失败 (社区报告)

**来源**: right.com.cn 论坛
**现象**: 手机一键加速后，10+ 秒自动断开

**社区方案**:
```bash
iptables -I OUTPUT -o tun3+ -p tcp -m tcp --dport 80 -j DROP
```
**原因分析**: 插件启动时向 TUN 隧道对端 80 端口发起大量 TCP 连接，触发服务端限流/拒绝。

**注意事项**: 规则重启后失效，需加入自启脚本，或联系客服获取 v2.0 插件版本。

### 案例 4: 固件发行版识别失败

**现象**: 安装时报"获取设备品牌或型号失败"

**原因**: 修改版固件修改了 `/etc/openwrt_release` 中的发行版标识。

**解决**:
```bash
sed -i 's/Oprt/OpenWrt/g' /etc/openwrt_release
```

### 案例 5: 与 OpenClash 同时运行断网

**现象**: OpenClash + 雷神同时开启 → 路由器断网

**原因**: 两者都操作 mangle 表的 PREROUTING 链，GAMEACC 链与 Clash 规则冲突。

**解决**: TUN 模式错开 (如 acc-gw 版本支持)，或关闭代理插件。

### 案例 6: 加速后所有流量走加速线路

**现象**: 开启加速后，所有网络流量 (包括下载、视频) 都走加速线路 → 下载变慢

**原因**: 雷神插件可能劫持了全部流量而非仅游戏流量 (GAMEACC 链匹配过宽)。

**解决**: 下载时手动暂停加速；无完美解决方案。

### 案例 7: 官方 OpenWrt 25.05.5 安装成功但无效

**来源**: right.com.cn 论坛用户反馈
**现象**: 安装成功、APP 显示加速中，但实际无加速效果

**状态**: 未解决。可能与 fw4/nftables 环境有关（和本文案例 1 属于同类问题）。

---

## Sources

**官方资源**:
- [雷神加速器官网 — 路由器插件安装及使用教程](https://www.leigod.com/help-center/84683)
- [雷神加速器 — OpenWrt 插件安装前准备](https://www.leigod.com/help/84685.html)

**上游开源项目**:
- [GitHub — miaoermua/openwrt-leigodacc-manager](https://github.com/miaoermua/openwrt-leigodacc-manager) (Shell 管理器)
- [GitHub — miaoermua/luci-app-leigod-acc](https://github.com/miaoermua/luci-app-leigod-acc) (LuCI IPK 包)
- [GitHub — jiajiaxd/leigod-api](https://github.com/jiajiaxd/leigod-api) (Node.js API 封装)

**社区讨论**:
- [恩山论坛 — OpenWrt 雷神加速器插件安装方法](https://www.right.com.cn/FORUM/thread-8395262-1-1.html)
- [恩山论坛 — UU、迅游、灵缇、雷神等加速器安装汇总](https://www.right.com.cn/forum/thread-8441527-1-1.html)
- [恩山论坛 — OpenWrt 安装雷神加速器插件教程](https://www.right.com.cn/forum/thread-8375243.html)
- [喵二博客 — 雷神加速器插件管理器使用指南](https://www.miaoer.net/posts/blog/openwrt-leigodacc-manager)

**本项目**:
- [CHANGELOG.md](./CHANGELOG.md) — 完整变更历史 (v2.0.0 → v2.3.3)
- [SESSION-LOG.md](./SESSION-LOG.md) — 开发会话记录
- [leigod-fw4-install-guide.md](./leigod-fw4-install-guide.md) — 安装指南

### 案例 1: 延迟 300ms+ (APP 显示加速中但无效)

**日期**: 2026-05-25
**路由器**: Xiaomi Redmi AX6000 / ImmortalWrt 24.10
**现象**: 手机 APP 能连接路由器，点击加速后 APP 显示加速中，但游戏延迟 300ms+

**排查过程:**
1. `acc_core_conf.json` 中 `tproxy_ip` = `"10.20.30.40"` ← 不存在于任何接口
2. init 脚本 `args="... -l 10.20.30.40"` ← 同一伪造 IP
3. daemon 日志: `child process exit, pid:XXX, status:255` ← web 子进程崩溃循环
4. 先尝试 TUN 模式 (`acc_mode:1`) → `unknow acc mode:1` ← 此版本不支持
5. 回退 TPROXY + 正确 IP `192.168.10.1` → **加速生效**

**根因**: 伪造的 `tproxy_ip` 导致 web 子进程绑定 TPROXY 失败，崩溃循环。acc_mode:1 (TUN) 又不被支持。

**修复**: 三处修改:
- `acc_core_conf.json`: tproxy_ip → `192.168.10.1`
- `/etc/init.d/acc` line 135: `-l 10.20.30.40` → `-l 192.168.10.1`
- 杀掉所有残留进程后干净重启

### 案例 2: 自动暂停失效 (空闲计数正常但不暂停)

**现象**: `idle_count=2859` 持续增长，上次成功暂停在 2026-05-21

**原因**: account_token 过期 (典型有效期 7 天)，curl 请求 API 返回空响应

**修复**: 重新获取 token → 更新配置 → 重置状态计数器

---

## Sources

- [GitHub — miaoermua/openwrt-leigodacc-manager](https://github.com/miaoermua/openwrt-leigodacc-manager) (上游仓库)
- [本仓库 CHANGELOG.md](./CHANGELOG.md) — 完整变更历史 (v2.0.0 → v2.2.1)
- [本仓库 SESSION-LOG.md](./SESSION-LOG.md) — 开发会话记录
- [本仓库 leigod-fw4-install-guide.md](./leigod-fw4-install-guide.md) — 安装指南
