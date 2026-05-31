# 雷神加速器插件 — OpenWrt 24.10 (fw4) 安装指南

## 前置条件

- OpenWrt 24.10+ 系统（使用 fw4/nftables 防火墙）
- 路由器已联网
- SSH 已启用
- 至少 50MB 可用存储空间（系统 → 软件包 查看）

## 步骤 1：将脚本上传到路由器

### 方法 A — MobaXterm 一键上传（Windows 用户推荐）

[MobaXterm](https://mobaxterm.mobatek.net) 是 Windows 平台最常用的 OpenWrt 管理工具，内置 SSH 终端 + SFTP 文件浏览器，无需额外安装 scp 工具。

1. **下载并启动 MobaXterm**（免费 Home Edition 即可）

2. **连接路由器**：点击 `Session` → `SSH`，填入路由器 IP（如 `192.168.1.1`），用户名 `root`

3. **上传脚本**：连接成功后，左侧会显示 SFTP 文件浏览器。直接将以下文件**拖拽**到 `/tmp/` 目录：

   - `leigod-fw4.sh`
   - `auto-pause.sh`（如需要使用自动暂停功能）

   > **提示**：如果 SFTP 侧栏未显示，按 `Ctrl+Shift+B` 打开。

4. **验证上传**：在右侧终端输入 `ls -la /tmp/leigod-fw4.sh`，确认文件已上传

### 方法 B — 使用 scp 命令行上传

在**电脑**终端执行（不是路由器）：

```bash
scp C:\Users\Myrna\leigod-fw4.sh root@192.168.1.1:/tmp/
```

> 将 `192.168.1.1` 替换为你的路由器 IP
>
> **Windows 注意**：系统自带的 scp 在部分版本不可用。如提示 `scp 不是内部命令`，请使用上方 MobaXterm 方式，或安装 [WinSCP](https://winscp.net) 进行文件传输。

### 方法 C — 路由器直接下载

先在电脑上将 `leigod-fw4.sh` 放到任意 HTTP 可访问位置，然后 SSH 登录路由器：

```bash
cd /tmp
wget -O leigod-fw4.sh "http://你的电脑IP:端口/leigod-fw4.sh"
```

### 方法 D — 手动复制粘贴

1. SSH 登录路由器：`ssh root@192.168.1.1`
2. 在路由器上执行：`cat > /tmp/leigod-fw4.sh`
3. 用文本编辑器打开 `leigod-fw4.sh`，复制全部内容
4. 粘贴到 SSH 终端，按 `Ctrl+D` 结束输入

## 步骤 2：赋予执行权限并运行

```bash
chmod +x /tmp/leigod-fw4.sh
/tmp/leigod-fw4.sh
```

你应该看到类似输出：

```
[INFO] 检测到 fw4/nftables 防火墙 - OpenWrt 24.10+ 适配版
[INFO] 将使用 nftables 兼容模式安装依赖

=============================
OpenWrt LeigodAcc Manager
防火墙: nftables (fw4)

1. 安装
2. 卸载
3. 重装/更新
4. 禁用/启用 雷神服务
5. 切换运行模式   (TUN/Tproxy)
6. 安装兼容性依赖 (主机优化)
7. 禁用/启用 IPv6 (手机优化)
8. 安装 Lean IPKG 版
9. 自动暂停时长 (省时长)
S. 查看服务状态 (诊断)
L. 延迟波动诊断 (bufferbloat/QoS/PPPoE)
T. 内核网络调优 (低延迟优化)
H. 反馈/帮助
0. 退出
=============================
选择数字/字母并回车执行:
```

## 步骤 3：安装

输入 `1` 并回车。脚本会自动执行以下操作：

1. **自动检测防火墙类型** — 识别 fw4/nftables（包括未安装 `firewall4` 包的 ImmortalWrt 24.10）
2. **更新 opkg 软件源**
3. **安装 fw4 兼容依赖**：
   - `iptables-nft` — iptables 兼容层（将 iptables 命令转译为 nftables）
   - `kmod-nft-nat` — NAT 内核模块
   - `kmod-nft-tproxy` — TPROXY 内核模块
   - `kmod-tun` — TUN 设备支持
   - `libpcap`、`tc-full`、`conntrack` 等
   - `kmod-netem` — 内核 6.x 已内置则自动跳过
4. **安装 `luci-compat`** — LuCI Lua CBI 兼容层（如有 LuCI）
5. **配置 fw4 防火墙集成** — 创建 hotplug 脚本，fw4 重载时自动恢复加速规则
6. **启用 UPnP** — 用于手机 APP 发现设备
7. **下载并安装雷神官方加速器**
8. **恢复 fw4 LuCI 补丁** — 官方安装脚本会清除 LuCI 文件，脚本自动恢复
9. **询问是否切换 TUN 模式** — fw4 下推荐立即切换

> **注意**：选项 `1`（官方安装）**不包含 LuCI 网页管理界面**。如需通过路由器 Web 后台管理插件，请使用选项 `8`（Lean IPKG 版）安装 `luci-app-leigod-acc`。

## 步骤 4：选择运行模式（重要）

安装完成后，**建议将模式切换为 TUN**，fw4 下 TUN 模式兼容性最好：

1. 输入 `5` 进入切换模式
2. 选择切换为 TUN 模式（再次运行选项 5 可切回 TPROXY）

## 步骤 5：绑定设备

1. 打开手机上的**雷神加速器 APP**
2. APP 应通过 UPnP 自动发现路由器
3. 如发现不了，确认 UPnP 已启用（服务 → UPnP）

## 步骤 6：配置自动暂停时长计费（可选）

输入 `9` 进入自动暂停子菜单，可避免游戏结束后继续消耗时长。

### 6.1 获取 account_token

安装前需要先获取雷神账号的 account_token：

1. 在**电脑浏览器**打开 https://vip.leigod.com 并登录你的雷神账号
2. 按 `F12` 打开开发者工具
3. 切换到 **Application（应用程序）** 标签
4. 左侧找到 **Local Storage** → `https://vip.leigod.com`
5. 找到 key 为 `account_token` 的条目，复制其 value（一长串字符串）

### 6.2 安装与配置

在子菜单选择 **安装/配置**，脚本会：

1. 将 `auto-pause.sh` 写入路由器 `/usr/bin/`
2. 引导你粘贴 account_token 并保存到 `/etc/leigod-auto-pause.conf`
3. 自动添加 cron 任务（默认每 2 分钟检查一次）
4. 所有操作记录到系统日志

### 6.3 工作原理

- 通过 UCI 检查 `/etc/config/accelerator` 中 Phone/PC/Game/Unknown 的设备加速状态
- 连续 3 次检测到所有设备空闲（约 6 分钟）后调用雷神 API 暂停时长
- 暂停后 10 分钟内不重复调用（API 防抖）
- 设备恢复游戏后自动重置计次

### 6.4 查看状态

子菜单选择 **查看运行状态**，会显示：
- account_token 配置情况（脱敏显示）
- cron 任务是否就绪
- 当前各设备加速状态
- 最近系统日志

### 6.5 卸载

子菜单选择 **卸载**，会清理 cron 任务、脚本文件、配置文件、状态文件。

## 步骤 7：查看服务状态

输入 `S` 可查看完整诊断信息，包括：
- 安装状态和服务运行状态
- 当前加速模式和 acc-gw 进程
- 各设备加速状态（手机/PC/游戏/未知）
- 自动暂停配置和运行状态
- 最近日志异常

## 步骤 7.1：延迟波动诊断（重要）

如果游戏延迟频繁在 50~500ms 之间抖动，输入 `L` 运行 **6 步延迟诊断**：

| 步骤 | 检查项 | 可自动修复 |
|------|--------|-----------|
| 1/6 | WAN 口队列管理 (QoS) | ✅ 安装 SQM / 添加 fq_codel |
| 2/6 | GAMEACC 劫持流量分析 | 无（闭源限制） |
| 3/6 | conntrack 连接追踪表压力 | ✅ 一键扩大 2× |
| 4/6 | DNS 中继延迟 | 无 |
| 5/6 | TURN 中继稳定性 + 抖动 (mdev) | 无 |
| 6/6 | PPPoE MTU/分片 (MSS clamping) | ✅ 一键添加 MSS clamping |

诊断完成后自动询问是否安装 SQM QoS（最有效的防抖动方案）。

## 步骤 7.2：内核网络调优（推荐）

输入 `T` 一键应用 **8 项内核低延迟优化参数**：

- `fq_codel` 队列管理（防 bufferbloat）
- `BBR` 拥塞控制（更适合有损/抖动链路）
- 扩大 socket 缓冲区（防止突发丢包）
- 扩大 conntrack 表（65536 条目）
- TCP fastopen + keepalive 优化

参数写入 `/etc/sysctl.d/99-leigod-latency.conf`，重启后自动加载。

## 可选：安装 LuCI 界面版

如果要通过路由器 Web 后台管理，使用选项 **8**（Lean IPKG 版），会额外安装 `luci-app-leigod-acc`，之后可以在 **服务 → Leigod Acc** 中操作。

> **注意**：IPK 安装会覆盖 fw4 适配补丁文件，脚本会自动重新应用补丁。安装完成后 LuCI Web 界面即可正常使用 fw4 功能：防火墙类型显示、TUN 模式推荐、自动暂停配置页。也可通过 SSH 菜单管理：`S` 查看状态、`9` 配置自动暂停。

### LuCI fw4 适配补丁

选项 1 和选项 8 安装完成后会自动应用 fw4 适配补丁（`apply_luci_fw4_patch`）：

- **防火墙类型显示** — 服务状态 API 增加 `firewall` 字段 (fw3/fw4)，状态页面显示防火墙信息
- **自动暂停页面** — 新增"自动暂停"菜单页，支持 token 配置、cron 启停、手动暂停、实时状态轮询
- **TUN 模式推荐** — fw4 下服务配置页标注 TUN 模式"强烈推荐"
- **补丁位置** — 文件写入 `/usr/lib/lua/luci/` (LuCI1 Lua 路径)

### LuCI2 (JavaScript) 迁移可行性评估

> **评估日期**: 2026-05-20 | **结论**: 暂不迁移，当前方案可满足需求

**背景**：OpenWrt 主线的 LuCI 正从服务端 Lua 渲染逐步迁移到客户端 JavaScript 渲染。Lua CBI 页面需依赖 `luci-compat` 包在新版 LuCI 上运行。

**当前方案**：
- 使用 LuCI1 Lua CBI（`/usr/lib/lua/luci/`） + `luci-compat`
- 10 个补丁文件：controller (Lua)、model/cbi (Lua)、view (HTML+JS)
- 自动暂停页面已混用 JavaScript (XHR 轮询)，为后续迁移做了铺垫

**LuCI2 迁移要点**：

| 项目 | LuCI1 (当前) | Modern LuCI (目标) |
|------|-------------|-------------------|
| 视图路径 | `/usr/lib/lua/luci/view/` | `/www/luci-static/resources/view/` |
| 控制器 | `module("luci.controller.acc")` | `ucode` RPC 脚本 (`/usr/share/rpcd/ucode/`) |
| 菜单 | `entry()` in Lua | JSON in `/usr/share/luci/menu.d/` |
| 表单 | `Map/Section/Option` Lua | `form.Map` / `E()` JavaScript |
| 数据访问 | `luci.model.uci` Lua | `uci.load()` JS / `rpc.declare()` ubus |
| 兼容层 | 需 `luci-compat` | 原生支持 |

**迁移工作量估算**：

| 文件 | 行数 | 迁移难度 | 说明 |
|------|------|---------|------|
| `controller/acc.lua` | ~330 | 高 | 需拆分为 JS view + ucode RPC + JSON ACL |
| `model/cbi/leigod/autopause.lua` | ~120 | 中 | 表单用 `form.Map` + `E()` 重写，状态轮询 JS 可复用 |
| `model/cbi/leigod/service.lua` | ~50 | 低 | 简单表单，少量字段 |
| `view/leigod/autopause.htm` | ~80 | 低 | 纯 JS 轮询逻辑，几乎可直接迁移 |
| `view/leigod/service.htm` | ~30 | 低 | 小段 JS 状态展示 |
| 其余 5 个文件 | ~200 | 低 | 上游文件，无 fw4 修改 |

**不迁移的理由**：
1. **luci-compat 在 OpenWrt 24.10 上可用且稳定** — 当前方案无兼容性风险
2. **完整的迁移需要引入 ucode** — 自 OpenWrt 24.10 起服务端 RPC 推荐 ucode 替代 Lua，学习成本高
3. **上游尚未迁移** — 雷神 LuCI 上游仍是 Lua CBI，迁移后需自行维护与上游的差异
4. **SSH 菜单是主管理方式** — LuCI 在本项目中定位为辅助可视化，SSH 菜单承担核心管理功能
5. **工作量与收益不成比例** — 迁移约需 3-5 天，但对终端用户体验改善有限

**建议迁移时机**：
- OpenWrt 彻底移除 `luci-compat` 时（目前无此计划）
- 上游 `luci-app-leigod-acc` 官方发布 JS 版本时
- 需要深度集成 LuCI2 生态特性（如 `luci-app-statistics` 图表）时

**预 adaptation 设计**：当前自动暂停页面已采用 JavaScript 轮询模式（10 秒 XHR → JSON → DOM 更新），与 LuCI2 的 `XHR.poll()` 模式一致，届时只需替换路径和包引用即可完成迁移。

## 常见问题

| 问题 | 解决方法 |
|------|---------|
| 加速不生效（最常见） | **必须先切换到 TUN 模式**（选项 5）。fv4/nftables 下 TPROXY 规则无法被正确处理。安装脚本会自动询问是否切换。 |
| 安装后无 LuCI 网页界面 | 选项 `1`（官方安装）不含 LuCI。请使用选项 `8` 安装 Lean IPKG 版 (`luci-app-leigod-acc`)。也可通过 SSH 菜单 `S` 管理。 |
| LuCI 页面空白/不显示 | 检查 `luci-compat` 是否已安装：`opkg list-installed \| grep luci-compat`。若无则 `opkg install luci-compat`。 |
| 手机 APP 发现不了设备 | 路由器后台检查 UPnP 是否已启用（服务 → UPnP） |
| 安装时防火墙误判为 fw3 | ImmortalWrt 24.10 等未安装 `firewall4` 包的固件可能被误判。v2.2.1 已修复：通过 `nft` 命令双重检测。更新脚本至最新版。 |
| 安装报错 `kmod-netem` | kernel 6.x 已内置 netem，该包不存在。v2.2.1 已自动跳过。可忽略此警告。 |
| 与 OpenClash 共存 | LeigodAcc 用 TUN 模式，OpenClash 用 Redir-Host 兼容模式 |
| 手机游戏无法加速 | 选项 7 禁用 IPv6，然后忘记 Wi-Fi 重新连接 |
| 缺少依赖包 | 选项 6 安装兼容性依赖 |
| `opkg` 锁住 | `rm /var/lock/opkg.lock` |
| fw4 防火墙重载后加速失效 | 重启 LeigodAcc 服务（选项 4 先禁用再启用，或选项 5 切换模式） |
| IPKG 版模式切换无效 | 已修复 (v2.2.1)；更新脚本后重新运行即可正常切换 TUN↔TPROXY |
| 自动暂停不生效 | 确认 account_token 已配置（选项 9 → 查看运行状态）；检查 cron 是否运行 (`logread -l 50 -f`) |

## fw3 vs fw4 包对照

| 功能 | fw3 (旧版) | fw4 (新版) |
|------|-----------|-----------|
| iptables 命令 | `iptables` | `iptables-nft` |
| NAT 内核模块 | `kmod-ipt-nat` | `kmod-nft-nat` |
| TPROXY 内核模块 | `kmod-ipt-tproxy` | `kmod-nft-tproxy` |
| TPROXY 用户态模块 | `iptables-mod-tproxy` | nftables 内置，无需安装 |
| IP 集合 | `kmod-ipt-ipset` + `ipset` | nftables 内置，无需安装 |

## 脚本改动说明

本脚本基于 [openwrt-leigodacc-manager](https://github.com/miaoermua/openwrt-leigodacc-manager) 修改（当前版本 v2.2.1），主要改动：

- 新增防火墙自动检测（fw3 / fw4）— 双检测机制（`fw4` + `nft`），覆盖 ImmortalWrt 等未安装 `firewall4` 包的 nftables 固件
- 根据防火墙类型动态选择依赖包
- 移除 fw4 不支持警告，替换为适配提示
- 新增 fw4 hotplug 防火墙集成（自动恢复被 fw4 重载清空的加速规则）
- 新增 iptables-nft 兼容层自动配置
- 新增 TPROXY 内核模块 4 级 fallback 检测
- 新增磁盘空间预检查和 opkg 错误处理
- 新增 **自动暂停时长计费**功能（菜单选项 9）
- 新增 **服务状态诊断面板**（菜单选项 S）
- 新增 **LuCI fw4 适配补丁**：安装时自动修改上游 LuCI 界面，显示 fw4 防火墙状态
- 卸载时自动清理 fw4 集成文件
- 完整保留 fw3 向后兼容
