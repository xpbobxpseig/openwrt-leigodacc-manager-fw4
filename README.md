# openwrt-leigodacc-manager-fw4

雷神加速器 OpenWrt 插件管理器 — fw4/nftables 适配版

> **基于** [miaoermua/openwrt-leigodacc-manager](https://github.com/miaoermua/openwrt-leigodacc-manager) 修改，适配 OpenWrt 24.10+ fw4/nftables 防火墙。

## 特性

- ✅ **单文件部署** — 只需 `leigod-fw4.sh`，所有组件内嵌
- ✅ **fw4/nftables 适配** — hotplug 脚本守护动态规则，iptables-nft 兼容层
- ✅ **LuCI 全中文界面** — 6 个标签页：服务配置/设备管理/自动暂停/网络诊断/使用须知/APP下载
- ✅ **自动暂停时长** — 空闲检测 + 书签一键获取 Token → 自动暂停计费
- ✅ **网络诊断** — 延迟 Ping 测试 (网关/DNS/TURN)，加速节点分析，排版对齐报告
- ✅ **tproxy_ip 守护** — cron 每 2 分钟检测并自动修复 daemon 硬编码的伪造 IP
- ✅ **自定义空闲间隔** — 1~30 分钟可调检测频率
- ✅ **兼容 fw3/fw4** — 自动检测防火墙类型，动态选择依赖包

## 快速安装

```bash
# 1. 上传
scp leigod-fw4.sh root@192.168.10.1:/root/

# 2. SSH 登录并安装
ssh root@192.168.10.1
chmod +x /root/leigod-fw4.sh
/root/leigod-fw4.sh
# 选 1 → 安装加速器
# 选 9 → 1 → 安装自动暂停
```

> **不需要** `luci-fw4-patch/` 目录或 `auto-pause.sh` 独立文件。全部内嵌。

## 菜单

```
1. 安装                    # 官方安装脚本
2. 卸载                    # 完整卸载
3. 重装/更新               # 卸载 + 重装
4. 禁用/启用 雷神服务      # 开关服务
5. 切换运行模式             # TUN/TPROXY (注意: 部分二进制仅支持 TPROXY)
6. 安装兼容性依赖           # 补全 opkg 包
7. 禁用/启用 IPv6           # 手机游戏优化
8. 安装 Lean IPKG 版        # 实验性 IPK 安装
9. 自动暂停时长             # 空闲检测 + API 暂停
S. 查看服务状态             # 综合诊断
L. 延迟波动诊断             # Bufferbloat/QoS
H. 帮助
0. 退出
```

## LuCI 界面

| 页面 | 说明 |
|------|------|
| 服务配置 | 防火墙类型、启用加速、TUN模式、定时暂停 |
| 设备管理 | DHCP/ARP 设备列表，分类设置 |
| 自动暂停 | Token 配置、空闲检测间隔、书签一键获取 |
| **网络诊断** | 系统/进程/配置/延迟/节点/日志综合报告 |
| 使用须知 | 依赖说明、桥接模式、加速模式 |
| APP下载 | APP 下载链接 + 绑定教程 |

## 自动暂停

### Token 获取

**方式一（推荐）**：LuCI → 自动暂停 → 拖书签到浏览器 → 打开 leigod.com → 点击书签

**方式二（备选）**：浏览器 F12 → `JSON.parse(localStorage.getItem('account_token')).account_token` → 粘贴到 LuCI

### 空闲检测

```
总空闲时间 = 检测间隔 × 检测次数
默认: 2分钟 × 3次 = 6分钟
```

可自定义间隔 (1~30 分钟) 和次数 (1~30 次)。

## 技术说明

### 关于登录 API

雷神登录 API (`/wap/login/bind/v1`) 被 CloudWAF(418) 封锁，从所有网络来源（家庭宽带/Cloudflare/GitHub Actions/服务器）均不可自动化访问。pause API (`/api/user/pause`) 无此限制，有有效 Token 即可。详见 [SESSION-LOG.md](SESSION-LOG.md)。

### 关于 acc_mode

经实测，部分 acc-gw 二进制版本 (v1.2.2.13 router.arm64) 仅支持 `acc_mode=2` (TPROXY)。`fix_acc_core_conf()` 会自动检测并修正。

### 文件结构

```
openwrt-leigodacc-manager-fw4/
├── leigod-fw4.sh                    # ★ 主脚本（单文件部署）
├── auto-pause.sh                    # 自动暂停脚本 v2.5
├── README.md                        # 本文件
├── CHANGELOG.md                     # 完整变更日志
├── UPDATE.md                        # 安装与使用指南
├── SESSION-LOG.md                   # 会话上下文记录
├── leigod-accelerator-tech-reference.md  # 技术参考
└── luci-fw4-patch/                  # LuCI 补丁源码
    └── luasrc/
        ├── controller/acc.lua
        ├── model/cbi/leigod/        (6 文件)
        └── view/leigod/             (5 文件)
```

## 已知问题

| 问题 | 影响 | 缓解 |
|------|------|------|
| token 有效期 ≈7 天 | 自动暂停到期失效 | 书签 5 秒手动刷新 |
| 部分 acc-gw 仅支持 TPROXY | 不能切 TUN 模式 | `fix_acc_core_conf` 强制 mode=2 |
| 登录 API CloudWAF 封锁 | 无法自动化获取 token | 浏览器书签 |
| daemon 不写 UCI state | 设备状态从 JSON 读取 | 已实现 JSON 解析 |

## 引用与致谢

- **原始项目**: [miaoermua/openwrt-leigodacc-manager](https://github.com/miaoermua/openwrt-leigodacc-manager)
- **登录签名算法参考**: [luanche/leigod-auto-pause](https://github.com/luanche/leigod-auto-pause)
- **雷神 API 参考**: [jiajiaxd/leigod-api](https://github.com/jiajiaxd/leigod-api)

> **AI 生成声明**: 本项目的代码修改、文档编写和问题诊断由 DeepSeek AI 辅助完成。所有修改均在人工审查和验证后合入。

## License

本项目基于原始项目 [miaoermua/openwrt-leigodacc-manager](https://github.com/miaoermua/openwrt-leigodacc-manager) 的许可证。
