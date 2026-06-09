# LeigodAcc Manager fw4 适配版 — 安装与使用指南

基于 [openwrt-leigodacc-manager](https://github.com/miaoermua/openwrt-leigodacc-manager) 修改，适配 OpenWrt 24.10+ fw4/nftables 防火墙。

**当前版本**: v2.4.1 (2026-06-10) — 离家模式 Bug 修复

## 前置条件

- OpenWrt / ImmortalWrt 路由器（fw3 或 fw4/nftables）
- 已联网，能访问 `webapi.leigod.com`
- 雷神加速器账号

## 快速安装（单文件）

### 1. 上传

```powershell
scp leigod-fw4.sh root@192.168.10.1:/root/
```

### 2. 安装

```bash
ssh root@192.168.10.1
chmod +x /root/leigod-fw4.sh
/root/leigod-fw4.sh
# 选 1 安装加速器
# 选 9→1 安装自动暂停（直接回车使用书签方案）
```

> **不再需要 `luci-fw4-patch/` 目录或 `auto-pause.sh`。** 全部内嵌在 `leigod-fw4.sh` 中。

### 3. 菜单操作流程

| 步骤 | 选项 | 说明 |
|------|------|------|
| 安装 | **1** | 自动安装雷神加速器（检测防火墙类型、安装依赖、部署服务） |
| 诊断 | **S** | 查看服务状态，确认所有检查通过 |
| LuCI | 浏览器 | `http://192.168.10.1/cgi-bin/luci/admin/services/acc/service` |

## 菜单说明

```
=============================
OpenWrt LeigodAcc Manager
防火墙: nftables (fw4)

1. 安装                    # 官方安装脚本
2. 卸载                    # 完整卸载（含 auto-pause）
3. 重装/更新               # 卸载 + 重装
4. 禁用/启用 雷神服务      # 开关服务（保留配置）
5. 切换运行模式             # TUN ↔ TPROXY
6. 安装兼容性依赖           # 补全缺失的 opkg 包
7. 禁用/启用 IPv6           # 手机游戏优化
8. 安装 Lean IPKG 版        # 实验性 IPK 安装
9. 自动暂停时长             # 空闲检测 + API 暂停
S. 查看服务状态             # 综合诊断
L. 延迟波动诊断             # Bufferbloat / QoS / PPPoE MSS / TURN 抖动
T. 内核网络调优             # fq_codel + BBR + conntrack 优化
H. 反馈/帮助
0. 退出
=============================
```

## 自动暂停（省时长）

### 安装

菜单选项 **9** → **1**（安装），直接回车跳过 token 配置。

### Token 获取

**方式一（推荐）— 书签一键获取**：

1. LuCI → 自动暂停页面 → 拖 `🔑 获取雷神Token` 按钮到浏览器书签栏
2. 打开 `https://www.leigod.com` → 登录
3. 点击书签 → 弹出 "Token 已保存到路由器!"
4. 每 7 天点击一次

**方式二（备选）— 浏览器 F12**：

1. 打开 `https://vip.leigod.com` → 登录
2. F12 → Console → `JSON.parse(localStorage.getItem('account_token')).account_token`
3. 复制 token → 粘贴到 LuCI 自动暂停页面的输入框 → 点"保存"

### 自定义空闲时间

| 配置项 | 默认值 | 说明 |
|--------|--------|------|
| 检测间隔 | 2 分钟 | cron 运行频率 |
| 空闲检测次数 | 3 次 | 连续空闲次数后触发 |
| **总空闲时间** | **6 分钟** | 间隔 × 次数 |

修改后保存，cron 自动更新。

### 离家模式（禁止自动暂停）

**用途：** 异地使用 PC 客户端加速时，防止路由器误判无设备而自动暂停时长计费。

| 配置项 | 默认值 | 说明 |
|--------|--------|------|
| MANUAL_DISABLE | 0 | `0`=正常自动暂停 / `1`=离家模式（禁止自动暂停） |

**操作方式：**
- **LuCI CBI 页面**：自动暂停配置页 → 勾选 "离家模式 (禁止自动暂停)" → 保存
- **手动编辑**：`echo "MANUAL_DISABLE=1" >> /etc/leigod-auto-pause.conf`
- **CLI 查看状态**：`/root/leigod-fw4.sh` → 选 `9` → 选 `3`（查看状态）→ 显示 `[模式] 离家模式` 或 `[模式] 自动模式`

**行为说明：**
- 离家模式下 cron 持续运行但不执行空闲检测，不调用暂停 API
- 首次进入离家模式写一条 syslog，后续静默（不重复刷日志）
- 空闲计数在进入离家模式时自动清零，退出后从零重新累计
- LuCI "立即暂停" 按钮在离家模式下被禁止，返回错误提示
- Debug 页面 / 自动暂停状态页面实时显示离家模式状态

**典型场景：**
1. 出门前开启离家模式 → PC 客户端异地加速不受影响
2. 回家后关闭离家模式 → 路由器恢复正常的空闲检测 + 自动暂停
3. 休假/长期外出期间开启离家模式 → 避免误暂停

### 技术说明

雷神登录 API 被 CloudWAF(418) 封锁，无法自动化登录。pause API 不受此限制，有有效 token 即可。书签方案是经过验证的物理最优方案。

### Token 策略 (v2.5)

```
单一来源: ACCOUNT_TOKEN (浏览器书签获取)
有效期 ~7 天, 过期后重新点击书签 (5秒)
配置 chmod 600, HTTPS 传输
```

## 诊断页面

浏览器访问：`http://192.168.10.1/cgi-bin/luci/admin/services/acc/debug`

**8 项分类诊断**：
- 系统信息（固件/内核/防火墙/LAN IP）
- 进程状态（PID/内存/模式/端口监听）
- Init 脚本（模式标志格式验证）
- 运行时配置（tproxy_ip + acc_mode 验证）
- 网络与防火墙（TUN/TURN/API/GAMEACC）
- 依赖包完整性
- 设备加速状态
- 自动暂停状态

**操作**：
- 点击"刷新"更新数据
- 点击"复制报告"获取纯文本诊断报告（可直接粘贴提交 bug 分析）

## 已知问题与解决方案

### 端口 5588 未监听 / web 进程崩溃

```
症状: 诊断页显示"端口 5588: No"，手机 APP 无法通信
根因: acc_core_conf.json 中 tproxy_ip 不正确 (可能为 10.20.30.40)
修复: /root/leigod-fw4.sh fix-tproxy
```

### GAMEACC 规则缺失

```
症状: 诊断页显示"GAMEACC 链: No"
说明: 正常现象。GAMEACC 规则由手机 APP 发起加速后动态注入
验证: 手机 APP 点击加速 → iptables -L GAMEACC -n
```

### acc_mode 报 "unknow acc mode:2"

```
症状: daemon 日志中出现 unknow acc mode:2
说明: 非致命冗余警告，仅在规则清理时打印，不影响加速功能
处理: 无需修复
```

### 自动暂停 token 过期

```
症状: 日志 "token 已过期 (code=400006)"
方案A: 浏览器 F12 获取新 token → 填入 LuCI
方案B: 使用 GitHub Actions (luanche/leigod-auto-pause)
```

## 内核网络调优（T 选项）

菜单选项 **T** 或 CLI `leigod-fw4.sh tune-network` 一键应用低延迟内核参数：

### 应用的参数

| 参数 | 值 | 作用 |
|------|-----|------|
| `default_qdisc` | `fq_codel` | 公平队列 + 主动队列管理，防止 WAN 口缓冲区膨胀 |
| `tcp_congestion_control` | `bbr` | Google BBR 拥塞控制，更适合有损/抖动链路 |
| `rmem_max / wmem_max` | 4MB | 防止突发流量丢包 |
| `tcp_fastopen` | 3 | 减少 TCP 连接建立 1 次往返 |
| `nf_conntrack_max` | 65536 | 扩大连接追踪表，防止"表满"丢连接 |
| `nf_conntrack_tcp_timeout_established` | 3600s | 更快释放空闲连接 |
| `tcp_keepalive_time` | 120s | 快速检测断连 |

### 持久化

配置写入 `/etc/sysctl.d/99-leigod-latency.conf`，路由器重启后自动加载，无需额外配置。

### BBR 检查

调优完成后自动验证 BBR 是否实际激活。如果内核未编译 `CONFIG_TCP_CONG_BBR=y`，会提示手动操作。

## 延迟诊断增强（L 选项 — v2.3.3 重写）

菜单选项 **L** 或打开"延迟波动诊断"，现已升级为 6 步完整诊断：

| 步骤 | 检查项 | 增强 (v2.3.3) |
|------|--------|---------------|
| 1/6 | QoS 队列管理 | 无变化 |
| 2/6 | GAMEACC 流量分析 | **iptables-nft/iptables 自动回退** |
| 3/6 | conntrack 压力 | **一键自动扩大**（使用率 > 80% 时询问） |
| 4/6 | DNS 中继延迟 | iptables 回退 |
| 5/6 | TURN 中继稳定性 | **抖动测量 (mdev)** — min/max/mdev，> 15ms 警告 |
| **6/6** | **PPPoE MTU/分片** | **全新** — TCP MSS clamping 检查 + MTU 合理性 + 一键修复 |

## 非交互式诊断（CLI）

```bash
/root/leigod-fw4.sh diagnose
```

输出纯文本报告（无 y/n 交互），适合：
- 定时 cron 监控：`0 * * * * /root/leigod-fw4.sh diagnose >> /tmp/leigod-diag.log`
- 远程排查：输出可直接粘贴提交 bug 分析

## 文件结构

```
leigod-fw4/                          (18 个文件)
├── leigod-fw4.sh                    # ★ 单文件部署 — 所有组件已内嵌
├── auto-pause.sh                    # 自动暂停脚本 v2.5 (源码参考)
├── CHANGELOG.md                     # 完整变更日志
├── UPDATE.md                        # 本文件 — 安装与使用指南
├── SESSION-LOG.md                   # 会话上下文 (新对话必读)
├── leigod-accelerator-tech-reference.md  # 技术参考
├── old/leigod-fw4-install-guide.md  # 旧安装指南 (已废弃)
└── luci-fw4-patch/                  # LuCI 源码 (参考, .sh 已内嵌)
    └── luasrc/
        ├── controller/acc.lua       (1213 行)
        ├── model/cbi/leigod/        (6 文件)
        │   ├── service.lua          — 服务配置
        │   ├── device.lua           — 设备管理
        │   ├── autopause.lua        — 自动暂停配置
        │   ├── notice.lua           — 使用须知
        │   ├── app.lua              — APP下载
        │   └── debug.lua            — 诊断页 CBI 包装器
        └── view/leigod/             (5 文件)
            ├── service.htm          — 加速状态
            ├── autopause.htm        — 自动暂停状态 + 书签UI
            ├── debug.htm            — 网络诊断报告
            ├── app.htm              — APP 信息
            └── notice.htm           — 公告内容
```

## CLI 命令

```bash
# 静默修复 tproxy_ip + acc_mode（cron 每 2 分钟自动运行）
/root/leigod-fw4.sh fix-tproxy

# 内核网络调优 — 应用 fq_codel/BBR/conntrack 等低延迟优化参数
/root/leigod-fw4.sh tune-network

# 非交互式诊断报告 — 6 段纯文本，适合 cron 作业或脚本化监控
/root/leigod-fw4.sh diagnose

# LuCI 完整性验证 — 检查 12 个文件 + luci-compat + UCI 配置，自动修复
/root/leigod-fw4.sh verify-luci

# 手动测试自动暂停（调试用）
/usr/sbin/leigod-auto-pause.sh 2>&1
```

## 版本

- **当前**: v2.4.1 (2026-06-10)
- **兼容**: OpenWrt 21.02+ / ImmortalWrt 23.05+ / fw3 (iptables) + fw4 (nftables)
- **acc-gw**: v1.2.2.13 (router.arm64) — 仅支持 TPROXY (acc_mode=2)
- **LuCI**: 全中文界面（7 个标签页均已翻译）+ 离家模式开关
- **安全**: Token 仅存储在路由器 (chmod 600), API 全程 HTTPS
- **新增**: 离家模式 — 异地加速时禁止自动暂停，防止误判
