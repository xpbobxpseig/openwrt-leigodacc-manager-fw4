#!/bin/sh

# ============================================================
# OpenWrt LeigodAcc Manager - fw4/nftables adapted version
# 版本: v2.5.2 (2026-08-15)
# 变更: device.lua Lua5.1兼容修复(goto→if嵌套, 修设备页Runtime error) + .gitattributes LF行尾(防CRLF致shebang失效)
# 项目: https://github.com/xxx/openwrt-leigodacc-manager-fw4
# 基于: miaoermua/openwrt-leigodacc-manager
# AI 辅助: DeepSeek AI 生成和修改
# 适配 OpenWrt 24.10+ fw4 防火墙
# ============================================================

# Check ROOT & OpenWrt
if [ "$(id -u)" != "0" ]; then
    echo "Error: You must be root to run this script, please use root user"
    exit 1
fi

# Prevent Xiaomi Routers and Qunou Routers from running openwrt-leigodacc-manager
if [ -e /etc/asus_release ]; then
    echo "TONY 别肘! 我爱 BCM!"
    echo ""
    echo "[ERROR] 检测到 ASUS 路由器，无法运行 OpenWrt LeigodAcc 管理器，你不是 OpenWrt 系统!"

    if [ ! -d /jffs/softcenter ]; then
        echo "[INFO] 检测到官改 or Koolcenter 版本，即将脱离 OpenWrt 管理器运行官方脚本开始安装."
        echo "[INFO] 以下内容均与 OpenWrt 管理器作者无关，本人并无华硕路由器 Debug!"
        echo
        sleep 5
        cd /tmp || { echo "[ERROR] 无法切换到 /tmp 目录"; exit 1; }
        sh -c "$(curl -fsSL https://119.3.40.126/router_plugin_new/plugin_install.sh 2>/dev/null || curl -fsSL http://119.3.40.126/router_plugin_new/plugin_install.sh)"
    fi
    exit 0
fi

if [ -d /userdisk/appdata ]; then
    echo "R u OK?"
    echo ""
    echo "[ERROR] 检测到小米路由器，无法运行 OpenWrt LeigodAcc 管理器，你不是 OpenWrt 系统!"
    name=$(uci get misc.hardware.displayName 2>/dev/null)
    if [ "$?" != "0" ] || [ -z "$name" ]; then
        name=$(uci get misc.hardware.model 2>/dev/null)
    fi
    if [ -n "$name" ]; then
        echo "[INFO] 小米路由器: ${name}"
        sleep 5
        echo "[INFO] 检测到小米已经解锁了 SSH，即将脱离 OpenWrt 管理器运行官方脚本开始安装."
        echo "[INFO] 以下内容均与 OpenWrt 管理器作者无关，本人并无小米路由器 Debug!"
        echo
        cd /tmp || { echo "[ERROR] 无法切换到 /tmp 目录"; exit 1; }
        sh -c "$(curl -fsSL https://119.3.40.126/router_plugin_new/plugin_install.sh 2>/dev/null || curl -fsSL http://119.3.40.126/router_plugin_new/plugin_install.sh)"
        exit 0
    fi
fi

if ! grep -qi -E "OpenWrt|LEDE|QWRT|ImmortalWrt|iStoreOS" /etc/openwrt_release; then
    echo "Your system is not supported!"
    echo "[INFO]你的系统可能无法运行 OpenWrt Leigodacc 插件!"
    echo "当前系统环境并非常见或标准的 OpenWrt，可能是论坛版本修改发行版文件导致无法识别"
    echo "可能导致无法正常支持全部依赖，部分组件可能无法正常启用导致加速问题"
    echo "你可以无视风险继续安装，5s 后将进入管理器菜单，详情参考管理器发布于博客信息"
    echo
    sleep 5
fi

# ============================================================
# Firewall detection: fw3 (iptables) vs fw4 (nftables)
# ============================================================
detect_firewall() {
    # Multi-layered detection: some OpenWrt 24.10 derivatives (ImmortalWrt etc.)
    # use nftables as the firewall backend but don't install the firewall4
    # package by default. We check for the nft userspace tool as a more
    # reliable indicator of the underlying nftables subsystem.
    if [ -x /usr/sbin/fw4 ] || [ -x /usr/sbin/nft ]; then
        FW_TYPE="fw4"
        FW_NAME="nftables (fw4)"
        echo ""
        echo "[INFO] 检测到 fw4/nftables 防火墙 - OpenWrt 24.10+ 适配版"
        echo "[INFO] 将使用 nftables 兼容模式安装依赖"
        echo ""
        sleep 1
    else
        FW_TYPE="fw3"
        FW_NAME="iptables (fw3)"
        echo "[INFO] 检测到 fw3/iptables 防火墙，使用传统模式"
    fi
}

# Set package lists based on firewall type
set_fw_packages() {
    if [ "$FW_TYPE" = "fw4" ]; then
        # fw4/nftables packages
        PKG_IPTABLES="iptables-nft"
        PKG_NAT="kmod-nft-nat"
        PKG_TPROXY=""          # handled separately via ensure_fw4_tproxy()
        PKG_IPSET=""           # nftables has built-in set support
        PKG_IPSET_TOOL=""      # nftables uses nft sets natively
        PKG_IPT_TPROXY_MOD=""  # not needed for nftables
    else
        # fw3/iptables packages (original)
        PKG_IPTABLES="iptables"
        PKG_NAT="kmod-ipt-nat"
        PKG_TPROXY="kmod-ipt-tproxy"
        PKG_IPSET="kmod-ipt-ipset"
        PKG_IPSET_TOOL="ipset"
        PKG_IPT_TPROXY_MOD="iptables-mod-tproxy"
    fi
}

# fw4: install kmod-nft-tproxy with fallback checks.
# On some OpenWrt 24.10 builds, the nft_tproxy module may be built into
# the kernel (CONFIG_NFT_TPROXY=y) rather than shipped as a separate kmod.
ensure_fw4_tproxy() {
    if [ "$FW_TYPE" != "fw4" ]; then
        return 0
    fi

    echo "[INFO] 检查 nftables TPROXY 支持..."

    # Already loaded? Nothing to do.
    if lsmod 2>/dev/null | grep -q "nft_tproxy"; then
        echo "[INFO] nft_tproxy 模块已加载"
        return 0
    fi

    # Try loading the module directly (maybe it's already installed)
    if modprobe nft_tproxy 2>/dev/null; then
        echo "[INFO] nft_tproxy 模块加载成功"
        return 0
    fi

    # Try installing the kmod package
    if opkg list 2>/dev/null | grep -q "^kmod-nft-tproxy"; then
        echo "[INFO] 正在安装 kmod-nft-tproxy..."
        if opkg install kmod-nft-tproxy 2>/dev/null; then
            modprobe nft_tproxy 2>/dev/null
            echo "[INFO] kmod-nft-tproxy 安装成功"
            return 0
        fi
    fi

    # Check if TPROXY is built into the kernel
    if [ -f /proc/config.gz ] && zcat /proc/config.gz 2>/dev/null | grep -q "CONFIG_NFT_TPROXY=y"; then
        echo "[INFO] nft_tproxy 已编译进内核 (CONFIG_NFT_TPROXY=y)"
        return 0
    fi

    # Nothing worked — TPROXY is unavailable
    echo "[WARN] nftables TPROXY 不可用 (kmod-nft-tproxy 未找到且未编译进内核)"
    echo "[WARN] TPROXY 不可用。注意: 此 acc-gw 版本可能仅支持 TPROXY，加速将无法工作"
    echo "[INFO] 请运行选项 S 诊断确认 tproxy_ip 配置是否正确"
    return 1
}

# Check available disk space before installation (>10MB free on /).
# OpenWrt devices often have limited flash (128-256MB).
check_disk_space() {
    free_kb=$(df / 2>/dev/null | awk 'NR==2 {print $4}')
    if [ -z "$free_kb" ]; then
        echo "[WARN] 无法检测磁盘空间，继续安装..."
        return 0
    fi
    if [ "$free_kb" -lt 10240 ]; then
        echo "[ERROR] 磁盘空间不足! 可用: $((free_kb / 1024))MB, 需要至少 10MB"
        echo "[ERROR] 请到 系统→软件包 中卸载不用的包或扩容后重试"
        return 1
    fi
    echo "[INFO] 磁盘空间: $((free_kb / 1024))MB 可用"
    return 0
}

# Check network connectivity before attempting opkg update or downloads.
# Returns 0 if reachable, 1 if not.
# Uses multiple geographically diverse hosts to avoid regional false negatives.
check_network() {
    # Global CDN (works worldwide)
    if curl -sL --connect-timeout 3 -o /dev/null https://httpbin.org/ip 2>/dev/null; then
        return 0
    fi
    # Fallback: China mirror (for users in China)
    if curl -sL --connect-timeout 3 -o /dev/null https://mirrors.pku.edu.cn 2>/dev/null; then
        return 0
    fi
    # Final fallback: any reachable
    if curl -sL --connect-timeout 3 -o /dev/null https://cloudflare.com 2>/dev/null; then
        return 0
    fi
    echo "[WARN] 网络不可达，后续操作可能失败"
    return 1
}

# Wrapper for opkg install that checks return codes.
# Accumulates failed packages in $OPKG_FAILED for caller inspection.
OPKG_FAILED=""
safe_opkg_install() {
    for pkg in "$@"; do
        echo "[INFO] 安装 $pkg ..."
        if opkg install "$pkg"; then
            :
        else
            echo "[ERROR] 安装失败: $pkg"
            OPKG_FAILED="$OPKG_FAILED $pkg"
        fi
    done
}

# Check if netem (network emulation / QoS) is already available in the kernel.
# On kernel 6.x, CONFIG_NET_SCH_NETEM is often built-in rather than a module,
# so the kmod-netem package may not exist.
# Returns 0 if netem is available (or if the package doesn't exist at all).
has_netem() {
    lsmod 2>/dev/null | grep -q sch_netem && return 0
    zcat /proc/config.gz 2>/dev/null | grep -q 'CONFIG_NET_SCH_NETEM=y' && return 0
    # If the package doesn't exist in the repo, skip it gracefully
    opkg list kmod-netem 2>/dev/null | grep -q "^kmod-netem " || return 0
    return 1
}

# Get the essential packages list for the current firewall
get_essential_packages() {
    local pkgs="libpcap $PKG_IPTABLES $PKG_NAT $PKG_TPROXY"
    [ -n "$PKG_IPT_TPROXY_MOD" ] && pkgs="$pkgs $PKG_IPT_TPROXY_MOD"
    [ -n "$PKG_IPSET" ] && pkgs="$pkgs $PKG_IPSET"
    [ -n "$PKG_IPSET_TOOL" ] && pkgs="$pkgs $PKG_IPSET_TOOL"
    echo "$pkgs"
}

# Get the optional packages list for the current firewall
get_optional_packages() {
    local pkgs="kmod-tun $PKG_TPROXY tc-full conntrack"
    # kmod-netem may not exist on kernel 6.x — netem is built into the kernel
    has_netem || pkgs="$pkgs kmod-netem"
    [ -n "$PKG_IPSET" ] && pkgs="$pkgs $PKG_IPSET"
    echo "$pkgs"
}

# Get the full check list for the current firewall
get_check_packages() {
    local pkgs="kmod-tun $PKG_TPROXY tc-full"
    has_netem || pkgs="$pkgs kmod-netem"
    [ -n "$PKG_IPSET" ] && pkgs="$pkgs $PKG_IPSET"
    pkgs="$pkgs conntrack curl libpcap $PKG_IPTABLES $PKG_NAT"
    [ -n "$PKG_IPT_TPROXY_MOD" ] && pkgs="$pkgs $PKG_IPT_TPROXY_MOD"
    [ -n "$PKG_IPSET_TOOL" ] && pkgs="$pkgs $PKG_IPSET_TOOL"
    echo "$pkgs"
}

# ============================================================
# fw4 firewall integration
# ============================================================
setup_fw4_integration() {
    if [ "$FW_TYPE" != "fw4" ]; then
        return 0
    fi

    echo "[INFO] 配置 fw4/nftables 防火墙集成..."

    # Create firewall hotplug script to restore LeigodAcc rules
    # after fw4 reload (which flushes the entire nftables ruleset).
    # When LeigodAcc runs in TPROXY mode, acc-gw injects rules via
    # iptables-nft at runtime. These are lost on fw4 reload, so we
    # restart the service to re-inject them.
    # TUN mode is unaffected by fw4 reloads and is the recommended
    # mode for fw4 systems.
    mkdir -p /etc/hotplug.d/firewall
    cat > /etc/hotplug.d/firewall/99-leigodacc-restart << 'HOTPLUGEOF'
#!/bin/sh
# LeigodAcc - restart after fw4 reload to restore dynamic rules

[ "$ACTION" = "reload" ] || exit 0
[ -x /etc/init.d/acc ] || exit 0

# Restart if the service was running (fw4 reload clears dynamic iptables-nft rules)
if /etc/init.d/acc running >/dev/null 2>&1 || ps | grep -q "[a]cc-gw"; then
    # Debounce: skip if recently restarted (within 30s)
    last_restart=$(cat /tmp/leigod-hotplug-restart.ts 2>/dev/null)
    now=$(date +%s)
    if [ -n "$last_restart" ] && [ $((now - last_restart)) -lt 30 ]; then
        exit 0
    fi
    echo "$now" > /tmp/leigod-hotplug-restart.ts
    logger -t leigodacc "fw4 reload detected, re-injecting rules..."
    /etc/init.d/acc restart >/dev/null 2>&1 &
fi
HOTPLUGEOF
    chmod +x /etc/hotplug.d/firewall/99-leigodacc-restart

    # Add firewall rule to allow phone app → acc-gw API (TCP 5588).
    # On fw4 the default ruleset may drop LAN→router traffic on non-standard
    # ports, which blocks the phone from sending acceleration commands.
    if ! grep -q "LeigodAcc" /etc/config/firewall 2>/dev/null; then
        uci add firewall rule
        uci set firewall.@rule[-1].name='LeigodAcc'
        uci set firewall.@rule[-1].src='lan'
        uci set firewall.@rule[-1].dest_port='5588'
        uci set firewall.@rule[-1].proto='tcp'
        uci set firewall.@rule[-1].target='ACCEPT'
        uci commit firewall
        /etc/init.d/firewall restart >/dev/null 2>&1
        echo "[INFO] 已添加防火墙规则：允许 LAN 访问 acc-gw API (TCP 5588)"
    fi

    echo "[INFO] fw4 防火墙集成配置完成"
    echo "[INFO] 已安装 fw4 热插拔脚本: /etc/hotplug.d/firewall/99-leigodacc-restart"
    echo "[INFO] fw4 重载防火墙后会自动恢复 LeigodAcc 规则"
}

# On fw4, ensure iptables → iptables-nft symlinks exist so the LeigodAcc
# binary's iptables calls are transparently translated to nftables.
setup_iptables_nft_compat() {
    if [ "$FW_TYPE" != "fw4" ]; then
        return 0
    fi
    if [ ! -x /usr/sbin/iptables ]; then
        if [ -x /usr/sbin/iptables-nft ]; then
            ln -sf /usr/sbin/iptables-nft /usr/sbin/iptables 2>/dev/null
            ln -sf /usr/sbin/iptables-nft-restore /usr/sbin/iptables-restore 2>/dev/null
            ln -sf /usr/sbin/iptables-nft-save /usr/sbin/iptables-save 2>/dev/null
            echo "[INFO] 已配置 iptables-nft 兼容层"
        else
            echo "[WARN] iptables-nft 未安装，跳过兼容层配置"
        fi
    fi
}

# Apply fw4 compatibility patches to the installed LuCI interface.
# The upstream luci-app-leigod-acc was written for fw3/iptables.
# This replaces key Lua/HTML files with fw4-aware versions.
apply_luci_fw4_patch() {
    if [ "$FW_TYPE" != "fw4" ]; then
        return 0
    fi

    local luci_src="/usr/lib/lua/luci"
    local patch_dir=""

    # Locate patch files: check script dir, CWD, common paths
    script_dir=$(cd "$(dirname "$0")" && pwd 2>/dev/null || dirname "$0")
    for d in "$script_dir/luci-fw4-patch" "./luci-fw4-patch" \
             "/tmp/luci-fw4-patch" "/tmp/leigod-fw4/luci-fw4-patch" \
             "$HOME/leigod-fw4/luci-fw4-patch" "/root/leigod-fw4/luci-fw4-patch"; do
        [ -d "$d/luasrc" ] && patch_dir="$d" && break
    done

    if [ -z "$patch_dir" ]; then
        # Patch files bundled inline — write them directly
        echo "[INFO] 正在应用 LuCI fw4 适配补丁..."

        # controller/acc.lua
        mkdir -p "$luci_src/controller"
        cat > "$luci_src/controller/acc.lua" << 'LUAEOF'
module("luci.controller.acc", package.seeall)

function index()
  entry({ "admin", "services", "acc" }, alias("admin", "services", "acc", "service"), "雷神加速器", 50)
  entry({ "admin", "services", "acc", "service" }, cbi("leigod/service"), "服务配置", 30)
  entry({ "admin", "services", "acc", "device" }, cbi("leigod/device"), "设备管理", 50)
  entry({ "admin", "services", "acc", "app" }, cbi("leigod/app"), "APP下载", 60)
  entry({ "admin", "services", "acc", "notice" }, cbi("leigod/notice"), "使用须知", 80)
  entry({ "admin", "services", "acc", "autopause" }, cbi("leigod/autopause"), "自动暂停", 70)
  entry({ "admin", "services", "acc", "debug" }, cbi("leigod/debug"), "网络诊断", 90)
  entry({ "admin", "services", "acc", "status" }, call("get_acc_status")).leaf = true
  entry({ "admin", "services", "acc", "start_acc_service" }, call("start_acc_service"))
  entry({ "admin", "services", "acc", "stop_acc_service" }, call("stop_acc_service"))
  entry({ "admin", "services", "acc", "schedule_pause" }, call("schedule_pause"))
  entry({ "admin", "services", "acc", "ap_status" }, call("get_autopause_status")).leaf = true
  entry({ "admin", "services", "acc", "ap_save" }, call("save_autopause_config"))
  entry({ "admin", "services", "acc", "ap_trigger" }, call("trigger_autopause"))
  entry({ "admin", "services", "acc", "ap_toggle" }, call("toggle_autopause_cron"))
  entry({ "admin", "services", "acc", "debug_status" }, call("get_debug_status")).leaf = true
  entry({ "admin", "services", "acc", "debug_report" }, call("get_debug_report")).leaf = true
  entry({ "admin", "services", "acc", "save_token" }, call("save_token")).leaf = true
end

-- get_acc_status get acc status (fw4 adapted)
-- Reads device acceleration state from acc_core_conf.json (daemon writes
-- state here, NOT to UCI). Falls back to UCI for backward compat.
function get_acc_status()
  local util      = require "luci.util"
  local uci       = require "luci.model.uci".cursor()
  local fs        = require "nixio.fs"
  local resp      = {}
  resp.service    = "已停止"
  resp.state      = {}

  if fs.access("/usr/sbin/fw4") or fs.access("/usr/sbin/nft") then
    resp.firewall = "nftables (fw4)"
  else
    resp.firewall = "iptables (fw3)"
  end

  local exist = util.exec("ps | grep acc-gw | grep -v grep")
  if exist ~= "" then resp.service = "已启用" end

  -- Initialize all categories to "无"
  for _, typ in pairs({ "手机", "电脑", "游戏主机", "未知设备" }) do
    resp.state[typ] = "无"
  end

  -- Parse acc_core_conf.json for live acceleration state
  -- Daemon writes state in nested JSON: "PC":{"...","state":1,...}
  -- Lua [^{] breaks on nested { so use a two-pass approach:
  -- 1. Find all category keys (Phone/PC/Game/Unknown) at top level
  -- 2. Search for "state":N near each category
  local json_raw = ""
  if fs.access("/tmp/acc/acc_core_conf.json") then
    for line in io.lines("/tmp/acc/acc_core_conf.json") do json_raw = json_raw .. line end

    -- Map device_type to label: 1-3=Game, 4-6=PC, 7-8=Phone, 20-21=VR, other=Unknown
    local dt_label = { [0]="未知设备", [1]="游戏主机", [2]="游戏主机", [3]="游戏主机",
                       [4]="电脑", [5]="电脑", [6]="电脑",
                       [7]="手机", [8]="手机",
                       [20]="VR设备", [21]="VR设备", [22]="未知设备" }

    -- Find category key position, then search for "state":N after it
    -- This avoids .- getting confused by nested/escaped JSON
    local cat_label = { Phone="手机", PC="电脑", Game="游戏主机", Unknown="未知设备" }
    for _, cat in ipairs({"Phone","PC","Game","Unknown"}) do
      local pos = json_raw:find('"'..cat..'":')
      if pos then
        local after = json_raw:sub(pos)
        local st = after:match('"state":(%d+)')
        if st then
          local label = cat_label[cat] or cat
          local st_num = tonumber(st)
          if st_num == 1 then resp.state[label] = "加速中"
          elseif st_num == 2 then resp.state[label] = "已停止"
          elseif st_num == 3 then resp.state[label] = "已暂停" end
        end
      end
    end
  end

  resp.hotplug = fs.access("/etc/hotplug.d/firewall/99-leigodacc-restart") and "installed" or "not_installed"
  luci.http.prepare_content("application/json")
  luci.http.write_json(resp)
end

-- start_acc_service
function start_acc_service()
  local util = require "luci.util"
  util.exec("/etc/init.d/acc enable")
  util.exec("/etc/init.d/acc restart")
  luci.http.prepare_content("application/json")
  luci.http.write_json({ result = "OK" })
end

-- stop_acc_service
function stop_acc_service()
  local util = require "luci.util"
  util.exec("/etc/init.d/acc stop")
  util.exec("/etc/init.d/acc disable")
  luci.http.prepare_content("application/json")
  luci.http.write_json({ result = "OK" })
end

-- schedule_pause
function schedule_pause()
  local util = require "luci.util"
  local uci = require "luci.model.uci".cursor()
  local schedule_enabled = uci:get("accelerator", "system", "schedule_enabled") or "0"
  local pause_time = uci:get("accelerator", "system", "pause_time") or "01:00"
  local username = uci:get("accelerator", "system", "username") or ""
  local password = uci:get("accelerator", "system", "password") or ""
  util.exec("sed -i '/\\/usr\\/sbin\\/leigod\\/leigod-helper.sh/d' /etc/crontabs/root")
  if schedule_enabled == "1" then
    local hour, minute = pause_time:match("(%d+):(%d+)")
    local safe_username = username:gsub("'", "'\\''")
    local safe_password = password:gsub("'", "'\\''")
    local cron_time = string.format("%s %s * * * USERNAME='%s' PASSWORD='%s' /usr/sbin/leigod/leigod-helper.sh", tonumber(minute), tonumber(hour), safe_username, safe_password)
    util.exec("echo '" .. cron_time .. "' >> /etc/crontabs/root")
    util.exec("/etc/init.d/cron restart")
  end
  luci.http.prepare_content("application/json")
  luci.http.write_json({ result = "OK" })
end

-- ============================================================
-- Auto-Pause API endpoints (fw4 adapted)
-- ============================================================

local AP_CONF = "/etc/leigod-auto-pause.conf"
local AP_STATE = "/tmp/leigod-auto-pause.state"
local AP_CRON = "/etc/crontabs/root"
local AP_SCRIPT = "/usr/sbin/leigod-auto-pause.sh"

-- Read auto-pause config file, return table
local function read_ap_conf()
  local fs = require "nixio.fs"
  local conf = {}
  if not fs.access(AP_CONF) then
    return conf
  end
  for line in io.lines(AP_CONF) do
    local key, val = line:match("^([A-Z_]+)='(.*)'$")
    if key and val then
      conf[key] = val
    elseif line:match("^IDLE_CHECKS_BEFORE_PAUSE=(%d+)") then
      conf["IDLE_CHECKS_BEFORE_PAUSE"] = line:match("=(%d+)")
    elseif line:match("^API_TIMEOUT=(%d+)") then
      conf["API_TIMEOUT"] = line:match("=(%d+)")
    elseif line:match("^NOTIFY_ON_PAUSE=(%d+)") then
      conf["NOTIFY_ON_PAUSE"] = line:match("=(%d+)")
    elseif line:match("^MANUAL_DISABLE=(%d+)") then
      conf["MANUAL_DISABLE"] = line:match("=(%d+)")
    end
  end
  return conf
end

-- Read auto-pause state file
local function read_ap_state()
  local fs = require "nixio.fs"
  local state = { idle_count = "0", last_pause_epoch = "0" }
  if not fs.access(AP_STATE) then
    return state
  end
  for line in io.lines(AP_STATE) do
    local key, val = line:match("^([a-z_]+)=(%d+)$")
    if key and val then
      state[key] = val
    end
  end
  return state
end

-- Mask token: show first 8 + last 4 characters
local function mask_token(token)
  if not token or #token <= 12 then
    return token and string.rep("*", #token) or "(not set)"
  end
  return token:sub(1, 8) .. "..." .. token:sub(-4)
end

-- get_autopause_status — AJAX polling endpoint
function get_autopause_status()
  local util = require "luci.util"
  local fs   = require "nixio.fs"

  local resp = {}
  local conf = read_ap_conf()

  -- Token status
  resp.token_configured = conf["ACCOUNT_TOKEN"] ~= nil and conf["ACCOUNT_TOKEN"] ~= ""
  resp.token_masked = mask_token(conf["ACCOUNT_TOKEN"])

  -- Config values
  resp.idle_checks = conf["IDLE_CHECKS_BEFORE_PAUSE"] or "3"
  resp.api_timeout  = conf["API_TIMEOUT"] or "10"
  resp.manual_disable = conf["MANUAL_DISABLE"] or "0"

  -- Cron status
  local cron_enabled = false
  if fs.access(AP_CRON) then
    for line in io.lines(AP_CRON) do
      if line:match("leigod%-auto%-pause") then
        cron_enabled = true
        break
      end
    end
  end
  resp.cron_enabled = cron_enabled

  -- Runtime state
  local state = read_ap_state()
  resp.idle_count = state["idle_count"] or "0"
  resp.last_pause_epoch = state["last_pause_epoch"] or "0"

  -- Format last pause time
  if tonumber(resp.last_pause_epoch) > 0 then
    local now = tonumber(os.date("%s"))
    local ago = now - tonumber(resp.last_pause_epoch)
    if ago < 60 then
      resp.last_pause_text = "just now"
    elseif ago < 3600 then
      resp.last_pause_text = string.format("%d min ago", math.floor(ago / 60))
    else
      resp.last_pause_text = string.format("%d hr ago", math.floor(ago / 3600))
    end
  else
    resp.last_pause_text = "never"
  end

  -- Script exists
  resp.script_installed = fs.access(AP_SCRIPT)

  -- Is potentially already paused (API cooldown active)
  if tonumber(state["last_pause_epoch"] or 0) > 0 then
    local now = tonumber(os.date("%s"))
    resp.in_cooldown = (now - tonumber(state["last_pause_epoch"])) < 600
  else
    resp.in_cooldown = false
  end

  luci.http.prepare_content("application/json")
  luci.http.write_json(resp)
end

-- save_autopause_config — partial-update handler.
-- Only fields explicitly passed in the request are updated;
-- all others are preserved from the existing config file.
function save_autopause_config()
  local util = require "luci.util"
  local conf = read_ap_conf()

  -- Read request values, fall back to existing config
  local token = luci.http.formvalue("account_token")
  if not token or token == "" or token:match("^%*+$") then
    token = conf["ACCOUNT_TOKEN"]  -- preserve existing
  else
    token = token:gsub("[^a-zA-Z0-9_-]", "")  -- sanitize (prevent config breakage)
  end
  local idle_checks = luci.http.formvalue("idle_checks") or conf["IDLE_CHECKS_BEFORE_PAUSE"] or "3"
  local api_timeout = luci.http.formvalue("api_timeout") or conf["API_TIMEOUT"] or "10"
  local notify = luci.http.formvalue("notify_on_pause") or conf["NOTIFY_ON_PAUSE"] or "1"
  local manual_disable = luci.http.formvalue("manual_disable")
  if manual_disable == nil or manual_disable == "" then
    manual_disable = conf["MANUAL_DISABLE"] or "0"
  end

  local file = io.open(AP_CONF, "w")
  if not file then
    luci.http.prepare_content("application/json")
    luci.http.write_json({ result = "ERROR", message = "Cannot write config file" })
    return
  end

  file:write("# LeigodAcc Auto-Pause configuration\n")
  if token and token ~= "" then
    file:write(string.format("ACCOUNT_TOKEN='%s'\n", token))
  end
  file:write(string.format("IDLE_CHECKS_BEFORE_PAUSE=%d\n", tonumber(idle_checks) or 3))
  file:write(string.format("API_TIMEOUT=%d\n", tonumber(api_timeout) or 10))
  file:write(string.format("API_ENDPOINT=\"https://webapi.leigod.com\"\n"))
  file:write(string.format("NOTIFY_ON_PAUSE=%d\n", tonumber(notify) or 1))
  file:write(string.format("MANUAL_DISABLE=%d\n", tonumber(manual_disable) or 0))
  file:close()

  util.exec(string.format("chmod 600 %s", AP_CONF))
  luci.http.prepare_content("application/json")
  luci.http.write_json({ result = "OK" })
end

-- trigger_autopause — manual pause trigger
function trigger_autopause()
  local util = require "luci.util"
  local fs   = require "nixio.fs"

  if not fs.access(AP_SCRIPT) then
    luci.http.prepare_content("application/json")
    luci.http.write_json({ result = "ERROR", message = "auto-pause.sh not installed" })
    return
  end

  -- Respect manual disable (away mode)
  local conf = read_ap_conf()
  if conf["MANUAL_DISABLE"] == "1" then
    luci.http.prepare_content("application/json")
    luci.http.write_json({ result = "ERROR", message = "离家模式已启用, 手动暂停被禁止" })
    return
  end

  local token = ""
  if conf["ACCOUNT_TOKEN"] then
    token = conf["ACCOUNT_TOKEN"]
  end

  if token == "" then
    luci.http.prepare_content("application/json")
    luci.http.write_json({ result = "ERROR", message = "account_token not configured" })
    return
  end

  -- Send a direct pause API call (same as auto-pause.sh does)
  local safe_token = token:gsub("\\", "\\\\"):gsub('"', '\\"'):gsub("'", "'\\''")
  local cmd = string.format(
    "curl -sL --connect-timeout 10 -X POST 'https://webapi.leigod.com/api/user/pause' " ..
    "-H 'Content-Type: application/json' " ..
    "-H 'User-Agent: LeigodAcc-AutoPause/1.0' " ..
    "-d '{\"account_token\":\"%s\",\"lang\":\"zh_CN\"}'", safe_token)
  local resp_body = util.exec(cmd)
  local code = resp_body:match('"code":%s*(%d+)')

  if code == "0" then
    -- Record pause timestamp via Lua I/O (echo '\n' is literal on BusyBox)
    local now = os.date("%s")
    local sf = io.open(AP_STATE, "w")
    if sf then
      sf:write("idle_count=0\n")
      sf:write("last_pause_epoch=" .. now .. "\n")
      sf:close()
    end
    luci.http.prepare_content("application/json")
    luci.http.write_json({ result = "OK", message = "Pause successful" })
  elseif code == "400803" then
    luci.http.prepare_content("application/json")
    luci.http.write_json({ result = "OK", message = "Already paused" })
  else
    luci.http.prepare_content("application/json")
    luci.http.write_json({ result = "ERROR", message = "API returned code: " .. (code or "nil") })
  end
end

-- toggle_autopause_cron — enable/disable the cron job
function toggle_autopause_cron()
  local util = require "luci.util"
  local fs   = require "nixio.fs"
  local enable = luci.http.formvalue("enable")

  if not fs.access(AP_SCRIPT) then
    luci.http.prepare_content("application/json")
    luci.http.write_json({ result = "ERROR", message = "auto-pause.sh not installed" })
    return
  end

  if enable == "1" then
    -- Add cron if not present
    if fs.access(AP_CRON) then
      local has_cron = false
      for line in io.lines(AP_CRON) do
        if line:match("leigod%-auto%-pause") then has_cron = true; break end
      end
      if not has_cron then
        local f = io.open(AP_CRON, "a")
        if f then
          f:write(string.format("*/2 * * * * %s >> /tmp/leigod-auto-pause.log 2>&1\n", AP_SCRIPT))
          f:close()
        end
        util.exec("/etc/init.d/cron restart 2>/dev/null")
      end
    end
  else
    -- Remove cron
    util.exec(string.format("sed -i '/leigod-auto-pause/d' %s", AP_CRON))
    util.exec("/etc/init.d/cron restart 2>/dev/null")
  end

  luci.http.prepare_content("application/json")
  luci.http.write_json({ result = "OK" })
end

-- ============================================================
-- Diagnostic debug endpoint (fw4 adapted)
-- Collects system state and automatically flags issues.
-- ============================================================
function get_debug_status()
  local util  = require "luci.util"
  local uci   = require "luci.model.uci".cursor()
  local fs    = require "nixio.fs"

  local resp = {
    system         = {},
    process        = {},
    init_script    = {},
    network        = {},
    packages       = {},
    devices        = {},
    autopause      = {},
    logs           = {},
    issues         = {},
    checks_passed  = 0,
    checks_total   = 0,
    checks_failed  = 0,
    checks_warn    = 0
  }

  local function check(name, ok, level)
    level = level or "error"
    resp.checks_total = resp.checks_total + 1
    if ok then
      resp.checks_passed = resp.checks_passed + 1
    else
      if level == "error" then
        resp.checks_failed = resp.checks_failed + 1
      else
        resp.checks_warn = resp.checks_warn + 1
      end
    end
    return ok
  end

  local function issue(severity, msg)
    resp.issues[#resp.issues + 1] = { severity = severity, message = msg }
  end

  -- === System ===
  local release = util.exec("cat /etc/openwrt_release 2>/dev/null | head -1") or ""
  release = release:gsub("\n", ""):gsub("^%s+", ""):gsub("%s+$", "")
  resp.system.firmware = release ~= "" and release or "Unknown"
  resp.system.kernel   = (util.exec("uname -r"):gsub("\n", ""))
  resp.system.arch     = (util.exec("uname -m"):gsub("\n", ""))
  resp.system.uptime   = (util.exec("uptime"):gsub("\n", "") or "")
  resp.system.lan_ip   = (uci:get("network", "lan", "ipaddr") or "unknown")
  resp.system.lan_mask = (uci:get("network", "lan", "netmask") or "unknown")

  local has_fw4 = fs.access("/usr/sbin/fw4")
  local has_nft = fs.access("/usr/sbin/nft")
  resp.system.fw4_exists = has_fw4
  resp.system.nft_exists = has_nft

  if has_fw4 or has_nft then
    resp.system.firewall_type = "nftables (fw4)"
  else
    resp.system.firewall_type = "iptables (fw3)"
  end

  -- === Process ===
  -- Use 'ps ww' (unlimited width) to avoid BusyBox truncating long command lines
  -- Without 'ww', '-m tproxy' gets truncated to '-m tp'
  local ps_out = util.exec("ps ww | grep acc-gw | grep -v grep 2>/dev/null") or ""
  resp.process.running = ps_out ~= ""
  -- Take first line only (daemon process) to avoid multi-line concatenation
  local cmdline = (ps_out:match("[^\n]+") or ""):gsub("%s+", " ")
  resp.process.cmdline = cmdline ~= "" and cmdline or "N/A"

  -- Extract mode from actual process command line
  local pid_mode = cmdline:match("%-m (%S+)")
  resp.process.mode_cmdline = pid_mode or "not detected"
  resp.process.mode_ok = (pid_mode == "tun" or pid_mode == "tproxy")

  -- PID and memory (VSZ)
  -- BusyBox ps columns: PID USER VSZ STAT COMMAND (no RSS by default)
  -- $1=PID, $3=VSZ (virtual memory in KB) — use VSZ since RSS is not available
  local pid_raw = util.exec("ps ww | grep acc-gw | grep -v grep | head -1 | awk '{print $1,$3}' 2>/dev/null") or ""
  pid_raw = pid_raw:gsub("\n", ""):gsub("%s+", " ")
  local pid_parts = {}
  for p in pid_raw:gmatch("%S+") do pid_parts[#pid_parts+1] = p end
  resp.process.pid = pid_parts[1] or "N/A"
  resp.process.vsz_kb = pid_parts[2] or "N/A"

  -- Port listening check: try ss first, fallback to netstat (BusyBox lacks ss)
  local port_out = util.exec("ss -tlnp 2>/dev/null | grep 5588") or ""
  if port_out == "" then
    port_out = util.exec("netstat -tlnp 2>/dev/null | grep 5588") or ""
  end
  resp.process.port_listening = port_out ~= ""

  -- Init script enabled
  local init_enabled = util.exec("/etc/init.d/acc enabled 2>/dev/null") or ""
  resp.process.init_enabled = init_enabled:match("running") ~= nil or init_enabled:match("enabled") ~= nil

  -- === Init Script Analysis ===
  resp.init_script.exists = fs.access("/etc/init.d/acc")
  if resp.init_script.exists then
    local args_line = ""
    for line in io.lines("/etc/init.d/acc") do
      if line:match("^%s*args=") then
        args_line = line:gsub("^%s*", ""):gsub("%s*$", "")
        break
      end
    end
    resp.init_script.args_line = args_line ~= "" and args_line or "(args= line not found)"

    -- Detect mode flag format
    local short_tun  = args_line:match("%-m tun")
    local short_tpr  = args_line:match("%-m tproxy")
    local long_tun   = args_line:match("%-%mode tun")
    local long_tpr   = args_line:match("%-%mode tproxy")

    resp.init_script.short_format = (short_tun ~= nil or short_tpr ~= nil)
    resp.init_script.has_long_format = (long_tun ~= nil or long_tpr ~= nil)

    if short_tun then
      resp.init_script.mode_flag = "-m tun"
      resp.init_script.mode_name = "TUN"
    elseif short_tpr then
      resp.init_script.mode_flag = "-m tproxy"
      resp.init_script.mode_name = "TPROXY"
    elseif long_tun then
      resp.init_script.mode_flag = "--mode tun"
      resp.init_script.mode_name = "TUN (LONG FORMAT)"
    elseif long_tpr then
      resp.init_script.mode_flag = "--mode tproxy"
      resp.init_script.mode_name = "TPROXY (LONG FORMAT)"
    else
      resp.init_script.mode_flag = "MISSING"
      resp.init_script.mode_name = "UNKNOWN"
    end

    resp.init_script.has_port = args_line:match("%-p %d+") ~= nil
  else
    resp.init_script.args_line = "N/A"
    resp.init_script.mode_flag = "N/A"
    resp.init_script.mode_name = "N/A"
    resp.init_script.short_format = false
    resp.init_script.has_long_format = false
    resp.init_script.has_port = false
  end

  -- === Core Config (acc_core_conf.json) ===
  resp.core_config = { exists = false, tproxy_ip = "N/A", tproxy_ip_ok = false,
    acc_mode = "N/A", acc_mode_name = "N/A", acc_mode_ok = false }
  if fs.access("/tmp/acc/acc_core_conf.json") then
    resp.core_config.exists = true
    local conf_raw = ""
    for line in io.lines("/tmp/acc/acc_core_conf.json") do
      conf_raw = conf_raw .. line
    end
    local tproxy = conf_raw:match('"tproxy_ip":"([^"]*)"')
    resp.core_config.tproxy_ip = tproxy or "not found"
    local lan_ip = uci:get("network", "lan", "ipaddr") or ""
    resp.core_config.tproxy_ip_ok = (tproxy == lan_ip)
    local acc_mode = conf_raw:match('"acc_mode":(%d+)')
    resp.core_config.acc_mode = acc_mode or "not found"
    if acc_mode == "1" then
      resp.core_config.acc_mode_name = "TUN"
      resp.core_config.acc_mode_ok = true
    elseif acc_mode == "2" then
      resp.core_config.acc_mode_name = "TPROXY"
      resp.core_config.acc_mode_ok = true
    else
      resp.core_config.acc_mode_name = "UNKNOWN (" .. (acc_mode or "nil") .. ")"
      resp.core_config.acc_mode_ok = false
    end
  end

  -- === Network ===
  local ip_link = util.exec("ip link show 2>/dev/null") or ""
  local tun_match = ip_link:match("(tun%d+):")
  resp.network.tun_iface = tun_match or nil

  -- Firewall rule for TCP 5588
  local fw_rules = util.exec("uci show firewall 2>/dev/null | grep '5588'") or ""
  resp.network.fw_rule_5588 = fw_rules ~= ""

  resp.network.hotplug = fs.access("/etc/hotplug.d/firewall/99-leigodacc-restart")

  -- TURN relay connectivity
  local turn_ping = util.exec("ping -c 1 -W 2 route-turn.xxghh.biz 2>/dev/null | grep -c 'bytes from'") or "0"
  resp.network.turn_reachable = (tonumber(turn_ping:match("%d+")) or 0) > 0

  -- API endpoint reachability
  local api_curl = util.exec("curl -sLo /dev/null -w '%{http_code}' --connect-timeout 3 https://webapi.leigod.com 2>/dev/null") or "000"
  resp.network.api_reachable = api_curl:match("^[23]%d%d$") ~= nil
  resp.network.api_http_code = api_curl:gsub("%s+","")

  -- GAMEACC chain check (iptables-legacy or iptables-nft)
  -- GAMEACC chain: use exit code for reliable detection
  local ga_ok = os.execute("iptables -L GAMEACC -n >/dev/null 2>&1")
  local gameacc_rules = util.exec("iptables -L GAMEACC -n -v 2>/dev/null | head -20") or ""
  if ga_ok == 0 then
    resp.network.gameacc_exists = true
    local counter_line = gameacc_rules:match("\n%s*(%d+%s+%d+%s+[A-Z]+.*)")
    resp.network.gameacc_sample = counter_line and counter_line:gsub("^%s+",""):gsub("%s+$","") or "规则存在 (无计数器行)"
  else
    resp.network.gameacc_exists = false
    resp.network.gameacc_sample = "N/A"
  end

  -- === Latency Diagnostics ===
  resp.latency = {}
  local function ping_host(host)
    local out = util.exec("ping -c 5 -W 2 " .. host .. " 2>/dev/null") or ""
    local loss = out:match("(%d+)%% packet loss") or "?"
    local rtt = out:match("([%d.]+/[%d.]+/[%d.]+) ms") or out:match("min/avg/max = ([%d./]+)") or ""
    local min, avg, max = "?", "?", "?"
    if rtt ~= "" then
      min, avg, max = rtt:match("([%d.]+)/([%d.]+)/([%d.]+)")
      min, avg, max = min or "?", avg or "?", max or "?"
    end
    return { loss = loss, min = min, avg = avg, max = max }
  end

  -- Ping gateway (local network)
  local gw = uci:get("network", "lan", "gateway") or uci:get("network", "lan", "ipaddr") or "192.168.10.1"
  resp.latency.gateway = ping_host(gw)
  resp.latency.gateway.host = gw

  -- Ping public DNS (internet baseline)
  local dns_host = "223.5.5.5"
  resp.latency.dns = ping_host(dns_host)
  resp.latency.dns.host = dns_host
  -- If first DNS fails, try alternate
  if resp.latency.dns.loss == "100" or resp.latency.dns.avg == "?" then
    resp.latency.dns = ping_host("8.8.8.8")
    resp.latency.dns.host = "8.8.8.8"
  end

  -- Ping TURN relay (accelerator server)
  resp.latency.turn = ping_host("route-turn.xxghh.biz")
  resp.latency.turn.host = "route-turn.xxghh.biz"

  -- Extract acceleration server nodes with their ping values from JSON
  resp.latency.nodes = {}
  if fs.access("/tmp/acc/acc_core_conf.json") then
    local raw = ""
    for line in io.lines("/tmp/acc/acc_core_conf.json") do raw = raw .. line end
    -- Extract server host:port and ping values
    -- Pattern: "node":"s5://...@IP:PORT","ping":NN
    for ip, port, ping_val in raw:gmatch('//[^@]+@([%d.]+):(%d+)"[^}]-"ping":(%d+)') do
      resp.latency.nodes[#resp.latency.nodes + 1] = {
        ip = ip, port = port, ping_ms = tonumber(ping_val) }
    end
    -- Try alternate pattern for node IP
    if #resp.latency.nodes == 0 then
      for ip, ping_val in raw:gmatch('"node":"[^"]+@([%d.]+):%d+","ping":(%d+)') do
        resp.latency.nodes[#resp.latency.nodes + 1] = { ip = ip, ping_ms = tonumber(ping_val) }
      end
    end
  end

  -- === Packages ===
  local pkg_check = {
    ["iptables-nft"]    = "iptables-nft",
    ["kmod-nft-nat"]    = "kmod-nft-nat",
    ["kmod-nft-tproxy"] = "kmod-nft-tproxy",
    ["kmod-tun"]        = "kmod-tun",
    ["tc-full"]         = "tc-full",
    ["conntrack"]       = "conntrack",
    ["libpcap"]         = "libpcap",
    ["luci-compat"]     = "luci-compat"
  }
  resp.packages = {}
  for name, pkg in pairs(pkg_check) do
    local installed = util.exec("opkg list-installed 2>/dev/null | grep -q '^" .. pkg .. " ' && echo yes || echo no")
    resp.packages[name] = installed:match("yes") ~= nil
  end

  -- === Devices ===
  resp.devices = { Phone = "None", PC = "None", Game = "None", Unknown = "None" }
  if fs.access("/tmp/acc/acc_core_conf.json") then
    local raw = ""
    for line in io.lines("/tmp/acc/acc_core_conf.json") do raw = raw .. line end
    for _, cat in ipairs({"Phone","PC","Game","Unknown"}) do
      local pos = raw:find('"'..cat..'":')
      if pos then
        local st = raw:sub(pos):match('"state":(%d+)')
        if st then
          local state = tonumber(st)
          if state == 1 then resp.devices[cat] = "Accelerating"
          elseif state == 2 then resp.devices[cat] = "Idle"
          elseif state == 3 then resp.devices[cat] = "Paused" end
        end
      end
    end
  end

  -- === Auto-Pause ===
  resp.autopause = {
    script_installed = fs.access("/usr/sbin/leigod-auto-pause.sh"),
    token_configured = false,
    token_masked     = "(not set)",
    daemon_token_ok  = false,
    cron_enabled     = false,
    manual_disable   = "0"
  }
  -- Check manual token
  if fs.access("/etc/leigod-auto-pause.conf") then
    for line in io.lines("/etc/leigod-auto-pause.conf") do
      local token_val = line:match("ACCOUNT_TOKEN='(.*)'")
      if token_val and token_val ~= "" then
        resp.autopause.token_configured = true
        if #token_val > 12 then
          resp.autopause.token_masked = token_val:sub(1, 8) .. "..." .. token_val:sub(-4)
        else
          resp.autopause.token_masked = string.rep("*", #token_val)
        end
        -- no break: continue loop to parse MANUAL_DISABLE and other keys
      end
      local md = line:match("^MANUAL_DISABLE=(%d+)")
      if md then resp.autopause.manual_disable = md end
    end
  end
  -- Check daemon token (fallback source, always fresh via heartbeat)
  if fs.access("/tmp/acc/acc_core_conf.json") then
    local dt = util.exec("grep -o '\\\\\"token\\\\\":\\\\\"[^\\\\]*' /tmp/acc/acc_core_conf.json 2>/dev/null | head -1 | sed 's/.*\\\\\"//'")
    dt = dt:gsub("\n",""):gsub("%s+","")
    resp.autopause.daemon_token_ok = (#dt > 10)
  end
  if fs.access("/etc/crontabs/root") then
    for line in io.lines("/etc/crontabs/root") do
      if line:match("leigod%-auto%-pause") then
        resp.autopause.cron_enabled = true
        break
      end
    end
  end

  -- === Logs ===
  local raw_logs = util.exec("logread -l 20 2>/dev/null | grep -iE 'leigod|acc-gw|auto.pause' | tail -5") or ""
  resp.logs = {}
  if raw_logs ~= "" and raw_logs ~= "\n" then
    for line in raw_logs:gmatch("[^\n]+") do
      resp.logs[#resp.logs + 1] = line
    end
  end

  -- === Error Log Scan (/tmp/acc/log/) ===
  resp.error_logs = {}
  local log_dir = "/tmp/acc/log/"
  if fs.access(log_dir) then
    local log_files = { "acc_daemon.log", "acc_web.log", "acc_acc.log" }
    for _, lf in ipairs(log_files) do
      local path = log_dir .. lf
      if fs.access(path) then
        local content = util.exec("grep -iE 'error|fail|fatal|crash|wrong|invalid|exit|refused' " .. path .. " 2>/dev/null | tail -5") or ""
        if content ~= "" and content ~= "\n" then
          for line in content:gmatch("[^\n]+") do
            resp.error_logs[#resp.error_logs + 1] = { file = lf, line = line }
          end
        end
      end
    end
  end

  -- ============================================================
  -- Automatic issue detection
  -- ============================================================

  -- CRITICAL: Long format mode flag
  if resp.init_script.has_long_format then
    issue("error", "Init script uses GNU long format (" .. (resp.init_script.mode_flag or "--mode") .. "). The acc-gw binary only recognizes short format (-m tun / -m tproxy). This flag is SILENTLY IGNORED and the binary defaults to TPROXY.")
    check("Init script mode flag uses short format (-m)", false, "error")
  else
    check("Init script mode flag uses short format (-m)", resp.init_script.short_format, "error")
  end

  -- Process running
  if resp.process.running then
    check("acc-gw process is running", true)
  else
    issue("error", "acc-gw process is NOT running. Acceleration is completely non-functional.")
    check("acc-gw process is running", false, "error")
  end

  -- Mode consistency: is the process actually running in the mode the init script specifies?
  if resp.process.running and resp.init_script.short_format then
    local init_mode = resp.init_script.mode_flag:match("%-m (%S+)")
    if init_mode and pid_mode and init_mode ~= pid_mode then
      issue("warning", "Mode mismatch: init script specifies " .. init_mode .. " but process is running as " .. pid_mode .. ". Try restarting the service (menu option 5).")
      check("Process mode matches init script", false, "warning")
    else
      check("Process mode matches init script", true)
    end
  end

  -- Mode check: this binary ONLY supports TPROXY (not TUN)
  if resp.process.running then
    if pid_mode == "tun" then
      -- TUN was selected but binary may ignore it; check if it actually took effect
      if resp.network.tun_iface then
        check("TUN mode active (TUN interface exists)", true)
      else
        issue("info", "选择了 TUN 模式但二进制不支持 TUN，实际运行在 TPROXY。风险: 低(如加速正常则无影响)")
        check("TUN mode active", false, "info")
      end
    elseif pid_mode == "tproxy" then
      -- TPROXY is the only supported mode for this binary — no issue
      check("运行模式 (TPROXY)", true, "info")
    end
  end

  -- TUN interface
  if pid_mode == "tun" then
    if resp.network.tun_iface then
      check("TUN interface exists (TUN mode active)", true)
    else
      issue("warning", "Process claims TUN mode but no tunX interface found. The TUN device may have failed to create.")
      check("TUN interface exists (TUN mode active)", false, "warning")
    end
  end

  -- Port 5588
  if resp.process.running then
    if resp.process.port_listening then
      check("API port 5588 is listening", true)
    else
      issue("error", "Port 5588 is NOT listening. Phone APP cannot communicate with acc-gw. Clicking 'accelerate' will hang.")
      check("API port 5588 is listening", false, "error")
    end
  end

  -- Firewall rule for 5588
  if not resp.network.fw_rule_5588 and (has_fw4 or has_nft) then
    issue("warning", "No firewall rule for TCP 5588. fw4 may block LAN traffic to the acc-gw API. Run menu option 1 or install via script to auto-configure.")
    check("Firewall rule allows TCP 5588", false, "warning")
  else
    check("Firewall rule allows TCP 5588", resp.network.fw_rule_5588 or not (has_fw4 or has_nft))
  end

  -- Hotplug
  if has_fw4 or has_nft then
    if resp.network.hotplug then
      check("fw4 hotplug script installed", true)
    else
      issue("warning", "fw4 hotplug script not installed. After fw4 reload, acceleration rules may be lost.")
      check("fw4 hotplug script installed", false, "warning")
    end
  end

  -- Init script has port
  if resp.init_script.exists then
    if resp.init_script.has_port then
      check("Init script specifies API port (-p)", true)
    else
      issue("error", "Init script missing -p <port>. acc-gw may not listen on the correct port.")
      check("Init script specifies API port (-p)", false, "error")
    end
  end

  -- Critical packages
  if resp.packages["kmod-tun"] ~= nil and not resp.packages["kmod-tun"] then
    issue("warning", "kmod-tun is not installed. TUN mode will NOT work without it.")
    check("kmod-tun is installed", false, "warning")
  else
    check("kmod-tun is installed", resp.packages["kmod-tun"] ~= false)
  end

  if (has_fw4 or has_nft) then
    if resp.packages["iptables-nft"] ~= nil and not resp.packages["iptables-nft"] then
      issue("warning", "iptables-nft is not installed. iptables commands will not translate to nftables rules.")
      check("iptables-nft is installed", false, "warning")
    else
      check("iptables-nft is installed", resp.packages["iptables-nft"] ~= false)
    end

    if resp.packages["kmod-nft-nat"] ~= nil and not resp.packages["kmod-nft-nat"] then
      issue("warning", "kmod-nft-nat is not installed. NAT rules required for acceleration may not work.")
      check("kmod-nft-nat is installed", false, "warning")
    else
      check("kmod-nft-nat is installed", resp.packages["kmod-nft-nat"] ~= false)
    end
  end

  -- Init script file exists
  if resp.init_script.exists then
    check("Init script /etc/init.d/acc exists", true)
  else
    issue("error", "Init script /etc/init.d/acc not found. LeigodAcc may not be installed.")
    check("Init script /etc/init.d/acc exists", false, "error")
  end

  -- Is anything actually accelerating?
  local any_accel = false
  for _, state in pairs(resp.devices) do
    if state == "Accelerating" then any_accel = true; break end
  end
  if resp.process.running and not any_accel then
    issue("info", "当前无设备在加速。如未开始游戏则属正常，开始游戏后设备状态应变为 Accelerating。")
  end

  -- Init script enabled
  if not resp.process.init_enabled and resp.init_script.exists then
    issue("info", "服务未设为开机自启 (路由器重启后需手动启动)。建议: /etc/init.d/acc enable")
    check("开机自启", false, "info")
  else
    check("开机自启", resp.process.init_enabled, "info")
  end

  -- Core config: tproxy_ip correctness
  if resp.core_config.exists then
    if resp.core_config.tproxy_ip_ok then
      check("acc_core_conf.json tproxy_ip matches LAN IP", true)
    else
      if pid_mode == "tproxy" then
        issue("error", "acc_core_conf.json tproxy_ip (" .. resp.core_config.tproxy_ip .. ") does NOT match LAN IP (" .. resp.system.lan_ip .. "). The web subprocess will CRASH (exit 255) and phone APP cannot communicate. Run 'leigod-fw4.sh fix-config' to auto-fix.")
        check("acc_core_conf.json tproxy_ip matches LAN IP", false, "error")
      else
        issue("warning", "acc_core_conf.json tproxy_ip (" .. resp.core_config.tproxy_ip .. ") does not match LAN IP (" .. resp.system.lan_ip .. "). In TUN mode this may not matter, but if you switch to TPROXY it will break.")
        check("acc_core_conf.json tproxy_ip matches LAN IP", false, "warning")
      end
    end

    if resp.core_config.acc_mode_ok then
      check("acc_core_conf.json acc_mode is valid", true)
    else
      issue("error", "acc_core_conf.json has invalid acc_mode (" .. resp.core_config.acc_mode .. "). The daemon may reject this configuration.")
      check("acc_core_conf.json acc_mode is valid", false, "error")
    end
  else
    issue("warning", "acc_core_conf.json not found at /tmp/acc/acc_core_conf.json. The acc-gw daemon has not generated its runtime config yet. Try starting the service first.")
    check("acc_core_conf.json exists", false, "warning")
  end

  -- TURN relay reachability
  if resp.network.turn_reachable then
    check("TURN relay route-turn.xxghh.biz is reachable", true)
  else
    issue("error", "TURN relay host route-turn.xxghh.biz is NOT reachable. This is the relay server that forwards accelerated game traffic. Without it, acceleration will have NO effect on latency. Check your internet connection and DNS.")
    check("TURN relay route-turn.xxghh.biz is reachable", false, "error")
  end

  -- API endpoint reachability
  if resp.network.api_reachable then
    check("Leigod API webapi.leigod.com is reachable", true)
  else
    issue("error", "Leigod API endpoint webapi.leigod.com returned HTTP " .. resp.network.api_http_code .. ". Auto-pause and device status sync will NOT work. Check your internet connection.")
    check("Leigod API webapi.leigod.com is reachable", false, "error")
  end

  -- GAMEACC chain
  if resp.network.gameacc_exists then
    check("GAMEACC iptables chain exists", true)
  else
    if resp.process.running then
      issue("warning", "GAMEACC iptables 链未找到。如手机 APP 已发起加速则规则注入失败, 请重启服务。如未发起加速则属正常。")
      check("GAMEACC iptables chain exists", false, "warning")
    end
  end

  -- Error log scan issues
  if #resp.error_logs > 0 then
    local msgs = {}
    for _, entry in ipairs(resp.error_logs) do
      msgs[#msgs+1] = "[" .. entry.file .. "] " .. entry.line
    end
    issue("warning", "Found " .. #resp.error_logs .. " error/warning lines in acc-gw logs: see Error Logs table for details.")
    check("acc-gw internal logs are error-free", false, "warning")
  else
    check("acc-gw internal logs are error-free", true)
  end

  -- Web subprocess crash detection (exit 255 pattern)
  if resp.core_config.exists and pid_mode == "tproxy" and not resp.core_config.tproxy_ip_ok then
    issue("error", "Web subprocess crash loop expected: tproxy_ip mismatch. The web process exits with code 255 every ~8 seconds, consuming CPU and preventing phone APP communication. FIX: set tproxy_ip to " .. resp.system.lan_ip .. " in /tmp/acc/acc_core_conf.json and restart.")
  end

  luci.http.prepare_content("application/json")
  luci.http.write_json(resp)
end

-- ============================================================
-- Plain-text diagnostic report for copy-paste bug analysis
-- ============================================================
function get_debug_report()
  local util = require "luci.util"
  local uci  = require "luci.model.uci".cursor()
  local fs   = require "nixio.fs"

  local lines = {}
  local function w(s) lines[#lines+1] = s end
  local function ok(b) return b and "PASS" or "FAIL" end
  local function yn(b) return b and "Yes" or "No" end

  local now = os.date("%Y-%m-%d %H:%M:%S")
  w("============================================================")
  w("  Leigod Accelerator Diagnostic Report")
  w("  Generated: " .. now)
  w("============================================================")
  w("")

  -- System
  local release = util.exec("cat /etc/openwrt_release 2>/dev/null | head -1"):gsub("\n","")
  w("--- System ---")
  w("  Firmware:    " .. (release ~= "" and release or "Unknown"))
  w("  Kernel:      " .. util.exec("uname -r"):gsub("\n",""))
  w("  Arch:        " .. util.exec("uname -m"):gsub("\n",""))
  w("  Uptime:      " .. util.exec("uptime"):gsub("\n",""))
  w("  LAN IP:      " .. (uci:get("network","lan","ipaddr") or "unknown"))
  w("  Firewall:    " .. (fs.access("/usr/sbin/fw4") and "nftables (fw4)" or "iptables (fw3)"))

  -- Process
  local ps_raw = (util.exec("ps ww | grep acc-gw | grep -v grep 2>/dev/null"):match("[^\n]+") or "")
  local running = ps_raw ~= ""
  w("")
  w("--- Process ---")
  w("  Running:     " .. yn(running))
  if running then
    w("  Cmdline:     " .. ps_raw:gsub("%s+"," "))
    local pm = ps_raw:match("%-m (%S+)") or "not detected"
    w("  Mode:        " .. pm)
    local pid = ps_raw:match("^(%d+)") or "N/A"
    w("  PID:         " .. pid)
  end
  local ss = util.exec("ss -tlnp 2>/dev/null | grep 5588") or ""
  w("  Port 5588:   " .. yn(ss ~= ""))

  -- Init script
  local init_exists = fs.access("/etc/init.d/acc")
  w("")
  w("--- Init Script /etc/init.d/acc ---")
  w("  Exists:      " .. yn(init_exists))
  if init_exists then
    local args_line = "N/A"
    for line in io.lines("/etc/init.d/acc") do
      if line:match("^%s*args=") then args_line = line:gsub("^%s*",""):gsub("%s*$",""); break end
    end
    w("  Args:        " .. args_line)
    local has_short = args_line:match("%-m tun") or args_line:match("%-m tproxy")
    w("  Short fmt:   " .. yn(has_short ~= nil))
    local has_port = args_line:match("%-p %d+")
    w("  Has port:    " .. yn(has_port ~= nil))
  end

  -- Core config
  local conf_exists = fs.access("/tmp/acc/acc_core_conf.json")
  w("")
  w("--- Core Config /tmp/acc/acc_core_conf.json ---")
  w("  Exists:      " .. yn(conf_exists))
  if conf_exists then
    local conf_raw = ""
    for line in io.lines("/tmp/acc/acc_core_conf.json") do conf_raw = conf_raw .. line end
    local tproxy_ip = conf_raw:match('"tproxy_ip":"([^"]*)"') or "not found"
    local lan_ip = uci:get("network","lan","ipaddr") or ""
    w("  tproxy_ip:   " .. tproxy_ip .. " (LAN: " .. lan_ip .. ") [" .. ok(tproxy_ip == lan_ip) .. "]")
    local acc_mode = conf_raw:match('"acc_mode":(%d+)') or "not found"
    local mode_name = acc_mode == "1" and "TUN" or (acc_mode == "2" and "TPROXY" or "UNKNOWN")
    w("  acc_mode:    " .. mode_name .. " (" .. acc_mode .. ")")
  end

  -- Network
  w("")
  w("--- Network & Firewall ---")
  local tun = util.exec("ip link show 2>/dev/null | grep -o 'tun[0-9]*'"):gsub("\n"," ")
  w("  TUN ifaces:  " .. (tun ~= "" and tun or "none"))
  local fw_rule = util.exec("uci show firewall 2>/dev/null | grep -c 5588"):gsub("\n","")
  w("  FW rule 5588:" .. (tonumber(fw_rule) > 0 and " Yes" or " No"))
  w("  Hotplug:     " .. yn(fs.access("/etc/hotplug.d/firewall/99-leigodacc-restart")))
  local turn_ok = (tonumber((util.exec("ping -c 1 -W 2 route-turn.xxghh.biz 2>/dev/null | grep -c 'bytes from'") or "0"):match("%d+")) or 0) > 0
  w("  TURN relay:  " .. ok(turn_ok) .. " (route-turn.xxghh.biz)")
  local api_code = util.exec("curl -sLo /dev/null -w '%{http_code}' --connect-timeout 3 https://webapi.leigod.com 2>/dev/null"):gsub("%s+","")
  w("  API endpoint: HTTP " .. api_code .. " [" .. ok(api_code:match("^[23]%d%d$") ~= nil) .. "]")

  -- GAMEACC
  local gameacc = util.exec("iptables -L GAMEACC -n 2>/dev/null | wc -l"):gsub("%s+","")
  w("  GAMEACC rules: " .. (tonumber(gameacc) > 2 and gameacc .. " lines" or "MISSING"))

  -- Packages
  w("")
  w("--- Critical Packages ---")
  for _, pkg in ipairs({"iptables-nft","kmod-nft-nat","kmod-nft-tproxy","kmod-tun","tc-full","conntrack","libpcap","luci-compat"}) do
    local inst = util.exec("opkg list-installed 2>/dev/null | grep -q '^" .. pkg .. " ' && echo yes || echo no"):match("yes") ~= nil
    w("  " .. pkg .. ": " .. string.rep(" ", 18 - #pkg) .. yn(inst))
  end

  -- Devices
  w("")
  w("--- Device Acceleration State ---")
  for _, cat in ipairs({"Phone","PC","Game","Unknown"}) do
    local state = uci:get("accelerator", cat, "state") or "0"
    local text = state == "1" and "Accelerating" or (state == "2" and "Idle" or (state == "3" and "Paused" or "None"))
    w("  " .. cat .. ": " .. string.rep(" ", 10 - #cat) .. text)
  end

  -- Auto-pause
  w("")
  w("--- Auto-Pause ---")
  w("  Script:      " .. yn(fs.access("/usr/sbin/leigod-auto-pause.sh")))
  local token_ok = false
  local token_masked = "(not set)"
  local manual_disable = false
  if fs.access("/etc/leigod-auto-pause.conf") then
    for line in io.lines("/etc/leigod-auto-pause.conf") do
      local token_val = line:match("ACCOUNT_TOKEN='(.*)'")
      if token_val and token_val ~= "" and not token_ok then
        token_ok = true
        token_masked = #token_val > 12 and (token_val:sub(1,8) .. "..." .. token_val:sub(-4)) or string.rep("*",#token_val)
      end
      local md = line:match("^MANUAL_DISABLE=(%d+)")
      if md == "1" then manual_disable = true end
    end
  end
  w("  Token:       " .. token_masked .. " [" .. ok(token_ok) .. "]")
  if manual_disable then
    w("  AwayMode:    已启用 (自动暂停禁用)")
  end
  local cron_ok = false
  if fs.access("/etc/crontabs/root") then
    for line in io.lines("/etc/crontabs/root") do
      if line:match("leigod%-auto%-pause") then cron_ok = true; break end
    end
  end
  w("  Cron:        " .. yn(cron_ok))

  -- Error logs
  w("")
  w("--- acc-gw Internal Error Logs ---")
  local log_dir = "/tmp/acc/log/"
  local found_errors = false
  if fs.access(log_dir) then
    for _, lf in ipairs({"acc_daemon.log","acc_web.log","acc_acc.log"}) do
      local path = log_dir .. lf
      if fs.access(path) then
        local content = util.exec("grep -iE 'error|fail|fatal|crash|wrong|invalid|exit|refused' " .. path .. " 2>/dev/null | tail -5") or ""
        if content ~= "" and content ~= "\n" then
          found_errors = true
          w("  [" .. lf .. "]")
          for line in content:gmatch("[^\n]+") do
            w("    " .. line)
          end
        end
      end
    end
  end
  if not found_errors then w("  (no errors found)") end

  -- System logs (recent)
  w("")
  w("--- Recent System Logs (logread) ---")
  local sys_logs = util.exec("logread -l 20 2>/dev/null | grep -iE 'leigod|acc-gw|auto.pause' | tail -5") or ""
  if sys_logs ~= "" and sys_logs ~= "\n" then
    for line in sys_logs:gmatch("[^\n]+") do w("  " .. line) end
  else
    w("  (no matching log entries)")
  end

  w("")
  w("============================================================")
  w("  Report complete. Copy this text to share for bug analysis.")
  w("============================================================")

  luci.http.prepare_content("text/plain; charset=utf-8")
  luci.http.write(table.concat(lines, "\n"))
end

-- ============================================================
-- One-click token save — called by bookmarklet from leigod.com
-- Accepts POST {token: "..."} and writes to auto-pause config
-- ============================================================
function save_token()
  local util = require "luci.util"
  local fs   = require "nixio.fs"

  -- Support both POST JSON and GET ?token=...
  local token = nil
  if luci.http.getenv("REQUEST_METHOD") == "POST" then
    local body = luci.http.content() or ""
    token = body:match('"token":"([^"]*)"') or body:match("token=([^&]+)")
  end
  if not token then
    token = luci.http.formvalue("token")
  end

  if not token or #token < 10 then
    luci.http.status(400, "Bad Request")
    luci.http.prepare_content("application/json")
    luci.http.write_json({ result = "ERROR", message = "无效的 token" })
    return
  end

  token = token:gsub("[^a-zA-Z0-9_-]", "")  -- sanitize

  local conf_file = "/etc/leigod-auto-pause.conf"
  local lines = {}
  local has_user, has_pwd = false, false

  -- Preserve existing USERNAME/PASSWORD_MD5 if present
  if fs.access(conf_file) then
    for line in io.lines(conf_file) do
      if line:match("^USERNAME=") then has_user = true; lines[#lines+1] = line
      elseif line:match("^PASSWORD_MD5=") then has_pwd = true; lines[#lines+1] = line
      elseif not line:match("^ACCOUNT_TOKEN=") and not line:match("^#") and line ~= "" then
        lines[#lines+1] = line
      elseif line:match("^#") then
        lines[#lines+1] = line
      end
    end
  end

  -- Rewrite config with new token
  local file = io.open(conf_file, "w")
  if not file then
    luci.http.status(500, "Internal Server Error")
    luci.http.prepare_content("application/json")
    luci.http.write_json({ result = "ERROR", message = "无法写入配置文件" })
    return
  end

  local wrote_token = false
  for _, line in ipairs(lines) do
    file:write(line .. "\n")
    -- Insert token after USERNAME/PASSWORD_MD5 lines (or at top if none)
    if not wrote_token and (line:match("^PASSWORD_MD5=") or (not has_user and line:match("^IDLE_"))) then
      file:write(string.format("ACCOUNT_TOKEN='%s'\n", token))
      wrote_token = true
    end
  end
  if not wrote_token then
    file:write(string.format("ACCOUNT_TOKEN='%s'\n", token))
    -- Ensure default settings exist
    if not has_user then
      file:write("IDLE_CHECKS_BEFORE_PAUSE=3\nAPI_TIMEOUT=10\nAPI_ENDPOINT=\"https://webapi.leigod.com\"\nNOTIFY_ON_PAUSE=1\nMANUAL_DISABLE=0\n")
    end
  end
  file:close()
  util.exec(string.format("chmod 600 %s", conf_file))

  -- For bookmarklet (GET) return HTML; for manual save (POST JSON) return JSON
  if luci.http.getenv("HTTP_CONTENT_TYPE") and luci.http.getenv("HTTP_CONTENT_TYPE"):match("application/json") then
    luci.http.prepare_content("application/json")
    luci.http.write_json({ result = "OK", message = "Token 已保存，下次检测时生效" })
  elseif luci.http.formvalue("token") and luci.http.getenv("REQUEST_METHOD"):upper() ~= "POST" then
    luci.http.prepare_content("text/html; charset=utf-8")
    luci.http.write([[
<!DOCTYPE html><html><head><meta charset="utf-8"><title>Token 已保存</title>
<style>body{font-family:sans-serif;text-align:center;padding:40px 20px;background:#f5f5f5}
.msg{font-size:24px;color:#080;font-weight:bold}.sub{color:#666;margin-top:8px}
</style></head><body><div class="msg">Token 已保存到路由器!</div>
<div class="sub">3秒后自动关闭窗口...</div>
<script>setTimeout(function(){window.close()},3000)</script></body></html>]])
  else
    luci.http.prepare_content("application/json")
    luci.http.write_json({ result = "OK", message = "Token 已保存，下次检测时生效" })
  end
end

LUAEOF

        # model/cbi/leigod/service.lua
        mkdir -p "$luci_src/model/cbi/leigod"
        cat > "$luci_src/model/cbi/leigod/service.lua" << 'LUAEOF'
-- fw4 adapted: Leigod Service configuration
local uci  = require "luci.model.uci".cursor()
local fs   = require "nixio.fs"

-- Detect firewall type
local fw_type = "iptables (fw3)"
local fw_recommend = ""
if fs.access("/usr/sbin/fw4") or fs.access("/usr/sbin/nft") then
    fw_type = "nftables (fw4)"
    fw_recommend = "检测到 fw4: 请确保 acc_core_conf.json 中 tproxy_ip 为路由器 LAN IP。如加速失败请运行诊断。"
end

m = Map("accelerator")
m.title = "雷神加速器配置"
m.description = "控制加速器设置"

-- Firewall info (read-only, fw4 adapted)
s = m:section(TypedSection, "system")
s.addremove = false
s.anonymous = true

fw_info = s:option(DummyValue, "_fw_info", "防火墙类型")
fw_info.value = fw_type
fw_info.rmempty = false
if fw_recommend ~= "" then
    fw_info.description = fw_recommend
end

enable = s:option(Flag, "enabled", "启用加速")
enable.rmempty = false
enable.default = 0

tun = s:option(Flag, "tun", "TUN 隧道模式")
tun.rmempty = false
tun.default = 0
tun.description = "切换为 TUN 隧道模式可避免与其他代理插件冲突。注意: 部分 acc-gw 版本仅支持 TPROXY，如加速失败请运行诊断。"

schedule_enabled = s:option(Flag, "schedule_enabled", "定时暂停")
schedule_enabled.rmempty = false
schedule_enabled.default = 0
schedule_enabled.description = "为雷神加速器启用定时暂停"

pause_time = s:option(ListValue, "pause_time", "暂停时间")
pause_time:depends("schedule_enabled", 1)
for i = 0, 23 do
    pause_time:value(string.format("%02d:00", i), string.format("%02d:00", i))
end
pause_time.rmempty = true

username = s:option(Value, "username", "手机号")
username:depends("schedule_enabled", 1)
username.rmempty = true

password = s:option(Value, "password", "雷神密码")
password:depends("schedule_enabled", 1)
password.password = true
password.rmempty = true

m:section(SimpleSection).template = "leigod/service"

return m

LUAEOF

        # model/cbi/leigod/notice.lua (fw4 adapted)
        cat > "$luci_src/model/cbi/leigod/notice.lua" << 'LUAEOF'
-- fw4 adapted: Leigod Notice page
local uci = require "luci.model.uci".cursor()
local fs  = require "nixio.fs"

m                                 = Map("accelerator")
m.title                           = "雷神公告"
m.description                     = "雷神加速器使用须知"

-- fw4 compatibility note
if fs.access("/usr/sbin/fw4") or fs.access("/usr/sbin/nft") then
    m.description = m.description .. "\n" ..
        "防火墙: nftables (fw4) — 通过 iptables-nft 翻译层兼容。" .. " " ..
        "请确保 acc_core_conf.json 中 tproxy_ip 为路由器 LAN IP。"
end

m:section(SimpleSection).template = "leigod/notice"

return m

LUAEOF

        # view/leigod/service.htm
        mkdir -p "$luci_src/view/leigod"
        cat > "$luci_src/view/leigod/service.htm" << 'HTMEOF'
<!-- fw4 adapted: acc service state + firewall info -->
<fieldset class="cbi-section">
  <legend>加速状态</legend>
  <table class="cbi-section-table" id="acc_catalog_state_table">
    <tr class="cbi-section-table-title">
      <th class="cbi-section-table-cell">设备类型</th>
      <th class="cbi-section-table-cell">加速状态</th>
    </tr>
  </table>
</fieldset>

<script type="text/javascript">//<![CDATA[
    XHR.poll(5, '<%=url('admin/services/acc/status')%>', null, function(x, st) {
      var catalog_table = document.getElementById("acc_catalog_state_table");
      if (st && catalog_table) {
        while(catalog_table.rows.length > 1)
          catalog_table.deleteRow(1);
        var status_map = st["state"];
        for (var typ in status_map) {
          var tr = catalog_table.insertRow(-1);
          tr.insertCell(-1).innerHTML = typ;
          tr.insertCell(-1).innerHTML = status_map[typ];
        }
        var tr = catalog_table.insertRow(-1);
        tr.insertCell(-1).innerHTML = '<em>防火墙</em>';
        tr.insertCell(-1).innerHTML = '<em>' + (st["firewall"] || "unknown") + '</em>';
      }
    });
//]]></script>

HTMEOF

        # model/cbi/leigod/autopause.lua
        cat > "$luci_src/model/cbi/leigod/autopause.lua" << 'LUAEOF'
-- fw4 adapted: Auto-Pause configuration page
local uci  = require "luci.model.uci".cursor()
local fs   = require "nixio.fs"
local util = require "luci.util"

local AP_CONF = "/etc/leigod-auto-pause.conf"

-- Read existing config
local existing_token = ""
local existing_idle = 3
local existing_interval = 2
local existing_timeout = 10
local existing_notify = 1
local existing_manual = 0
if fs.access(AP_CONF) then
    for line in io.lines(AP_CONF) do
        local tv = line:match("^ACCOUNT_TOKEN='(.*)'$")
        if tv then existing_token = tv end
        local idc = line:match("^IDLE_CHECKS_BEFORE_PAUSE=(%d+)")
        if idc then existing_idle = tonumber(idc) end
        local inv = line:match("^IDLE_CHECK_INTERVAL=(%d+)")
        if inv then existing_interval = tonumber(inv) end
        local tmo = line:match("^API_TIMEOUT=(%d+)")
        if tmo then existing_timeout = tonumber(tmo) end
        local nfy = line:match("^NOTIFY_ON_PAUSE=(%d+)")
        if nfy then existing_notify = tonumber(nfy) end
        local man = line:match("^MANUAL_DISABLE=(%d+)")
        if man then existing_manual = tonumber(man) end
    end
end

m = Map("accelerator", "自动暂停配置",
    "检测到所有设备停止加速后，自动暂停时长计费。Token 通过书签一键获取。")

-- Section: Settings
s = m:section(TypedSection, "system", "设置")
s.addremove = false
s.anonymous = true

-- Account token
token = s:option(Value, "_ap_token", "账号令牌 (Token)")
token.rmempty = false
token.password = true
if existing_token and existing_token ~= "" then
    local masked
    if #existing_token > 12 then
        masked = existing_token:sub(1, 8) .. string.rep("*", math.min(8, #existing_token - 12)) .. existing_token:sub(-4)
    else
        masked = string.rep("*", #existing_token)
    end
    token.value = masked
    token.placeholder = "(已配置)"
end
token.description = "将下方运行状态区的书签拖到浏览器书签栏，登录 leigod.com 后点击即可自动获取"

-- Idle check interval (cron frequency)
interval = s:option(Value, "_ap_interval", "检测间隔 (分钟)")
interval.datatype = "range(1,30)"
interval.default = existing_interval
interval.value = existing_interval
interval.description = "每 N 分钟检测一次设备是否空闲。修改后自动更新定时任务"

-- Idle checks before pause
idle = s:option(Value, "_ap_idle", "空闲检测次数")
idle.datatype = "range(1,30)"
idle.default = existing_idle
idle.value = existing_idle
idle.description = string.format("连续检测到空闲 N 次后触发暂停 (总空闲 = %d分钟 × %d次 = %d分钟)",
    existing_interval, existing_idle, existing_interval * existing_idle)

-- API timeout
timeout = s:option(Value, "_ap_timeout", "API 超时 (秒)")
timeout.datatype = "range(5,30)"
timeout.default = existing_timeout
timeout.value = existing_timeout
timeout.description = "调用雷神 API 的连接超时时间"

-- Notify on pause
notify = s:option(Flag, "_ap_notify", "暂停时通知")
notify.default = existing_notify
notify.value = existing_notify
notify.description = "暂停成功时打印通知到系统日志"

-- Manual disable (away mode)
manual = s:option(Flag, "_ap_manual", "离家模式 (禁止自动暂停)")
manual.default = existing_manual
manual.value = existing_manual
manual.description = "离家时开启：禁止自动暂停时长计费。用于异地 PC 客户端加速场景，防止路由器误判无设备而暂停时长"

-- Cron enable/disable
cron_enable = s:option(Button, "_ap_toggle_cron")
if fs.access("/etc/crontabs/root") then
    local has_cron = false
    for line in io.lines("/etc/crontabs/root") do
        if line:match("leigod%-auto%-pause") then has_cron = true; break end
    end
    if has_cron then
        cron_enable.title = "禁用自动暂停定时任务"
        cron_enable.inputstyle = "reset"
    else
        cron_enable.title = "启用自动暂停定时任务"
        cron_enable.inputstyle = "apply"
    end
else
    cron_enable.title = "启用自动暂停定时任务"
    cron_enable.inputstyle = "apply"
end
cron_enable.description = "启用或禁用定时检测任务"

-- Manual trigger
trigger = s:option(Button, "_ap_trigger", "立即暂停")
trigger.inputstyle = "apply"
trigger.description = "立即调用暂停 API (用于测试)"

-- Section: Status (filled by JavaScript polling)
s2 = m:section(SimpleSection, "运行状态")
s2.template = "leigod/autopause"

-- Form write handler
-- Scan all submitted form values for a Flag option by name suffix.
-- TypedSection uses internal CBI IDs (e.g. cfg0a1234), not the type name,
-- so we can't hardcode the full form field name. Scan by suffix instead.
-- luci.http.formvalues() (no args) returns {key = last_value, ...}, so
-- for Flag (hidden=0 + checkbox=1), checked → value "1", unchecked → "0".
local function find_flag(option_name, default)
    for k, v in pairs(luci.http.formvalues()) do
        if type(k) == "string" and k:match(option_name .. "$") then
            return v == "1" and "1" or "0"
        end
    end
    return default
end

m.on_commit = function(self)
    local token_val = luci.http.formvalue("cbid.accelerator.system._ap_token") or ""
    local interval_val = luci.http.formvalue("cbid.accelerator.system._ap_interval") or ""
    local idle_val = luci.http.formvalue("cbid.accelerator.system._ap_idle") or "3"
    local timeout_val = luci.http.formvalue("cbid.accelerator.system._ap_timeout") or "10"
    local notify_val = find_flag("_ap_notify", "1")
    -- manual_disable is a real UCI-backed Flag; CBI writes it to
    -- /etc/config/accelerator before on_commit fires. Read the raw file
    -- to avoid UCI cursor caching and form-field name mismatch.
    local manual_val = "0"
    local uf = io.open("/etc/config/accelerator")
    if uf then
        for line in uf:lines() do
            local v = line:match("^%s*option manual_disable%s+'([01])'")
            if v then manual_val = v; break end
        end
        uf:close()
    end

    local file = io.open(AP_CONF, "w")
    if not file then return end

    file:write("# LeigodAcc Auto-Pause configuration\n")

    -- Token
    if token_val ~= "" and not token_val:match("%*%*%*%*%*%*") then
        token_val = token_val:gsub("[^a-zA-Z0-9_-]", "")  -- sanitize
        file:write(string.format("ACCOUNT_TOKEN='%s'\n", token_val))
    elseif existing_token ~= "" then
        file:write(string.format("ACCOUNT_TOKEN='%s'\n", existing_token))
    end

    -- Idle settings
    local iv = tonumber(interval_val)
    if not iv or iv < 1 then iv = existing_interval end
    file:write(string.format("IDLE_CHECK_INTERVAL=%d\n", iv))

    local ic = tonumber(idle_val)
    if not ic or ic < 1 then ic = existing_idle end
    file:write(string.format("IDLE_CHECKS_BEFORE_PAUSE=%d\n", ic))

    file:write(string.format("API_TIMEOUT=%d\n", tonumber(timeout_val) or 10))
    file:write(string.format("API_ENDPOINT=\"https://webapi.leigod.com\"\n"))
    file:write(string.format("NOTIFY_ON_PAUSE=%d\n", tonumber(notify_val) or 1))
    file:write(string.format("MANUAL_DISABLE=%d\n", tonumber(manual_val) or 0))
    file:close()

    util.exec(string.format("chmod 600 %s", AP_CONF))

    -- Update cron interval
    local old_cron = "*/2 * * * *"
    local new_cron = string.format("*/%d * * * *", iv)
    util.exec(string.format("sed -i 's|%s %s|%s %s|' /etc/crontabs/root 2>/dev/null",
        old_cron:gsub("%*", "\\*"), "/usr/sbin/leigod-auto-pause.sh",
        new_cron, "/usr/sbin/leigod-auto-pause.sh"))
    util.exec("/etc/init.d/cron restart 2>/dev/null")
end

return m

LUAEOF

        # view/leigod/autopause.htm
        cat > "$luci_src/view/leigod/autopause.htm" << 'HTMEOF'
<!-- Auto-Pause status display (fw4 adapted) -->
<fieldset class="cbi-section">
  <legend>自动暂停运行状态</legend>
  <table class="cbi-section-table" id="ap_status_table">
    <tr class="cbi-section-table-title">
      <th class="cbi-section-table-cell">项目</th>
      <th class="cbi-section-table-cell">状态</th>
    </tr>
  </table>
  <div id="ap_actions" style="margin-top:8px;"></div>
</fieldset>

<fieldset class="cbi-section" style="margin-top:12px">
  <legend>一键获取 Token</legend>

  <div style="padding:8px 0">
    <p style="margin:0 0 6px 0"><b>方法一 (推荐)：</b>将下方按钮拖到浏览器书签栏。然后打开 <a href="https://www.leigod.com" target="_blank">leigod.com</a> 并登录，点击书签即可自动将 Token 发送到路由器。</p>

    <div id="bm_container" style="margin:8px 0;padding:8px 12px;background:#f0f0f0;border-radius:4px;display:inline-block">
      <span style="font-size:13px;color:#666;margin-right:8px">📌 拖我到书签栏 →</span>
      <a id="bm_link" href="" onclick="return false" class="cbi-button cbi-button-action" style="text-decoration:none;cursor:grab">🔑 获取雷神Token</a>
    </div>
    <small style="color:#888">点击书签后页面会弹出提示 "Token已发送到路由器!"</small>

    <hr style="margin:12px 0">

    <p style="margin:0 0 6px 0"><b>方法二 (手动)：</b>从 <a href="https://www.leigod.com" target="_blank">leigod.com</a> 登录后，F12 → Console 执行以下代码，然后粘贴到这里：</p>
    <code style="display:block;padding:4px 8px;background:#1e1e1e;color:#0c0;margin:4px 0 8px">JSON.parse(localStorage.getItem('account_token')).account_token</code>

    <div style="display:flex;align-items:center;gap:8px">
      <input type="text" id="ap_quick_token" placeholder="粘贴 Token 到这里..." style="flex:1;padding:4px 8px">
      <button class="cbi-button cbi-button-apply" onclick="ap_save_token()" style="white-space:nowrap">保存</button>
    </div>
    <div id="ap_save_msg" style="margin-top:4px;font-size:12px;display:none"></div>
  </div>
</fieldset>

<script type="text/javascript">//<![CDATA[
    // Generate bookmarklet with router URL
    (function() {
      var saveUrl = '<%=luci.dispatcher.build_url("admin", "services", "acc", "save_token")%>';
      var absUrl = window.location.origin + saveUrl;
      var bmJs = "(function(){try{" +
        "var t=JSON.parse(localStorage.getItem('account_token')).account_token;" +
        "window.open('" + absUrl + "?token='+encodeURIComponent(t),'_blank','width=450,height=250');" +
        "}catch(e){alert('请先在 leigod.com 登录!\\n错误:'+e.message);}})();";
      document.getElementById('bm_link').href = 'javascript:' + encodeURIComponent(bmJs);
    })();

    function ap_update_table(data) {
      var table = document.getElementById("ap_status_table");
      if (!table || !data) return;
      while (table.rows.length > 1) table.deleteRow(1);

      var items = [
        ["脚本", data.script_installed ? "&#x2705; 已安装" : "&#x26A0; 未安装"],
        ["令牌", data.token_configured ? "&#x2705; " + data.token_masked : "&#x26A0; 未配置"],
        ["离家模式", data.manual_disable == "1" ? "&#x1F3E0; 已启用 (自动暂停禁用)" : "自动模式"],
        ["定时任务", data.cron_enabled ? "&#x2705; 已启用 (每2分钟)" : "&#x26A0; 已禁用"],
        ["空闲计数", data.idle_count + " / " + data.idle_checks],
        ["上次暂停", data.last_pause_text],
        ["冷却中", data.in_cooldown ? "冷却中" : "就绪"]
      ];

      for (var i = 0; i < items.length; i++) {
        var tr = table.insertRow(-1);
        tr.insertCell(-1).innerHTML = '<strong>' + items[i][0] + '</strong>';
        tr.insertCell(-1).innerHTML = items[i][1];
      }

      var cron_btn = document.getElementById("cbid.accelerator.system._ap_toggle_cron");
      if (cron_btn) {
        cron_btn.value = data.cron_enabled ? "禁用自动暂停定时任务" : "启用自动暂停定时任务";
        cron_btn.className = data.cron_enabled ? "cbi-button cbi-button-reset" : "cbi-button cbi-button-apply";
      }
    }

    function ap_save_token() {
      var token = document.getElementById('ap_quick_token').value.trim();
      var msg = document.getElementById('ap_save_msg');
      if (!token || token.length < 10) {
        msg.style.display = 'block'; msg.style.color = '#c00';
        msg.textContent = 'Token 无效，请粘贴完整 token'; return;
      }

      var x = new XMLHttpRequest();
      x.open('POST', '<%=luci.dispatcher.build_url("admin", "services", "acc", "save_token")%>', true);
      x.setRequestHeader('Content-Type', 'application/json');
      x.onload = function() {
        var r = JSON.parse(x.responseText || '{}');
        msg.style.display = 'block';
        if (r.result === 'OK') {
          msg.style.color = '#080'; msg.textContent = 'Token 已保存!';
          document.getElementById('ap_quick_token').value = '';
          ap_poll(); // refresh status
        } else {
          msg.style.color = '#c00'; msg.textContent = '保存失败: ' + (r.message || x.status);
        }
      };
      x.onerror = function() {
        msg.style.display = 'block'; msg.style.color = '#c00';
        msg.textContent = '网络错误，无法连接路由器';
      };
      x.send(JSON.stringify({token: token}));
    }

    function ap_toggle_cron() {
      var cron_btn = document.getElementById("cbid.accelerator.system._ap_toggle_cron");
      var enable = cron_btn && cron_btn.value.indexOf("启用") >= 0 ? 1 : 0;
      XHR.get('<%=luci.dispatcher.build_url("admin", "services", "acc", "ap_toggle")%>' + '?enable=' + (enable ? '1' : '0'), null, function(x) {
        setTimeout(function() { ap_poll(); }, 500);
      });
    }

    function ap_trigger_pause() {
      if (!confirm("确认手动暂停? 将调用雷神 API。")) return;
      XHR.get('<%=luci.dispatcher.build_url("admin", "services", "acc", "ap_trigger")%>', null, function(x) {
        try {
          var resp = JSON.parse(x.responseText);
          alert(resp.message || resp.result);
        } catch(e) {
          alert("请求失败: " + (x.statusText || "网络错误"));
        }
        setTimeout(function() { ap_poll(); }, 1000);
      });
    }

    function ap_poll() {
      XHR.get('<%=luci.dispatcher.build_url("admin", "services", "acc", "ap_status")%>', null, function(x, st) {
        try {
          var data = JSON.parse(x.responseText);
          ap_update_table(data);
        } catch(e) { /* silently retry on next poll */ }
      });
    }

    document.addEventListener("DOMContentLoaded", function() {
      var trigger_btn = document.getElementById("cbid.accelerator.system._ap_trigger");
      if (trigger_btn) {
        trigger_btn.type = "button";
        trigger_btn.onclick = function(e) { e.preventDefault(); ap_trigger_pause(); };
      }
      var cron_btn = document.getElementById("cbid.accelerator.system._ap_toggle_cron");
      if (cron_btn) {
        cron_btn.type = "button";
        cron_btn.onclick = function(e) { e.preventDefault(); ap_toggle_cron(); };
      }
    });

    // Away mode checkbox: event delegation (CBI renders checkboxes after DOMContentLoaded)
    document.addEventListener('change', function(e) {
      if (e.target.name && e.target.name.match('_ap_manual$')) {
        XHR.get('<%=luci.dispatcher.build_url("admin", "services", "acc", "ap_save")%>?manual_disable=' + (e.target.checked ? '1' : '0'), null, function() {
          ap_poll();
        });
      }
    });

    ap_poll();
    setInterval(ap_poll, 10000);
//]]></script>

HTMEOF

        # Non-patched LuCI files (deleted by official installer's uninstall step)
        cat > "$luci_src/model/cbi/leigod/device.lua" << 'LUAEOF'
local uci     = require "luci.model.uci".cursor()
local util    = require "luci.util"
local fs      = require "nixio.fs"
local pairs   = pairs
local io      = io

-- config
m             = Map("accelerator")
m.title       = "雷神设备配置"
m.description = "管理加速设备"

-- get neigh info
neigh         = m:section(NamedSection, "base", "system", "监听接口")
neigh_tab     = neigh:option(ListValue, "neigh", "加速接口")
local sys_dir = util.exec("ls /sys/class/net")
if sys_dir ~= nil then
  neigh_tab:value("br-lan")
  for ifc in string.gmatch(sys_dir, "[^\n]+") do
    neigh_tab:value(ifc)
  end
end

-- range all device
device = m:section(NamedSection, "device", "hardware", "设备信息")
device:tab("none_catalog", "未分类")
device:tab("phone_catalog", "手机")
device:tab("pc_catalog", "电脑")
device:tab("game_catalog", "游戏主机")
device:tab("vr_catalog", "VR设备")
device:tab("unknown_catalog", "未知设备")


local dhcp_map = {}
-- check dhcp file
if fs.access("/tmp/dhcp.leases") then
  for line in io.lines("/tmp/dhcp.leases") do
    -- check if read empty line
    if line == "" then
      break
    end
    -- split line
    local valueSl = string.gmatch(line, "[^ ]+")
    -- read time
    valueSl()
    -- read mac
    local mac = valueSl() or ""
    -- get ip
    local ip = valueSl() or ""
    -- get host name
    local hostname = valueSl() or ""
    -- skip malformed entries
    if not (mac == "" or mac:match("^%*")) then
      -- key
      local key = string.gsub(mac, ":", "")
      -- store key
      dhcp_map[key] = {
        ["key"] = key,
        ["mac"] = mac,
        ["ip"] = ip,
        ["name"] = hostname
      }
    end
  end
end

ifc = uci:get("accelerator", "base", "neigh")
if ifc == nil then
  ifc = "br-lan"
end

local arp_map = {}
-- check if arp exist
if fs.access("/proc/net/arp") then
  -- read all item from arp
  for line in io.lines("/proc/net/arp") do
    -- check if line is not exist
    if line == "" then
      break
    end
    -- split item
    local valueSl = string.gmatch(line, "[^ ]+")
    -- get ip
    local ip = valueSl()
    -- get type
    valueSl()
    -- get flag
    local flag = valueSl()
    -- get mac
    local mac = valueSl() or ""
    -- get mask
    valueSl()
    -- get device
    local dev = valueSl() or ""
    -- get key
    if not (mac == "" or mac:match("^%*")) then
      local key = string.gsub(mac, ":", "")
      -- check if device and flag state
      if dev == ifc and flag == "0x2" then
        -- get current name
        local name = mac
        if dhcp_map[key] ~= nil then
          name = dhcp_map[key].name or mac
          if name == "*" then name = mac end
        end
        arp_map[key] = {
          ["key"] = key,
          ["mac"] = mac,
          ["ip"] = ip,
          ["name"] = name
        }
      end
    end
  end
end

-- get device config
for key, item in pairs(arp_map) do
  local typ = uci:get("accelerator", "device", key)
  -- get device catalog from type
  local catalog = "none_catalog"
  -- default to unknown device
  if typ == nil then
    typ = 9
  else
    typ = tonumber(typ)
  end

  if typ == nil then
    catalog = "unknown_catalog"
  elseif typ >= 1 and typ <= 3 then
    catalog = "game_catalog"
  elseif typ >= 4 and typ <= 6 then
    catalog = "pc_catalog"
  elseif typ >= 7 and typ <= 8 then
    catalog = "phone_catalog"
  elseif typ >= 20 and typ <= 21 then
    catalog = "vr_catalog"
  else
    catalog = "unknown_catalog"
  end
  -- device type
  device_typ = device:taboption(catalog, ListValue, key, item.name)
  device_typ:value("0", "未设置")
  device_typ:value("1", "XBox")
  device_typ:value("2", "Switch")
  device_typ:value("3", "PlayStation")
  device_typ:value("4", "Steam Deck")
  device_typ:value("5", "Windows")
  device_typ:value("6", "MacBook")
  device_typ:value("7", "安卓手机")
  device_typ:value("8", "iPhone")
  device_typ:value("20", "Oculus")
  device_typ:value("21", "HTC Vive")
  device_typ:value("22", "Pico")
  device_typ:value("9", "未知")
end

-- set
device.write = function()
  util.exec("/etc/init.d/acc restart")
end

return m

LUAEOF

        cat > "$luci_src/model/cbi/leigod/app.lua" << 'LUAEOF'
require("luci.util")

mp = Map("accelerator")

mp:section(SimpleSection).template  = "leigod/app"

return mp

LUAEOF

        cat > "$luci_src/model/cbi/leigod/debug.lua" << 'LUAEOF'
require("luci.util")

mp = Map("accelerator")

mp:section(SimpleSection).template = "leigod/debug"

return mp

LUAEOF

        cat > "$luci_src/view/leigod/app.htm" << 'HTMEOF'
<fieldset class="cbi-section">
  <legend>雷神加速器 APP</legend>
  <p>下载 <b>雷神加速器</b> APP:</p>
  <p><a href="https://www.leigod.com" target="_blank">https://www.leigod.com</a></p>
  <p>绑定路由器: 打开 APP → 硬件加速 → 安装路由器插件</p>
</fieldset>

HTMEOF

        cat > "$luci_src/view/leigod/notice.htm" << 'HTMEOF'
<fieldset>
  <legend>声明</legend>
  此插件为 LEDE/QWRT 官方合作版插件, 需要配合雷神手机APP使用
  </p>
  <legend>更新信息</legend>
  <p>
    2024-8-1 <br>
    支持LEDE/QWRT性能优化 <br>
    2024-7-25 <br>
    支持非桥接模式下的旁路由 <br>
    2024-6-5 <br>
    扩充ipset容量, 以支持大容量代理ip库 <br>
    2024-1-22 <br>
    新增自动选择低延迟线路 <br>
    新增下载不限速(switch除外) <br>
    设备名为*时, 显示mac地址 <br>
    <hr/>
    2023-11-28 <br>
    新增对mips设备的支持 <br>
    新增对旁路由的支持 <br>
    解决翻译异常的问题 <br>
    设备管理页面可以显示未识别设备 <br>
  </p>
  <legend>安装依赖</legend>
  <p>
    插件运行需要借助一些依赖才能运行, 一般第三方固件默认已经集成了大部分的依赖, <br>
    如果使用的是openwrt官方的固件, 则需要确保依赖安装好了, 以下列出依赖包和注意事项 <br>
    libpcap <br>
    iptables <br>
    kmod-ipt-nat <br>
    iptables-mod-tproxy <br>
    kmod-ipt-tproxy <br>
    kmod-netem(非必须, 针对于一些icmp测速的游戏使用, 只影响界面显示, 实际游戏效果不影响) <br>
    tc-full(非必须, 同kmod-netem) <br>
    kmod-ipt-ipset <br>
    ipset <br>
    curl(谨慎更新, 某些三方固件升级curl, 会导致curl出现问题) <br>
  </p>
  <legend>网桥模式</legend>
  <p>
    加速插件无法探知当前插件应该使用什么模式,  <br>
    当前默认使用网桥作为流量转发的设备, <br>
    如果使用旁路由模式或者docker时, 此时默认设备不是网桥, <br>
    此时需要手动调整接口, <br>
    改变接口的地址在 设备管理->路由设备, 选择对应的设备 <br>
  </p>
  <legend>加速模式</legend>
    <p>
    当前雷神路由器支持两种加速模式, tproxy 和 tun <br>
    当前默认采用的是tproxy模式, 原因在于tproxy有更好的性能<br>
    tun模式暂时屏蔽, 后续luci会完善一键切换模式
    </p>
  <legend>使用说明</legend>
    <p>
    当前雷神加速插件是根据设备类型进行加速的, 也就是说, 如果加速了相应的类型后, 理论上只要连接该路由器的设备都将获得加速效果<br>
    当前支持的设备类型有以下几种:  <br>
    手机:  Android iPhone <br>
    电脑:  Windows MacOS SteamDeck <br>
    主机:  XBox Switch PlayStation <br>
    未识别: Others  <br>
    可以在设备管理中, 插件自己的设备是否被成功识别成对应的设备, 如果不是, 可以选择对应的设备, 这样设备就能成功加速了 <br>
    </p>
    <p>
    一些特殊的说明: <br>
    关于ios设备, 最好是在安装插件之前, 先忘记网络, 等安装完插件后, 再重新连接网络 <br>
    关于android设备, 需要关闭dhcpv6后, 手机重连网络, 以下给出一个 /etc/config/dhcp 的配置 <br>
    config dhcp 'lan'  <br>
    ... 此处是一些其他配置 <br>
    ra 'disable'  <br>
    dhcpv6 'disable' <br>
    list ra_flags 'none' <br>
    ... 此处是一些其他配置 <br>
    </p>
</fieldset>

HTMEOF

        # view/leigod/debug.htm — diagnostic page
        mkdir -p "$luci_src/view/leigod"
        cat > "$luci_src/view/leigod/debug.htm" << 'HTMEOF'
<!-- fw4 adapted: Diagnostic debug page -->
<fieldset class="cbi-section">
  <legend>诊断报告</legend>
  <div class="cbi-value" id="debug_status_bar" style="padding:6px 0">
    <div id="debug_status_text" style="font-weight:bold">加载中...</div>
  </div>
  <div id="debug_issues" style="margin-bottom:8px"></div>
  <div style="width:100%; background:#1e1e1e; border:1px solid #3c3c3c; border-radius:3px; overflow:auto; max-height:70vh">
    <pre id="debug_output" style="margin:0; padding:12px; font-family:'Courier New',monospace; font-size:13px; line-height:1.35; white-space:pre; color:#ccc; background:transparent; border:none">加载诊断数据...</pre>
  </div>
  <div class="cbi-page-actions" style="margin-top:12px">
    <button class="cbi-button cbi-button-apply" onclick="debug_refresh()">刷新</button>
    <button class="cbi-button cbi-button-action" onclick="debug_copy()">复制报告</button>
  </div>
</fieldset>

<script type="text/javascript">//<![CDATA[
var DEBUG_POLL_MS = 15000, _debug_data = null;

function debug_refresh() {
  var x = new XMLHttpRequest();
  x.onreadystatechange = function() {
    if (x.readyState !== 4 || x.status !== 200) return;
    try { _debug_data = JSON.parse(x.responseText); debug_render(_debug_data); }
    catch(e) { debug_show_err('解析失败: ' + e.message); }
  };
  x.open('GET', '<%=luci.dispatcher.build_url("admin", "services", "acc", "debug_status")%>', true);
  x.send();
}

function debug_render(data) {
  if (!data) { debug_show_err('无数据'); return; }
  var to = function(s) { return (s||'N/A').replace(/</g,'&lt;').replace(/>/g,'&gt;'); };
  var yn = function(b) { return b ? 'Yes' : 'No'; };
  var ok = function(b) { return b ? 'PASS' : 'FAIL'; };

  // Status bar
  var allClear = data.checks_total > 0 && data.checks_failed === 0 && data.checks_warn === 0;
  var hasErrors = data.checks_failed > 0, hasWarns = data.checks_warn > 0;
  var color = allClear ? '#080' : (hasErrors ? '#c00' : '#b85c00');
  var txt = allClear ? '全部通过 ('+data.checks_passed+'/'+data.checks_total+')'
    : data.checks_passed+'/'+data.checks_total+' 通过'+(hasErrors?', '+data.checks_failed+' 失败':'')+(hasWarns?', '+data.checks_warn+' 警告':'');
  document.getElementById('debug_status_text').innerHTML = '<span style="color:'+color+'">'+txt+'</span>';

  // Issues
  var issDiv = document.getElementById('debug_issues'); issDiv.innerHTML = '';
  if (data.issues && data.issues.length > 0) {
    for (var i = 0; i < data.issues.length; i++) {
      var iss = data.issues[i];
      var bg = iss.severity==='error'?'#ffe0e0':(iss.severity==='warning'?'#fff8e0':'#e0f0ff');
      var fg = iss.severity==='error'?'#c00':(iss.severity==='warning'?'#b85c00':'#036');
      issDiv.innerHTML += '<div style="padding:4px 8px;margin:2px 0;border-radius:2px;background:'+bg+';color:'+fg+';font-weight:bold;font-size:13px">'+(iss.severity==='error'?'✘ ':'⚠ ')+iss.message+'</div>';
    }
  }

  // === Build aligned text report ===
  var L = [];
  // Chinese-aware visual width for alignment
  var vl = function(s) { var w=0; for(var i=0;i<s.length;i++) w+=s.charCodeAt(i)>127?2:1; return w; };
  var pd = function(s,w) { var n=w-vl(s); return n>0?s+' '.repeat(n):s+' '; };
  var COL = 14; // label column width (Chinese chars)
  var rw = function(label, value) { L.push('  '+pd(label,COL)+' │ '+value); };
  var sec = function(title) { L.push(''); L.push('── '+title); };

  var now = new Date();
  L.push('═══════════════════════════════════════');
  L.push('  Leigod Accelerator 诊断报告');
  L.push('  '+now.toLocaleString());
  L.push('═══════════════════════════════════════');

  sec('系统信息');
  rw('固件',to(data.system.firmware)); rw('内核',to(data.system.kernel));
  rw('架构',to(data.system.arch)); rw('防火墙',to(data.system.firewall_type));
  rw('LAN IP',to(data.system.lan_ip)+' / '+to(data.system.lan_mask));
  rw('运行时间',to(data.system.uptime));

  sec('进程状态');
  rw('运行中',yn(data.process.running)); rw('PID',to(data.process.pid));
  rw('内存(VSZ)',to(data.process.vsz_kb)+' KB'); rw('模式',to(data.process.mode_cmdline)+(data.process.mode_ok?'':' [INVALID]'));
  rw('端口 5588',yn(data.process.port_listening)); rw('开机自启',yn(data.process.init_enabled));

  sec('Init 脚本 (/etc/init.d/acc)');
  rw('文件存在',yn(data.init_script.exists)); rw('Args 行',to(data.init_script.args_line));
  rw('模式标志',to(data.init_script.mode_flag)+' → '+to(data.init_script.mode_name));
  rw('短格式(-m)',yn(data.init_script.short_format)); rw('有 -p 端口',yn(data.init_script.has_port));

  if (data.core_config) {
    var cfg = data.core_config;
    sec('运行时配置 (acc_core_conf.json)');
    rw('文件存在',yn(cfg.exists));
    if (cfg.exists) { rw('tproxy_ip',to(cfg.tproxy_ip)+' ['+ok(cfg.tproxy_ip_ok)+']'); rw('acc_mode',to(cfg.acc_mode_name)+' ['+ok(cfg.acc_mode_ok)+']'); }
  }

  sec('网络与防火墙');
  rw('TUN 接口',to(data.network.tun_iface||'无')); rw('FW 5588',yn(data.network.fw_rule_5588));
  rw('Hotplug',yn(data.network.hotplug)); rw('TURN 中继',ok(data.network.turn_reachable)+' (route-turn.xxghh.biz)');
  rw('API 端点','HTTP '+to(data.network.api_http_code)+' ['+ok(data.network.api_reachable)+']');
  rw('GAMEACC 链',yn(data.network.gameacc_exists));
  if (data.network.gameacc_sample && data.network.gameacc_sample !== 'N/A') L.push('  '+pd('',COL)+' │ '+to(data.network.gameacc_sample));

  // Latency
  if (data.latency) {
    sec('延迟诊断 (ping 5次, ms)');
    L.push('  '+pd('目标',30)+'Min     Avg     Max     丢包');
    L.push('  '+pd('─'.repeat(28),30)+'─────  ─────  ─────  ────');
    var pRow = function(lb,r) {
      var s = '  '+pd(lb,30);
      s += pd(r.min||'?',7)+' '+pd(r.avg||'?',7)+' '+pd(r.max||'?',7)+(r.loss||'?')+'%';
      return s;
    };
    if (data.latency.gateway) L.push(pRow('网关 ('+(data.latency.gateway.host||'')+')',data.latency.gateway));
    if (data.latency.dns) L.push(pRow('DNS ('+(data.latency.dns.host||'')+')',data.latency.dns));
    if (data.latency.turn) L.push(pRow('TURN 中继 ('+(data.latency.turn.host||'')+')',data.latency.turn));
    if (data.latency.nodes && data.latency.nodes.length > 0) {
      L.push(''); L.push('  加速节点 (雷神分配):');
      L.push('  IP 地址              测速延迟');
      L.push('  ──────────────────   ────────');
      for (var i = 0; i < Math.min(data.latency.nodes.length,9); i++) {
        var n = data.latency.nodes[i];
        L.push('  '+pd(n.ip||'?',20)+(n.ping_ms||'?')+' ms');
      }
    }
    var gwAvg = parseFloat((data.latency.gateway||{}).avg);
    var turnAvg = parseFloat((data.latency.turn||{}).avg);
    if (!isNaN(gwAvg) && gwAvg > 10) L.push('  ⚠ 网关延迟 >10ms → 检查 WiFi/LAN 干扰');
    if (!isNaN(gwAvg) && !isNaN(turnAvg) && turnAvg-gwAvg > 50) L.push('  ⚠ TURN-网关 = '+(turnAvg-gwAvg).toFixed(0)+'ms → 宽带/服务器延迟');
  }

  sec('依赖包');
  var pkgs = data.packages || {}, pKeys = Object.keys(pkgs).sort();
  for (var ki = 0; ki < pKeys.length; ki++) rw(pKeys[ki],yn(pkgs[pKeys[ki]]));

  sec('设备加速状态');
  var devs = data.devices || { Phone:'None',PC:'None',Game:'None',Unknown:'None' };
  for (var dn in devs) rw(dn,to(devs[dn]));

  if (data.autopause) {
    var ap = data.autopause;
    sec('自动暂停');
    rw('脚本',yn(ap.script_installed));
    rw('手动令牌',ap.token_configured?to(ap.token_masked)+' [OK]':'未配置 ['+ok(false)+']');
    rw('离家模式',ap.manual_disable=='1'?'已启用 (自动暂停禁用)':'自动模式');
    rw('daemon 令牌',yn(ap.daemon_token_ok)+' (从 acc_core_conf.json 提取)');
    rw('定时任务',yn(ap.cron_enabled));
  }

  sec('acc-gw 内部错误日志 (/tmp/acc/log/)');
  var errLogs = data.error_logs || [];
  if (errLogs.length > 0) for (var i = 0; i < errLogs.length; i++) L.push('  ['+errLogs[i].file+'] '+to(errLogs[i].line));
  else L.push('  (无错误)');

  sec('最近系统日志 (logread)');
  var logs = data.logs || [];
  if (logs.length > 0) for (var i = 0; i < logs.length; i++) L.push('  '+to(logs[i]));
  else L.push('  (无相关日志)');

  L.push(''); L.push('═══════════════════════════════════════'); L.push('  报告结束');
  document.getElementById('debug_output').textContent = L.join('\n');
}

function debug_show_err(msg) {
  document.getElementById('debug_status_text').innerHTML = '<span style="color:#c00">'+msg+'</span>';
  document.getElementById('debug_output').textContent = 'ERROR: '+msg;
}

function debug_copy() {
  var text = document.getElementById('debug_output').textContent;
  if (navigator.clipboard && navigator.clipboard.writeText) {
    navigator.clipboard.writeText(text).then(function() {
      var s = document.getElementById('debug_status_text'), old = s.innerHTML;
      s.innerHTML = '<span style="color:#080">已复制到剪贴板</span>';
      setTimeout(function(){s.innerHTML=old},2000);
    });
  } else {
    var ta = document.createElement('textarea'); ta.value = text;
    ta.style.position='fixed'; ta.style.left='-9999px';
    document.body.appendChild(ta); ta.select();
    document.execCommand('copy'); document.body.removeChild(ta);
  }
}

document.addEventListener('DOMContentLoaded', function() {
  debug_refresh(); setInterval(debug_refresh, DEBUG_POLL_MS);
});
//]]></script>

HTMEOF

        echo "[INFO] LuCI fw4 适配补丁已应用 (含自动暂停页面+诊断调试页)"

    else
        echo "[INFO] 正在从 $patch_dir 部署 LuCI fw4 补丁..."
        cp -r "$patch_dir/luasrc"/* "$luci_src/"
        echo "[INFO] LuCI fw4 适配补丁已应用 (from $patch_dir)"
    fi

    # Clear LuCI cache so changes take effect
    rm -rf /tmp/luci-*
    echo "[INFO] LuCI 缓存已清除，刷新 Web 页面即可看到更新"
}

# ============================================================
# Menu
# ============================================================
leigod_menu() {
    echo
    echo "============================="
    echo "OpenWrt LeigodAcc Manager"
    echo "防火墙: $FW_NAME"
    echo
    echo "1. 安装"
    echo "2. 卸载"
    echo "3. 重装/更新"
    echo "4. 禁用/启用 雷神服务"
    echo "5. 切换运行模式   (TUN/Tproxy)"
    echo "6. 安装兼容性依赖 (主机优化)"
    echo "7. 禁用/启用 IPv6 (手机优化)"
    echo "8. 安装 Lean IPKG 版"
    echo "9. 自动暂停时长   (省时长)"
    echo "S. 查看服务状态   (诊断)"
    echo "L. 延迟波动诊断   (bufferbloat/QoS)"
    echo "T. 内核网络调优   (低延迟优化)"
    echo "H. 反馈/帮助"
    echo "0. 退出"
    echo "============================="
    echo -n "选择数字/字母并回车执行: "
}

# ============================================================
# Install LeigodAcc
# ============================================================
install_leigodacc() {
    if [ -d /usr/sbin/leigod ]; then
        echo -n "[INFO] 检测到已经安装 LeigodAcc ([1]继续安装 / [2]取消): "
        read choice
        case "$choice" in
            1)
                ;;
            2)
                return
                ;;
            *)
                echo "[ERROR] 无效的选项，请重新输入"
                return
                ;;
        esac
    fi

    if [ -f /etc/catwrt_release ]; then
        if ! grep -q -E "catwrt|repo.miaoer.xyz" /etc/opkg/distfeeds.conf; then
            echo "[ERROR] 检测到 CatWrt，请先配置 CatWrt 软件源，请使用:"
            echo "Cattools - Apply_repo"
            echo
            echo "在正确启用软件源后即可获取雷神加速器插件完整支持(可能)"
            cattools
            return
        fi
    else
        [ -f /etc/opkg/customfeeds.conf ] && { echo "[customfeeds.conf]"; cat /etc/opkg/customfeeds.conf; } || echo "[INFO] customfeeds.conf 不存在"
        [ -f /etc/opkg/distfeeds.conf ] && { echo "[distfeeds.conf]"; cat /etc/opkg/distfeeds.conf; } || echo "[INFO] distfeeds.conf 不存在"
        if [ ! -f /usr/bin/cattools ]; then
            echo "[AD] 你还没有安装 Cattools 以方便安装 LeigodAcc 中依赖部分缺少的组件"
            echo "请查看 https://github.com/miaoermua/cattools 或使用"
            echo "推荐 CatWrt 最新版 https://www.miaoer.net/network/catwrt"
            echo ""
        fi
    fi

    release_info=$(cat /etc/openwrt_release)
    if echo "$release_info" | grep -qE "iStoreOS|QWRT|ImmortalWrt|LEDE"; then
        echo "Detected third-party firmware: $(echo "$release_info" | grep -E "iStoreOS|QWRT|ImmortalWrt|LEDE")"
    fi

    # Check disk space before installing
    if ! check_disk_space; then
        return 1
    fi

    if [ -e /var/lock/opkg.lock ]; then
        if pgrep -x "opkg" > /dev/null 2>&1; then
            echo "[WARN] 检测到其他 opkg 进程正在运行，等待完成 (最多30秒)..."
            local _i=0
            while [ $_i -lt 30 ] && pgrep -x "opkg" > /dev/null 2>&1; do
                sleep 2
                _i=$((_i + 2))
            done
        fi
        # Only remove lock if no opkg is currently running
        if ! pgrep -x "opkg" > /dev/null 2>&1; then
            rm -f /var/lock/opkg.lock
        else
            echo "[WARN] opkg 仍在运行, 保留锁文件"
        fi
    fi
    if ! check_network; then
        echo "[WARN] 网络不可达，后续 opkg update 及下载可能会失败"
        echo -n "是否继续? (y/n): "
        read proceed
        [ "$proceed" != "y" ] && [ "$proceed" != "Y" ] && return
    fi

    # Install essential packages based on firewall type
    echo "[INFO] 安装必备组件 (防火墙: $FW_NAME)..."
    OPKG_FAILED=""
    for pkg in $(get_essential_packages); do
        if ! opkg list-installed | grep -q "$pkg"; then
            safe_opkg_install "$pkg"
        else
            echo "[INFO] $pkg 必备组件已安装，跳过"
        fi
    done

    # Install optional/enhanced packages
    echo "[INFO] 安装增强组件..."
    for pkg in $(get_optional_packages); do
        if ! opkg list-installed | grep -q "$pkg"; then
            safe_opkg_install "$pkg"
        else
            echo "[INFO] $pkg 已安装，跳过"
        fi
    done

    # fw4: ensure TPROXY kernel support (with fallback)
    if ! ensure_fw4_tproxy; then
        echo "[WARN] TPROXY 不可用。注意: 部分 acc-gw 版本仅支持 TPROXY，此情况下加速将无法工作"
    fi

    # Setup fw4 integration if needed
    setup_fw4_integration
    # fw4: patch upstream LuCI interface if installed
    if [ -d /usr/lib/lua/luci/controller ]; then
        # Ensure luci-compat is present (required for Lua CBI on modern LuCI)
        if ! opkg list-installed 2>/dev/null | grep -q "^luci-compat"; then
            echo "[INFO] 安装 luci-compat (LuCI Lua CBI 兼容层)..."
            safe_opkg_install luci-compat
        fi
        apply_luci_fw4_patch
    fi

    # UPnP for device discovery
    if ! opkg list-installed | grep -q 'luci-app-upnp'; then
        safe_opkg_install luci-app-upnp
    fi

    if [ -f /etc/config/upnpd ]; then
        echo "[INFO] 正在启用 UPnP..."
        uci set upnpd.config.enabled='1'
        uci commit upnpd

        /etc/init.d/miniupnpd start
        /etc/init.d/miniupnpd enable

        echo "[INFO] UPnP 已启用并运行"
        echo "安装成功后可以在雷神加速器 APP 发现并绑定设备"
        echo
    else
        echo "[ERROR] UPnP 配置不存在，安装可能失败，请检查固件!"
        return 1
    fi

    echo "[INFO] 下面是雷神官方提供的脚本,打印内容偏长如遇到问题请提供输出内容(截图/文字)反馈到群里."

    install_script=$(curl -fsSL --connect-timeout 10 --max-time 60 \
        https://119.3.40.126/router_plugin_new/plugin_install.sh 2>/dev/null || \
        curl -fsSL --connect-timeout 10 --max-time 60 \
        http://119.3.40.126/router_plugin_new/plugin_install.sh 2>/dev/null)
    if [ -z "$install_script" ]; then
        echo "[ERROR] 无法下载雷神官方安装脚本！请检查网络或雷神服务器状态"
        return 1
    fi
    cd /tmp && echo "$install_script" | sh

    if [ ! -d /usr/sbin/leigod ]; then
        echo "[ERROR] 检测到 LeigodAcc 未安装，有可能是设备存储空间已满或者雷神服务器挂了!"
        echo "请登录 OpenWrt 路由器后台: 系统-软件包 查看当前可用空间诊断."
    else
        echo "[INFO] LeigodAcc 已成功安装"

        # Initialize UCI config for LuCI pages (device.lua needs base/device sections)
        ensure_uci_config

        # fw4: the official installer writes --mode tun (GNU long format)
        # which the acc-gw binary silently ignores, defaulting to TPROXY.
        # Correct it to the short format (-m tun) that the binary recognizes.
        if grep -q -- "--mode tun" /etc/init.d/acc 2>/dev/null; then
            sed -i 's|--mode tun|-m tun|' /etc/init.d/acc
            echo "[INFO] 已修正加速模式参数格式 (--mode tun → -m tun)"
        elif grep -q -- "--mode tproxy" /etc/init.d/acc 2>/dev/null; then
            sed -i 's|--mode tproxy|-m tproxy|' /etc/init.d/acc
            echo "[INFO] 已修正加速模式参数格式 (--mode tproxy → -m tproxy)"
        fi

        setup_iptables_nft_compat

        # fw4: the official installer removes existing LuCI files as part of
        # its uninstall step. If LuCI was previously installed (e.g. via
        # option 8/IPK), re-apply fw4 patches to restore them.
        if [ "$FW_TYPE" = "fw4" ]; then
            apply_luci_fw4_patch
            # Verify: ensure critical LuCI files were actually written.
            # The official installer's uninstall step deletes them, and
            # apply_luci_fw4_patch should restore all 12 files. If any
            # are missing, warn the user immediately.
            local luci_missing=""
            for f in /usr/lib/lua/luci/controller/acc.lua \
                     /usr/lib/lua/luci/model/cbi/leigod/service.lua \
                     /usr/lib/lua/luci/model/cbi/leigod/device.lua \
                     /usr/lib/lua/luci/model/cbi/leigod/autopause.lua \
                     /usr/lib/lua/luci/view/leigod/debug.htm; do
                [ ! -f "$f" ] && luci_missing="$luci_missing  $f\n"
            done
            if [ -n "$luci_missing" ]; then
                echo "[WARN] LuCI 文件缺失! 可能是补丁目录未上传或内联写入失败:"
                printf "$luci_missing"
                echo "[INFO] 请确保 luci-fw4-patch/ 目录已上传到 /tmp/ 或 /root/"
                echo "[INFO] 或手动运行: leigod-fw4.sh 内联补丁将自动写入"
            else
                echo "[INFO] LuCI fw4 适配文件完整性验证: 通过"
            fi
        fi

        # Install tproxy_ip watcher cron (daemon regenerates JSON with fake IP)
        install_tproxy_watcher

        # Inform user about LuCI and TUN mode
        echo ""
        echo "=========================================="
        echo "  [提示] LuCI 网页管理 & 加速模式"
        echo "=========================================="
        if [ -f /usr/lib/lua/luci/controller/acc.lua ]; then
            echo "  LuCI 网页界面: 已就绪"
            echo "  可通过路由器 Web 后台 → 服务 → Leigod Acc 访问"
        else
            echo "  LuCI 网页界面: 未安装"
            echo "  如需要 Web 后台管理，请使用菜单选项 8"
            echo "  安装 Lean IPKG 版 (含 luci-app-leigod-acc)"
        fi
        echo "=========================================="
        echo ""
    fi

    # Post-install check
    echo "[INFO] 正在执行安装后检查..."
    for pkg in $(get_check_packages); do
        if ! opkg list-installed | grep -q "$pkg"; then
            echo "[WARN] 缺少组件包: $pkg"
            echo "[INFO] 你可以通过管理器中的安装依赖性组件进行补充!"
        fi
    done

    if [ "$FW_TYPE" = "fw4" ]; then
        echo ""
        echo "=========================================="
        echo "  [重要] fw4 防火墙 — 环境适配"
        echo "=========================================="
        echo "  当前系统使用 fw4/nftables 防火墙。"
        echo "  请确保 acc_core_conf.json 中 tproxy_ip"
        echo "  正确设置为路由器 LAN IP。"
        echo ""
        echo "  运行菜单选项 S (诊断) 可自动检测和修复。"
        echo "=========================================="
        echo ""

        # Initialize UCI config for LuCI pages
        ensure_uci_config
        # Fix acc_core_conf.json if needed (covers both fresh and re-installs)
        fix_acc_core_conf
        # Install tproxy_ip watcher cron
        install_tproxy_watcher

        echo -n "是否需要检查服务运行状态? (y/n, 默认 n): "
        read check_status
        case "$check_status" in
            [Yy]|[Yy][Ee][Ss])
                check_service_status
                ;;
            *)
                echo "[INFO] 可稍后通过菜单选项 S 查看"
                ;;
        esac
        echo ""
    fi

    # Run LuCI integrity verification after install
    if [ -d /usr/lib/lua/luci/controller ]; then
        verify_luci
    fi
}

# ============================================================
# Install compatibility dependencies
# ============================================================
install_compatibility_dependencies() {
    if ! check_disk_space; then
        return 1
    fi

    arch=$(opkg print-architecture | grep "arch" | awk '{print $2}' | grep -vE "all|noarch" | head -1)
    if [ -z "$arch" ]; then
        echo "[ERROR] 无法确定系统架构"
        return
    fi

    # For fw4, try official repos first since OpenWrt 24.10 should have these packages
    if [ "$FW_TYPE" = "fw4" ]; then
        echo "[INFO] fw4 系统，优先使用官方软件源安装兼容依赖..."
        for pkg in tc-full conntrack conntrackd; do
            if ! opkg list-installed | grep -q "$pkg"; then
                safe_opkg_install "$pkg"
            else
                echo "[INFO] $pkg 已安装，跳过"
            fi
        done
        # fw4: skip immortalwrt 23.05.3 fallback — those packages are for an older
        # kernel/libc ABI and may fail to install or cause runtime issues.
        echo "[INFO] fw4 系统已通过官方源安装兼容依赖，跳过旧版 immortalwrt 23.05.3 回退"
        if ! ensure_fw4_tproxy; then
            echo "[WARN] TPROXY 不可用。注意: 部分 acc-gw 版本仅支持 TPROXY，此情况下加速将无法工作"
        fi
    fi

    # Fallback: architecture-specific packages (fw3 only; fw4 guarded below)
    if [ "$FW_TYPE" != "fw4" ]; then
    case "$arch" in
        x86_64)
            packages="tc-full conntrack conntrackd libnetfilter-cttimeout1 libnetfilter-cthelper0"
            urls="https://mirrors.pku.edu.cn/immortalwrt/releases/23.05.3/packages/x86_64/packages/libnetfilter-cttimeout1_1.0.0-2_x86_64.ipk
            https://mirrors.pku.edu.cn/immortalwrt/releases/23.05.3/packages/x86_64/packages/libnetfilter-cthelper0_1.0.0-2_x86_64.ipk
            https://mirrors.pku.edu.cn/immortalwrt/releases/23.05.3/packages/x86_64/base/tc-full_6.3.0-1_x86_64.ipk
            https://mirrors.pku.edu.cn/immortalwrt/releases/23.05.3/packages/x86_64/packages/conntrackd_1.4.8-1_x86_64.ipk
            https://mirrors.pku.edu.cn/immortalwrt/releases/23.05.3/packages/x86_64/packages/conntrack_1.4.8-1_x86_64.ipk"
            ;;
        mipsel_24kc)
            packages="tc-full conntrack conntrackd libnetfilter-cttimeout1 libnetfilter-cthelper0"
            urls="https://mirrors.pku.edu.cn/immortalwrt/releases/23.05.3/packages/mipsel_24kc/packages/conntrackd_1.4.8-1_mips_24kc.ipk
            https://mirrors.pku.edu.cn/immortalwrt/releases/23.05.3/packages/mipsel_24kc/packages/conntrack_1.4.8-1_mips_24kc.ipk
            https://mirrors.pku.edu.cn/immortalwrt/releases/23.05.3/packages/mipsel_24kc/packages/libnetfilter-cthelper0_1.0.0-2_mips_24kc.ipk
            https://mirrors.pku.edu.cn/immortalwrt/releases/23.05.3/packages/mipsel_24kc/packages/libnetfilter-cttimeout1_1.0.0-2_mips_24kc.ipk
            https://mirrors.pku.edu.cn/immortalwrt/releases/23.05.3/packages/mipsel_24kc/base/tc-full_6.3.0-1_mips_24kc.ipk"
            ;;
        aarch64_cortex-a53|aarch64_cortex-a53+crypto)
            packages="tc-full conntrack conntrackd libnetfilter-cttimeout1 libnetfilter-cthelper0"
            urls="https://mirrors.pku.edu.cn/immortalwrt/releases/23.05.3/packages/aarch64_cortex-a53/base/tc-full_6.3.0-1_aarch64_cortex-a53.ipk
            https://mirrors.pku.edu.cn/immortalwrt/releases/23.05.3/packages/aarch64_cortex-a53/packages/conntrack_1.4.8-1_aarch64_cortex-a53.ipk
            https://mirrors.pku.edu.cn/immortalwrt/releases/23.05.3/packages/aarch64_cortex-a53/packages/conntrackd_1.4.8-1_aarch64_cortex-a53.ipk
            https://mirrors.pku.edu.cn/immortalwrt/releases/23.05.3/packages/aarch64_cortex-a53/packages/libnetfilter-cttimeout1_1.0.0-2_aarch64_cortex-a53.ipk
            https://mirrors.pku.edu.cn/immortalwrt/releases/23.05.3/packages/aarch64_cortex-a53/packages/libnetfilter-cthelper0_1.0.0-2_aarch64_cortex-a53.ipk"
            ;;
        aarch64_generic|aarch64_cortex-a72*|aarch64_cortex-a76*|aarch64_cortex-a55*|aarch64_cortex-a73*)
            packages="tc-full conntrack conntrackd libnetfilter-cttimeout1 libnetfilter-cthelper0"
            urls="https://mirrors.pku.edu.cn/immortalwrt/releases/23.05.3/packages/aarch64_generic/packages/conntrack_1.4.8-1_aarch64_generic.ipk
            https://mirrors.pku.edu.cn/immortalwrt/releases/23.05.3/packages/aarch64_generic/packages/conntrackd_1.4.8-1_aarch64_generic.ipk
            https://mirrors.pku.edu.cn/immortalwrt/releases/23.05.3/packages/aarch64_generic/packages/libnetfilter-cthelper0_1.0.0-2_aarch64_generic.ipk
            https://mirrors.pku.edu.cn/immortalwrt/releases/23.05.3/packages/aarch64_generic/packages/libnetfilter-cttimeout1_1.0.0-2_aarch64_generic.ipk
            https://mirrors.pku.edu.cn/immortalwrt/releases/23.05.3/packages/aarch64_generic/base/tc-full_6.3.0-1_aarch64_generic.ipk"
            ;;
        arm_cortex-a9*)
            packages="tc-full conntrack conntrackd libnetfilter-cttimeout1 libnetfilter-cthelper0"
            urls="https://mirrors.pku.edu.cn/immortalwrt/releases/23.05.3/packages/arm_cortex-a9/packages/conntrack_1.4.8-1_arm_cortex-a9.ipk
            https://mirrors.pku.edu.cn/immortalwrt/releases/23.05.3/packages/arm_cortex-a9/packages/conntrackd_1.4.8-1_arm_cortex-a9.ipk
            https://mirrors.pku.edu.cn/immortalwrt/releases/23.05.3/packages/arm_cortex-a9/packages/libnetfilter-cthelper0_1.0.0-2_arm_cortex-a9.ipk
            https://mirrors.pku.edu.cn/immortalwrt/releases/23.05.3/packages/arm_cortex-a9/packages/libnetfilter-cttimeout1_1.0.0-2_arm_cortex-a9.ipk
            https://mirrors.pku.edu.cn/immortalwrt/releases/23.05.3/packages/arm_cortex-a9/base/tc-full_6.3.0-1_arm_cortex-a9.ipk"
            ;;
        arm_cortex-a7*|arm_cortex-a15*|arm_cortex-a17*)
            echo "[WARN] 架构 $arch — 无预编译 IPK, 仅尝试 opkg 安装"
            packages="tc-full conntrack conntrackd"
            urls=""
            ;;
        arm_mpcore|arm_xscale)
            echo "[WARN] 架构 $arch 为 ARMv5，第三方源可能不兼容"
            echo "[WARN] 建议使用固件自带软件源安装依赖，或升级设备固件"
            packages=""
            # ARMv5: no compatible pre-built packages — skip manual downloads
            return
            ;;
        *)
            echo "[ERROR] 不支持的架构: $arch"
            return
            ;;
    esac

    for pkg in $packages; do
        if ! opkg list-installed | grep -q "$pkg"; then
            safe_opkg_install "$pkg"
        else
            echo "[INFO] $pkg 已安装，跳过"
        fi
    done

    for pkg in $packages; do
        if ! opkg list-installed | grep -q "$pkg"; then
            echo "[INFO] $pkg 未在官方源中找到，尝试使用第三方源"
            echo "[INFO] 正在使用天灵 immortalwrt pku 的软件源，并不是原生支持的软件包可能会存在你所在的第三方固件源除外的问题"
            tmp_dir=$(mktemp -d)
            for url in $urls; do
                wget -P "$tmp_dir" "$url"
            done
            opkg install "$tmp_dir"/*.ipk
            rm -rf "$tmp_dir"
            break
        fi
    done
    fi  # end fw3-only fallback block

    # Final check
    for pkg in $(get_check_packages); do
        if ! opkg list-installed | grep -q "$pkg"; then
            echo "[ERROR] 缺少包: $pkg"
            if [ "$FW_TYPE" = "fw4" ]; then
                echo "Tip: OpenWrt 24.10 使用 fw4 防火墙，请确保 opkg 软件源配置正确。"
                echo "你可能需要检查 /etc/opkg/distfeeds.conf 是否包含正确的软件源。"
            else
                echo "Tip: 你可以到 immortalwrt 官网构建固件并勾选对应的组件替换掉当前系统,或者使用 CatWrt.v24.9 支持 LeigodAcc 全部依赖."
                echo "https://www.miaoer.net/posts/network/catwrt"
            fi
            echo
        fi
    done
}

# ============================================================
# Uninstall LeigodAcc
# ============================================================
uninstall_leigodacc() {
    if [ ! -d /usr/sbin/leigod ]; then
        echo "[ERROR] 雷神服务文件不存在，是不是还没安装捏."
        return
    fi

    echo "[INFO] 确定卸载? 输入数字后回车或 10s 后自动取消 ([1]确定 / [2]取消): "
    read -t 10 choice
    case "$choice" in
        1)
            ;;
        *)
            echo "[INFO] 取消卸载"
            return
            ;;
    esac

    if opkg list-installed | grep -q "leigod-acc"; then
        echo "[INFO] leigod-acc 通过 opkg 安装，正在卸载"
        /etc/init.d/acc disable
        /etc/init.d/acc stop
        opkg remove luci-i18n-leigod-acc-zh-cn luci-app-leigod-acc leigod-acc
        rm -rf /usr/lib/lua/luci/model/cbi/leigod
        rm -rf /usr/lib/lua/luci/view/leigod
        rm -rf /usr/sbin/leigod
        rm -rf /tmp/luci-*
        echo "[INFO] leigod-acc 卸载成功"
    else
        /etc/init.d/acc disable 2>/dev/null
        /etc/init.d/acc stop 2>/dev/null
        rm -f /etc/config/accelerator
        rm -f /etc/init.d/acc
        rm -f /usr/lib/lua/luci/controller/acc.lua
        rm -rf /usr/lib/lua/luci/model/cbi/leigod
        rm -rf /usr/lib/lua/luci/view/leigod
        rm -rf /usr/sbin/leigod
        rm -f /usr/lib/lua/luci/i18n/acc.zh-cn.lmo
        rm -rf /tmp/luci-*
        echo "[INFO] leigod-acc 卸载成功"
    fi

    # Clean up iptables GAMEACC chain (left by acc-gw binary)
    iptables-nft -t mangle -F GAMEACC 2>/dev/null || iptables -t mangle -F GAMEACC 2>/dev/null
    iptables-nft -t mangle -X GAMEACC 2>/dev/null || iptables -t mangle -X GAMEACC 2>/dev/null
    iptables-nft -t mangle -D PREROUTING -j GAMEACC 2>/dev/null || \
        iptables -t mangle -D PREROUTING -j GAMEACC 2>/dev/null
    echo "[INFO] 已清理 iptables GAMEACC 规则"

    # Clean up firewall UCI rule for TCP 5588
    if grep -q "LeigodAcc" /etc/config/firewall 2>/dev/null; then
        fw_idx=$(uci show firewall | grep "LeigodAcc" | head -1 | cut -d. -f1-2)
        if [ -n "$fw_idx" ]; then
            uci delete "$fw_idx" 2>/dev/null
            uci commit firewall 2>/dev/null
            /etc/init.d/firewall restart >/dev/null 2>&1
            echo "[INFO] 已清理防火墙 TCP 5588 规则"
        fi
    fi

    # Clean up fw4 integration files
    if [ "$FW_TYPE" = "fw4" ]; then
        rm -f /etc/hotplug.d/firewall/99-leigodacc-restart
        echo "[INFO] 已清理 fw4 防火墙集成文件"
    fi

    # Clean up iptables-nft symlink (restore original if it was a symlink we created)
    if [ -L /usr/sbin/iptables ] && [ "$(readlink /usr/sbin/iptables 2>/dev/null)" = "iptables-nft" ]; then
        rm -f /usr/sbin/iptables
        echo "[INFO] 已清理 iptables-nft 符号链接"
    fi

    # Clean up auto-pause files
    if [ -f /usr/sbin/leigod-auto-pause.sh ]; then
        echo "[INFO] 检测到自动暂停组件，正在清理..."
        sed -i '/leigod-auto-pause/d' /etc/crontabs/root 2>/dev/null
        sed -i '/leigod-fw4.sh fix-tproxy/d' /etc/crontabs/root 2>/dev/null
        /etc/init.d/cron restart 2>/dev/null
        rm -f /usr/sbin/leigod-auto-pause.sh
        rm -f /etc/leigod-auto-pause.conf
        rm -f /tmp/leigod-auto-pause.state
        rm -f /tmp/leigod-auto-pause.log
        echo "[INFO] 已清理自动暂停组件"
    fi
}

# ============================================================
# Reinstall LeigodAcc (preserves user config across reinstall)
# ============================================================
reinstall_leigodacc() {
    # Backup user configuration before uninstall wipes it.
    # uninstall_leigodacc() does rm -f /etc/config/accelerator which
    # destroys all user-configured device bindings and settings.
    local cfg_backup=""
    if [ -f /etc/config/accelerator ]; then
        cfg_backup="/tmp/accelerator.bak.$$"
        cp /etc/config/accelerator "$cfg_backup"
        echo "[INFO] 已备份 UCI 配置到 $cfg_backup"
    fi

    # Backup auto-pause config
    local ap_backup=""
    if [ -f /etc/leigod-auto-pause.conf ]; then
        ap_backup="/tmp/leigod-auto-pause.conf.bak.$$"
        cp /etc/leigod-auto-pause.conf "$ap_backup"
    fi

    # Backup LuCI files in case the official installer's uninstall step
    # deletes them and apply_luci_fw4_patch fails
    local luci_backup=""
    if [ -d /usr/lib/lua/luci/model/cbi/leigod ] || [ -d /usr/lib/lua/luci/view/leigod ]; then
        luci_backup="/tmp/luci-leigod-backup.$$"
        mkdir -p "$luci_backup"
        [ -f /usr/lib/lua/luci/controller/acc.lua ] && cp /usr/lib/lua/luci/controller/acc.lua "$luci_backup/"
        [ -d /usr/lib/lua/luci/model/cbi/leigod ] && cp -r /usr/lib/lua/luci/model/cbi/leigod "$luci_backup/"
        [ -d /usr/lib/lua/luci/view/leigod ] && cp -r /usr/lib/lua/luci/view/leigod "$luci_backup/"
        echo "[INFO] 已备份 LuCI 文件到 $luci_backup"
    fi

    uninstall_leigodacc
    install_leigodacc

    # Restore user configuration
    if [ -n "$cfg_backup" ] && [ -f "$cfg_backup" ]; then
        cp "$cfg_backup" /etc/config/accelerator
        rm -f "$cfg_backup"
        echo "[INFO] 已恢复 UCI 配置 (设备绑定/加速状态等)"
    fi
    if [ -n "$ap_backup" ] && [ -f "$ap_backup" ]; then
        cp "$ap_backup" /etc/leigod-auto-pause.conf
        rm -f "$ap_backup"
        echo "[INFO] 已恢复自动暂停配置"
    fi

    # If LuCI files are still missing after install, restore from backup
    if [ -n "$luci_backup" ] && [ -d "$luci_backup" ]; then
        if [ ! -f /usr/lib/lua/luci/controller/acc.lua ]; then
            mkdir -p /usr/lib/lua/luci/controller
            cp "$luci_backup/acc.lua" /usr/lib/lua/luci/controller/ 2>/dev/null
        fi
        if [ ! -d /usr/lib/lua/luci/model/cbi/leigod ] && [ -d "$luci_backup/model/cbi/leigod" ]; then
            mkdir -p /usr/lib/lua/luci/model/cbi/leigod
            cp -r "$luci_backup/model/cbi/leigod"/* /usr/lib/lua/luci/model/cbi/leigod/ 2>/dev/null
        fi
        if [ ! -d /usr/lib/lua/luci/view/leigod ] && [ -d "$luci_backup/view/leigod" ]; then
            mkdir -p /usr/lib/lua/luci/view/leigod
            cp -r "$luci_backup/view/leigod"/* /usr/lib/lua/luci/view/leigod/ 2>/dev/null
        fi
        rm -rf "$luci_backup"
        # Clear LuCI cache so restored files take effect
        rm -rf /tmp/luci-*
        echo "[INFO] LuCI 文件已从备份恢复"
    fi

    # Run LuCI integrity verification
    verify_luci
}

# ============================================================
# Ensure UCI accelerator config is initialized
# device.lua and other LuCI pages require base/device sections
# to exist; without them the Device Config page renders blank.
# ============================================================
ensure_uci_config() {
    lan_if=$(uci get network.lan.ifname 2>/dev/null | awk '{print $1}')
    [ -z "$lan_if" ] && lan_if="br-lan"

    if ! uci get accelerator.base >/dev/null 2>&1; then
        uci set accelerator.base=system
        uci set accelerator.base.neigh="$lan_if"
        echo "[INFO] 已初始化 accelerator.base (监听接口: $lan_if)"
    fi
    if ! uci get accelerator.device >/dev/null 2>&1; then
        uci set accelerator.device=hardware
        echo "[INFO] 已初始化 accelerator.device"
    fi
    # Ensure a system section exists for service config
    if ! uci get accelerator.@system[0] >/dev/null 2>&1; then
        uci add accelerator system >/dev/null
        echo "[INFO] 已初始化 accelerator system section"
    fi
    uci commit accelerator
}

# ============================================================
# Verify LuCI installation integrity
# ============================================================
# Checks that all 12 LuCI files exist, luci-compat is installed,
# and UCI config has required sections.  Returns 0 if all pass,
# non-zero if any check fails.
verify_luci() {
    local luci_src="/usr/lib/lua/luci"
    local errors=0

    echo
    echo "============================="
    echo "  LuCI 完整性验证"
    echo "============================="

    # --- 1. luci-compat package ---
    echo ""
    echo "[1/4] luci-compat 包"
    if opkg list-installed 2>/dev/null | grep -q "^luci-compat"; then
        echo "  [OK] luci-compat 已安装"
    else
        echo "  [WARN] luci-compat 未安装! LuCI Lua CBI 页面将无法渲染"
        echo "  → 修复: opkg update && opkg install luci-compat"
        errors=$((errors + 1))
    fi

    # --- 2. LuCI files ---
    echo ""
    echo "[2/4] LuCI 文件完整性"
    local required_files="
        controller/acc.lua
        model/cbi/leigod/service.lua
        model/cbi/leigod/device.lua
        model/cbi/leigod/app.lua
        model/cbi/leigod/notice.lua
        model/cbi/leigod/autopause.lua
        model/cbi/leigod/debug.lua
        view/leigod/service.htm
        view/leigod/app.htm
        view/leigod/notice.htm
        view/leigod/autopause.htm
        view/leigod/debug.htm"
    local missing=""
    for f in $required_files; do
        if [ ! -f "$luci_src/$f" ]; then
            echo "  [FAIL] 缺失: $f"
            missing="$missing $f"
            errors=$((errors + 1))
        fi
    done
    if [ -z "$missing" ]; then
        echo "  [OK] 全部 12 个文件已就位"
    else
        echo "  → 修复: 确保 luci-fw4-patch/ 已上传到 /tmp/ 或 /root/"
        echo "  →      然后运行 leigod-fw4.sh，脚本将自动写入内联补丁"
    fi

    # --- 3. UCI config ---
    echo ""
    echo "[3/4] UCI 配置 (accelerator)"
    if [ -f /etc/config/accelerator ]; then
        local uci_ok=0
        if uci get accelerator.base >/dev/null 2>&1; then
            local neigh
            neigh=$(uci get accelerator.base.neigh 2>/dev/null)
            echo "  [OK] accelerator.base (neigh=$neigh)"
            uci_ok=$((uci_ok + 1))
        else
            echo "  [FAIL] accelerator.base 缺失"
            errors=$((errors + 1))
        fi
        if uci get accelerator.device >/dev/null 2>&1; then
            echo "  [OK] accelerator.device"
            uci_ok=$((uci_ok + 1))
        else
            echo "  [FAIL] accelerator.device 缺失"
            errors=$((errors + 1))
        fi
        if uci get accelerator.@system[0] >/dev/null 2>&1; then
            echo "  [OK] accelerator.@system[0] (服务配置)"
            uci_ok=$((uci_ok + 1))
        else
            echo "  [FAIL] accelerator.@system[0] 缺失"
            errors=$((errors + 1))
        fi
        # Check device-specific sections exist
        local dev_count
        dev_count=$(uci show accelerator 2>/dev/null | grep -c "accelerator\.@device\[" 2>/dev/null || echo 0)
        echo "  [INFO] 设备条目数: $dev_count (0 = 首次安装/重装后正常)"
    else
        echo "  [FAIL] /etc/config/accelerator 文件不存在!"
        errors=$((errors + 1))
    fi

    # --- 4. auto-pause config ---
    echo ""
    echo "[4/4] 自动暂停配置"
    if [ -f /etc/leigod-auto-pause.conf ]; then
        . /etc/leigod-auto-pause.conf
        if [ -n "$ACCOUNT_TOKEN" ]; then
            echo "  [OK] /etc/leigod-auto-pause.conf (token 已配置)"
        else
            echo "  [WARN] /etc/leigod-auto-pause.conf (token 未配置)"
            echo "  → 通过 LuCI 自动暂停页面书签一键获取"
        fi
        if [ "$MANUAL_DISABLE" = "1" ]; then
            echo "  [INFO] 离家模式已启用 (自动暂停暂时禁用)"
        fi
    else
        echo "  [INFO] /etc/leigod-auto-pause.conf 未配置 (首次安装正常)"
    fi

    # --- Summary ---
    echo
    echo "============================="
    if [ "$errors" -eq 0 ]; then
        echo "  验证结果: [OK] LuCI 安装完整"
        return 0
    else
        echo "  验证结果: [FAIL] 发现 $errors 个问题"
        echo ""
        echo "  === 自动修复 ==="
        echo "  正在尝试自动修复..."
        local fixed=0

        # Fix: install luci-compat
        if ! opkg list-installed 2>/dev/null | grep -q "^luci-compat"; then
            echo "  → 安装 luci-compat..."
            opkg update >/dev/null 2>&1
            opkg install luci-compat >/dev/null 2>&1 && \
                { echo "  [OK] luci-compat 已安装"; fixed=$((fixed + 1)); } || \
                echo "  [WARN] luci-compat 安装失败, 请手动安装"
        fi

        # Fix: write missing LuCI files from inline patches
        if [ -n "$missing" ]; then
            echo "  → 写入内联补丁..."
            # Trigger the inline patching path of apply_luci_fw4_patch
            apply_luci_fw4_patch
            # Re-check
            local still_missing=""
            for f in $missing; do
                [ ! -f "$luci_src/$f" ] && still_missing="$still_missing $f"
            done
            if [ -z "$still_missing" ]; then
                echo "  [OK] 缺失文件已修复"
                fixed=$((fixed + 1))
            else
                echo "  [WARN] 以下文件仍缺失: $still_missing"
                echo "  → 请手动将 luci-fw4-patch/ 上传到 /tmp/ 后重试"
            fi
        fi

        # Fix: ensure UCI config
        ensure_uci_config

        # Clear LuCI cache
        rm -rf /tmp/luci-*
        echo "  → LuCI 缓存已清除"

        if [ "$fixed" -gt 0 ]; then
            echo ""
            echo "  已自动修复 $fixed 个问题，请刷新 Web 页面"
        fi
        return 1
    fi
}

# ============================================================
# Service enable/disable
# ============================================================
service() {
    if [ ! -f /etc/init.d/acc ]; then
        echo "[ERROR] 雷神服务文件不存在，是不是还没安装捏."
        return
    fi

    if /etc/init.d/acc enabled; then
        /etc/init.d/acc disable
        /etc/init.d/acc stop
        echo "[INFO] LeigodAcc 服务已禁用并关闭"
    else
        /etc/init.d/acc enable
        /etc/init.d/acc start
        echo "[INFO] LeigodAcc 服务已启用并启动"
    fi
}

# ============================================================
# Switch mode (TUN/Tproxy)
# ============================================================
# ============================================================
# Fix acc_core_conf.json — detect and repair invalid tproxy_ip
# ============================================================
# The acc-gw binary (v1.2.2.13) reads /tmp/acc/acc_core_conf.json as
# the source of truth for web child process parameters.  If tproxy_ip
# is set to a non-existent or non-LAN IP (common fake: 10.20.30.40),
# the web subprocess will crash-loop and acceleration will fail.
#
# This function validates the tproxy_ip against the router's actual
# LAN address and repairs mismatches.
fix_acc_core_conf() {
    local conf="/tmp/acc/acc_core_conf.json"
    [ ! -f "$conf" ] && return 0

    lan_ip=$(uci get network.lan.ipaddr 2>/dev/null)
    [ -z "$lan_ip" ] && return 0

    # Self-healing: if daemon is stuck in a stop_acc crash loop (binary bug:
    # every ~50s web client disconnect triggers on_error → stop_acc),
    # force-restart the entire daemon to break the loop.
    if pgrep -f "/usr/sbin/leigod/acc-gw" >/dev/null 2>&1; then
        local stops=$(tail -20 /tmp/acc/log/acc_daemon.log 2>/dev/null | grep -c 'stop_acc')
        if [ "$stops" -ge 2 ] 2>/dev/null; then
            echo "[WARN] 检测到 stop_acc 崩溃循环 (近20行含${stops}次stop), 强重启 daemon..."
            /etc/init.d/acc stop >/dev/null 2>&1
            pids=$(pgrep -f "/usr/sbin/leigod/acc-gw" 2>/dev/null)
            [ -n "$pids" ] && kill -9 $pids 2>/dev/null
            sleep 2
            /etc/init.d/acc start >/dev/null 2>&1
            sleep 4
            sed -i "s|\"tproxy_ip\":\"[^\"]*\"|\"tproxy_ip\":\"$lan_ip\"|" "$conf" 2>/dev/null
            echo "[INFO] Daemon 已强重启, JSON 已修复"
        fi
    fi

    current_ip=$(sed -n 's/.*"tproxy_ip":"\([^"]*\)".*/\1/p' "$conf" 2>/dev/null)
    current_mode=$(sed -n 's/.*"acc_mode":\([0-9]*\).*/\1/p' "$conf" 2>/dev/null)
    local fixed=0

    # === Fix 1: tproxy_ip ===
    # The acc-gw binary has a hardcoded default tproxy_ip (10.20.30.40).
    # When the daemon starts, it regenerates acc_core_conf.json with this
    # fake IP, which causes the web subprocess to crash (exit 255).
    if [ "$current_ip" != "$lan_ip" ]; then
        echo "[WARN] acc_core_conf.json tproxy_ip 不正确: '$current_ip' (应为 '$lan_ip')"
        echo "[INFO] 正在修复 acc_core_conf.json tproxy_ip..."
        sed -i "s|\"tproxy_ip\":\"[^\"]*\"|\"tproxy_ip\":\"$lan_ip\"|" "$conf"
        fixed=1
        echo "[INFO] acc_core_conf.json tproxy_ip 已修复为 $lan_ip"
    fi

    # Also fix init script -l arg if it contains the wrong IP
    if [ -f /etc/init.d/acc ] && [ -n "$current_ip" ] && [ "$current_ip" != "$lan_ip" ]; then
        if grep -q -- "-l $current_ip" /etc/init.d/acc 2>/dev/null; then
            echo "[INFO] 同步修复 /etc/init.d/acc 中的 -l 参数..."
            sed -i "s|-l $current_ip|-l $lan_ip|g" /etc/init.d/acc
        fi
    fi

    # === Fix 2: acc_mode ===
    # This binary (acc-gw v1.2.2.13, router.arm64) has the following behavior:
    #   - acc_mode is read from JSON, NOT from command-line -m flag
    #   - acc_mode=0: web subprocess exit 255 crash loop
    #   - acc_mode=1: web subprocess exit 0 crash loop (TUN, unsupported)
    #   - acc_mode=2: STABLE — only value that works (TPROXY)
    # The daemon logs "unknow acc mode:2" during rule cleanup — this is a
    # non-fatal cosmetic warning. The binary functions correctly with mode=2.
    if [ "$current_mode" != "2" ]; then
        echo "[WARN] acc_core_conf.json acc_mode=$current_mode 不稳定 (已知稳定值为 2)"
        echo "[INFO] 正在修正 acc_mode 为 2 (TPROXY, 唯一稳定值)..."
        # Guard against empty current_mode (JSON being written by daemon in race)
        if [ -z "$current_mode" ]; then
            sed -i 's|"acc_mode":[0-9]*|"acc_mode":2|' "$conf"
        else
            sed -i "s|\"acc_mode\":$current_mode|\"acc_mode\":2|" "$conf"
        fi
        fixed=1
        echo "[INFO] acc_core_conf.json acc_mode 已修正为 2"
        # Note: "unknow acc mode:2" in daemon log is expected and non-fatal
        echo "[INFO] (daemon 日志中的 'unknow acc mode:2' 为冗余警告, 不影响功能)"
    fi

    # Also ensure init script uses -m tproxy (not -m tun) for consistency,
    # since this binary version only works with TPROXY
    if [ -f /etc/init.d/acc ]; then
        if grep -qE -- "-m tun\b" /etc/init.d/acc 2>/dev/null; then
            echo "[INFO] 同步修复 /etc/init.d/acc 模式为 tproxy..."
            sed -i 's|-m tun|-m tproxy|' /etc/init.d/acc
            fixed=1
        fi
    fi

    # === Restart if anything was fixed ===
    if [ "$fixed" = "1" ] && [ -x /etc/init.d/acc ]; then
        # Only restart if acc-gw is NOT running (crashed state).
        # Restarting a running daemon flushes GAMEACC rules and triggers
        # the binary's hardcoded-fake-IP overwrite → crash loop.
        if ! pgrep -f "/usr/sbin/leigod/acc-gw" >/dev/null 2>&1; then
            echo "[INFO] acc-gw 未运行, 启动服务..."
            /etc/init.d/acc start >/dev/null 2>&1
            sleep 4

            # Verify tproxy_ip survived the start (binary may overwrite)
            recheck_ip=$(sed -n 's/.*"tproxy_ip":"\([^"]*\)".*/\1/p' "$conf" 2>/dev/null)
            if [ "$recheck_ip" != "$lan_ip" ]; then
                echo "[WARN] tproxy_ip 在启动后又被覆盖为 '$recheck_ip'"
                echo "[INFO] 二进制硬编码了假IP, 再次修复..."
                sed -i "s|\"tproxy_ip\":\"[^\"]*\"|\"tproxy_ip\":\"$lan_ip\"|" "$conf"
            fi

            # Verify port listening
            sleep 2
            if netstat -tlnp 2>/dev/null | grep -q 5588 || ss -tlnp 2>/dev/null | grep -q 5588; then
                echo "[INFO] 端口 5588 已监听, 服务正常"
            else
                echo "[ERR] 端口 5588 未监听! 请手动排查: /etc/init.d/acc restart"
            fi
        else
            echo "[INFO] acc-gw 运行中, JSON 配置已修复 (无需重启以免中断加速)"
        fi
    fi
}

# ============================================================
# Install tproxy_ip watcher cron job
# The acc-gw binary hardcodes a fake tproxy_ip (10.20.30.40)
# and regenerates acc_core_conf.json on each daemon restart,
# overwriting manual fixes. This cron checks every 5 minutes
# and auto-repairs tproxy_ip + acc_mode.
# ============================================================
install_tproxy_watcher() {
    local watcher_cron="*/5 * * * * /usr/sbin/leigod/leigod-fw4.sh fix-tproxy >/dev/null 2>&1"
    local cron_file="/etc/crontabs/root"

    # Ensure self is deployed to the path referenced by the cron job
    if [ ! -f /usr/sbin/leigod/leigod-fw4.sh ] && [ -f "$0" ]; then
        cp "$0" /usr/sbin/leigod/leigod-fw4.sh
        chmod +x /usr/sbin/leigod/leigod-fw4.sh
        echo "[INFO] 已部署脚本到 /usr/sbin/leigod/leigod-fw4.sh"
    fi

    # Skip if already installed
    if grep -q "leigod-fw4.sh fix-tproxy" "$cron_file" 2>/dev/null; then
        return 0
    fi

    echo "$watcher_cron" >> "$cron_file"
    /etc/init.d/cron restart 2>/dev/null
    echo "[INFO] tproxy_ip 守护 cron 已安装 (每5分钟检查)"
}

remove_tproxy_watcher() {
    sed -i '/leigod-fw4.sh fix-tproxy/d' /etc/crontabs/root 2>/dev/null
}

switch_mode() {
    if [ ! -f /etc/init.d/acc ]; then
        echo "[ERROR] 雷神服务文件不存在，是不是还没安装捏."
        return
    fi

    echo "当前版本可能不支持切换模式"
    echo

    if opkg list-installed | grep -q "^leigod-acc"; then
        # Get tun option from the anonymous system section.
        # The "base" named section stores the neigh interface, not the
        # TUN flag, so accelerator.base.tun would be empty/wrong.
        # accelerator.@system[-1] targets the last system section
        # (the anonymous service-config section).
        current_tun=$(uci -q get accelerator.@system[-1].tun 2>/dev/null)

        if [ "$current_tun" = "1" ]; then
            uci set accelerator.@system[-1].tun='0'
            echo "[INFO] 已切换为 tproxy 模式"
        else
            uci set accelerator.@system[-1].tun='1'
            echo "[INFO] 已切换为 tun 模式"
        fi

        uci commit accelerator
    else
        cp /etc/init.d/acc /etc/init.d/acc.bak 2>/dev/null

        # Normalize legacy GNU long-format mode flags.
        # The acc-gw binary only recognizes the short form (-m tun / -m tproxy).
        # The official installer writes --mode tun which the binary silently
        # ignores, defaulting to TPROXY.
        if grep -q -- "--mode tun" /etc/init.d/acc; then
            sed -i 's|--mode tun|-m tun|' /etc/init.d/acc
            echo "[INFO] 已修正旧格式 --mode tun → -m tun"
        elif grep -q -- "--mode tproxy" /etc/init.d/acc; then
            sed -i 's|--mode tproxy|-m tproxy|' /etc/init.d/acc
            echo "[INFO] 已修正旧格式 --mode tproxy → -m tproxy"
        fi

        if grep -qE -- "-m tun\b" /etc/init.d/acc; then
            # TUN → TPROXY: replace mode flag only, preserve other params
            sed -i 's|-m tun|-m tproxy|' /etc/init.d/acc
            if ! grep -q -- "-p " /etc/init.d/acc; then
                sed -i 's|-m tproxy|-m tproxy -p 5588|' /etc/init.d/acc
                echo "[INFO] 已恢复默认 API 端口 (-p 5588)"
            fi
            echo "[INFO] 已切换为 tproxy 模式"
        else
            # TPROXY → TUN: replace mode flag only, preserve other params
            if grep -qE -- "-m tproxy\b" /etc/init.d/acc; then
                sed -i 's|-m tproxy|-m tun|' /etc/init.d/acc
            else
                # No recognizable mode flag — insert -m tun
                sed -i 's|args="|args="-m tun |' /etc/init.d/acc
            fi
            if ! grep -q -- "-p " /etc/init.d/acc; then
                sed -i 's|-m tun|-m tun -p 5588|' /etc/init.d/acc
                echo "[INFO] 已恢复默认 API 端口 (-p 5588)"
            fi
            echo "[INFO] 已切换为 tun 模式"
        fi
    fi

    if [ "$FW_TYPE" = "fw4" ]; then
        echo "[INFO] fw4/nftables 环境 — 确保 acc_core_conf.json tproxy_ip 正确"
        echo "[INFO] 已安装的二进制版本可能不支持 TUN 模式，TPROXY + 正确 LAN IP 是推荐方案"
    fi

    /etc/init.d/acc stop
    /etc/init.d/acc start
    echo "[INFO] 已经重启 LeigodAcc 服务"

    # Fix acc_core_conf.json tproxy_ip AFTER restart
    # (daemon regenerates JSON with hardcoded fake IP on start)
    sleep 3
    if [ -f /tmp/acc/acc_core_conf.json ]; then
        fix_acc_core_conf
    fi
    install_tproxy_watcher
}

# ============================================================
# Disable/Enable IPv6
# ============================================================
disabled_ipv6() {
    config_file="/etc/config/dhcp"
    option_dhcpv6=$(uci get dhcp.lan.dhcpv6 2>/dev/null)
    option_ra=$(uci get dhcp.lan.ra 2>/dev/null)

    if [ "$option_dhcpv6" = "disabled" ] && [ "$option_ra" = "disabled" ]; then
        uci set dhcp.lan.ra='server'
        uci set dhcp.lan.dhcpv6='server'
        uci delete dhcp.lan.ra_flags
        uci add_list dhcp.lan.ra_flags='managed-config'
        uci add_list dhcp.lan.ra_flags='other-config'
        echo "[INFO] IPv6 已启用"
        echo "[INFO] 该功能只在 LEDE/QWRT/CatWrt 中测试"
        echo "[INFO] 其他 OpenWrt 版本可能需要在 Luci 界面中启用其他 IPv6 选项以获取正常的 IPv6 网络支持"
    else
        uci delete dhcp.lan.ra_flags
        uci set dhcp.lan.ra='disabled'
        uci set dhcp.lan.dhcpv6='disabled'
        uci add_list dhcp.lan.ra_flags='none'
        echo "[INFO] IPv6 已禁用"
        echo "[INFO] iOS/Android 设备请忘记无线 Wi-Fi 网络再连接，插件内就会自动识别"
    fi

    uci commit dhcp
    /etc/init.d/odhcpd restart
}

# ============================================================
# Install Lean IPKG version
# ============================================================
install_lean_ipkg_version() {
    if opkg list-installed | grep -q "leigod-acc"; then
        echo "[INFO] leigod-acc 已安装，L 有大雕"
        return
    else
        echo "[INFO] leigod-acc 未安装"
        if [ -f /var/lock/opkg.lock ]; then
            if pgrep -f "opkg " > /dev/null 2>&1; then
                echo "[WARN] 检测到其他 opkg 进程正在运行，等待完成..."
                sleep 3
            fi
            rm -f /var/lock/opkg.lock
        fi
        if ! check_network; then
            echo "[WARN] 网络不可达，后续 opkg update 及下载可能会失败"
            echo -n "是否继续? (y/n): "
            read proceed
            [ "$proceed" != "y" ] && [ "$proceed" != "Y" ] && return
        fi
    fi

    if [ -d /usr/sbin/leigod ]; then
        echo -n "[INFO] 检测到已经安装 LeigodAcc 普通版本，请返回管理器卸载后再继续!"
        return
    fi

    if ! check_disk_space; then
        return 1
    fi

    # Try to detect latest release tag from GitHub API (lightweight, 5s timeout).
    # Falls back to v1.3 on any failure.
    LEIGOD_RELEASE="v1.3"
    echo "[INFO] 正在查询最新版本..."
    _latest=$(curl -sL --connect-timeout 5 \
        "https://api.github.com/repos/miaoermua/openwrt-leigodacc-manager/releases/latest" \
        2>/dev/null | sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p' | head -1)
    if [ -n "$_latest" ]; then
        LEIGOD_RELEASE="$_latest"
        echo "[INFO] 检测到最新版本: $LEIGOD_RELEASE"
    else
        echo "[INFO] 无法获取最新版本 (GitHub API 可能限流或网络不可达)，使用默认版本: $LEIGOD_RELEASE"
    fi

    # Use firewall-appropriate package list
    required_packages="libpcap $PKG_IPTABLES $PKG_NAT $PKG_TPROXY"
    [ -n "$PKG_IPT_TPROXY_MOD" ] && required_packages="$required_packages $PKG_IPT_TPROXY_MOD"
    [ -n "$PKG_IPSET" ] && required_packages="$required_packages $PKG_IPSET"
    [ -n "$PKG_IPSET_TOOL" ] && required_packages="$required_packages $PKG_IPSET_TOOL"
    required_packages="$required_packages kmod-tun curl miniupnpd tc-full kmod-netem conntrack conntrackd"

    missing_packages=""

    echo "[INFO] 检查在线软件源中是否存在所有依赖包..."
    for package in $required_packages; do
        if ! opkg list | grep -q "^$package"; then
            echo "[ERROR] 在线软件源中缺少依赖包: $package"
            missing_packages="$missing_packages $package"
        fi
    done

    if [ -n "$missing_packages" ]; then
        echo "[ERROR] 检测到在线软件源中缺少的依赖包，无法继续安装: $missing_packages"
        echo "你的设备暂不支持 Lean 版 IPKG 插件，尝试使用第一方带有依赖的 CatWrt 来安装 IPKG 版本吧，或者使用管理器中的普通安装选项"
        echo "访问以下链接获取 mt7621 & amd64(x86_64) 版本"
        echo
        echo "https://www.miaoer.net/posts/network/catwrt"
        sleep 5
        return 1
    fi

    echo "[INFO] 所有依赖包已在在线软件源中找到，正在安装缺失的依赖包..."

    OPKG_FAILED=""
    for package in $required_packages; do
        if ! opkg list-installed | grep -q "^$package"; then
            safe_opkg_install "$package"
        fi
    done

    if [ -n "$OPKG_FAILED" ]; then
        echo "[ERROR] 以下依赖包安装失败:$OPKG_FAILED"
        echo "[ERROR] 请检查网络连接和软件源配置后重试"
        return 1
    fi

    echo "[INFO] 所有依赖包已安装！"

    # fw4: ensure TPROXY kernel support (with fallback) before installing IPK
    if ! ensure_fw4_tproxy; then
        echo "[WARN] TPROXY 不可用。注意: 部分 acc-gw 版本仅支持 TPROXY，此情况下加速将无法工作"
    fi
    setup_fw4_integration
    apply_luci_fw4_patch

    arch=$(opkg print-architecture | grep "arch" | awk '{print $2}' | grep -vE "all|noarch" | head -1)

    if opkg list | grep -q "leigod-acc"; then
        echo "[INFO] 软件源中检测到 leigod-acc 插件，正在安装..."
        safe_opkg_install leigod-acc luci-app-leigod-acc luci-i18n-leigod-acc-zh-cn
        echo "[INFO] Lean 版本 leigod-acc 安装成功！"
    else
        echo "[INFO] 在线软件源中没有找到 leigod-acc 包，将从 GitHub Releases 下载"

        case "$arch" in
            "aarch64_cortex-a53"|"aarch64_cortex-a53+crypto")
                url="https://github.com/miaoermua/openwrt-leigodacc-manager/releases/download/${LEIGOD_RELEASE}/leigod-acc_1.3.0.30-1_aarch64_cortex-a53.ipk"
                ;;
            "aarch64_generic"|"aarch64_cortex-a72"|"aarch64_cortex-a76"|"aarch64_cortex-a55"|"aarch64_cortex-a73")
                url="https://github.com/miaoermua/openwrt-leigodacc-manager/releases/download/${LEIGOD_RELEASE}/leigod-acc_1.3.0.30-1_aarch64_generic.ipk"
                ;;
            "mipsel_24kc")
                url="https://github.com/miaoermua/openwrt-leigodacc-manager/releases/download/${LEIGOD_RELEASE}/leigod-acc_1.3.0.30-1_mipsel_24kc.ipk"
                ;;
            "x86_64")
                url="https://github.com/miaoermua/openwrt-leigodacc-manager/releases/download/${LEIGOD_RELEASE}/leigod-acc_1.3.0.30-1_x86_64.ipk"
                ;;
            *)
                echo "[ERROR] 不支持的架构: $arch"
                return 1
                ;;
        esac

        echo "[INFO] 正在下载 leigod-acc 包: $url"
        echo
        mkdir -p /tmp/upload
        wget -P /tmp/upload "$url" || {
            echo "[ERROR] 下载 leigod-acc 失败，请检查网络或访问 GitHub 确认版本"
            return 1
        }
        wget -P /tmp/upload "https://github.com/miaoermua/openwrt-leigodacc-manager/releases/download/${LEIGOD_RELEASE}/luci-app-leigod-acc_1-3_all.ipk" 2>/dev/null || \
            echo "[WARN] luci-app-leigod-acc 下载失败, LuCI 界面将不可用"
        wget -P /tmp/upload "https://github.com/miaoermua/openwrt-leigodacc-manager/releases/download/${LEIGOD_RELEASE}/luci-i18n-leigod-acc-zh-cn_1-3_all.ipk" 2>/dev/null || \
            echo "[WARN] luci-i18n 下载失败, 界面将使用英文"

        safe_opkg_install /tmp/upload/leigod-acc_*.ipk /tmp/upload/luci-app-leigod-acc_*.ipk /tmp/upload/luci-i18n-leigod-acc-zh-cn_*.ipk
        echo

        if [ ! -d /usr/sbin/leigod ]; then
            echo "[ERROR] 检测到 LeigodAcc 未安装，有可能是设备存储空间已满或者雷神服务器挂了!"
            echo "请登录 OpenWrt 路由器后台: 系统-软件包 查看当前可用空间诊断."
            return 1
        else
            echo "[INFO] Lean IPKG 插件版 leigod-acc 已成功安装!"

            # Normalize legacy long-format mode flags to short format
            if grep -q -- "--mode tun" /etc/init.d/acc 2>/dev/null; then
                sed -i 's|--mode tun|-m tun|' /etc/init.d/acc
                echo "[INFO] 已修正加速模式参数格式 (--mode tun → -m tun)"
            elif grep -q -- "--mode tproxy" /etc/init.d/acc 2>/dev/null; then
                sed -i 's|--mode tproxy|-m tproxy|' /etc/init.d/acc
                echo "[INFO] 已修正加速模式参数格式 (--mode tproxy → -m tproxy)"
            fi

            setup_iptables_nft_compat

            # Re-apply fw4 LuCI patches (IPK install may have overwritten them)
            apply_luci_fw4_patch
            echo ""
            echo "=========================================="
            echo "  [注意] LuCI Web 界面说明"
            echo "=========================================="
            echo "  LuCI Web 界面已应用 fw4 适配补丁。"
            echo "  IPK 安装可能覆盖了补丁文件，已自动重新应用。"
            echo ""
            echo "  - 服务状态: LuCI 服务页显示防火墙类型"
            echo "  - 自动暂停: LuCI 已集成自动暂停配置页"
            echo "  - 防火墙集成: 已自动配置 fw4 hotplug"
            echo "=========================================="
            echo ""
        fi
    fi

    if ! opkg list-installed | grep -q 'luci-app-upnp'; then
        safe_opkg_install luci-app-upnp
    fi

    if [ -f /etc/config/upnpd ]; then
        echo "[INFO] 正在启用 UPnP..."
        uci set upnpd.config.enabled='1'
        uci commit upnpd

        /etc/init.d/miniupnpd start
        /etc/init.d/miniupnpd enable

        echo "[INFO] UPnP 已启用并运行"
        echo "安装成功后可以在雷神加速器 APP 发现并绑定设备"
        echo
    else
        echo "[ERROR] UPnP 配置不存在，安装可能失败，请检查固件是否存在问题!"
        return 1
    fi

    if [ "$FW_TYPE" = "fw4" ]; then
        echo ""
        echo "=========================================="
        echo "  [重要] fw4 防火墙 — 环境适配"
        echo "=========================================="
        echo "  当前系统使用 fw4/nftables 防火墙。"
        echo "  请确保 acc_core_conf.json 中 tproxy_ip"
        echo "  正确设置为路由器 LAN IP。"
        echo ""
        echo "  运行菜单选项 S (诊断) 可自动检测和修复。"
        echo "=========================================="
        echo ""

        # Initialize UCI config for LuCI pages
        ensure_uci_config
        # Fix acc_core_conf.json if needed (covers both fresh and re-installs)
        fix_acc_core_conf
        # Install tproxy_ip watcher cron
        install_tproxy_watcher

        echo -n "是否需要检查服务运行状态? (y/n, 默认 n): "
        read check_status
        case "$check_status" in
            [Yy]|[Yy][Ee][Ss])
                check_service_status
                ;;
            *)
                echo "[INFO] 可稍后通过菜单选项 S 查看"
                ;;
        esac
        echo ""
    fi
}

# ============================================================
# Diagnostic functions
# ============================================================
check_logs() {
    if ! opkg list-installed | grep -q "^tc-full"; then
        return 0
    fi

    if grep -q "exec tc command failed" /tmp/acc/acc-gw.log-* 2>/dev/null && grep -q "No such file or directory" /tmp/acc/acc-gw.log-* 2>/dev/null; then
        echo "[ERROR] 检测到插件中的 tc-full 组件出现了 'exec tc command failed' 错误，可能是软件源或者固件提供的 tc-full 组件问题"
        echo "可能导致无法加速的问题，由于实装 tc-full 的用户过少，请自行测试加速问题或手动重装 tc-full 组件"
        echo "opkg update && opkg remove tc-full && opkg install tc-full"
        echo
        sleep 5
    fi
}

check_acceleration() {
    # Iterate over glob-expanded log files (avoids [ -f glob ] pitfall)
    for log_file in /tmp/acc/acc-gw.log-*.log; do
        [ -f "$log_file" ] || continue

        if ! grep -q "S5 UDP" "$log_file" 2>/dev/null; then
            continue
        fi

        # BusyBox-compatible: use date -r <file> instead of date -d <string>
        log_mtime=$(date -r "$log_file" +%s 2>/dev/null)
        [ -z "$log_mtime" ] && continue

        now=$(date +%s)
        if [ $((now - log_mtime)) -lt 30 ]; then
            echo "[INFO] 检测到 UDP 被成功代理，加速成功"
            return 0
        fi
    done
    return 1
}

check_openclash_mode() {
    pgrep -f "openclash" > /dev/null 2>&1 || return 0

    config_dir="/etc/openclash"
    config_files=""
    for f in "$config_dir"/*.yaml; do
        [ -f "$f" ] || continue
        config_files="$config_files $f"
    done

    if [ -z "$config_files" ]; then
        return 0
    fi

    for config_file in $config_files; do
        mode=$(grep -E "^mode:" "$config_file" | awk '{print $2}')
        enhanced_mode=$(grep -E "^ *enhanced-mode:" "$config_file" | cut -d':' -f2 | xargs)

        if [ -z "$mode" ] || [ -z "$enhanced_mode" ]; then
            continue
        fi

        if [ "$mode" = "rule" ] && [ "$enhanced_mode" = "redir-host" ];then
            if grep -q "^tun:" "$config_file"; then
                echo "[WARN] 运行模式可能存在冲突!"
                echo "========================="
                echo "OpenClash 运行在 Redir-Host 未处于兼容模式(Tproxy)"
                echo "你需要调整 OpenClash 的运行模式为 '兼容'，请移除 TUN 配置以避免 leigod-acc 冲突。"
                echo
                echo "[Tip] 当你 OpenClash 为兼容模式(Tproxy),Leigod 需要切换运行模式以避免冲突。请通过选项 S 诊断确认 tproxy_ip 是否正确。"
            fi
        else
            echo "[WARN] 运行模式冲突!"
            echo "=================="
            echo "检查到 OpenClash 运行在 Fake-IP 未处于 Redir-Host 兼容模式(Tproxy)"
            echo "需要调整 OpenClash 的运行模式为 '兼容'，请移除 Fake-IP 配置以避免 leigod-acc 冲突!"
            echo
            echo "OC > 插件设置 > 模式设置 > 切换页面到 Redir-Host 模式"
            echo
            echo "[Tip] 当你 OpenClash 为兼容模式(Tproxy),Leigod 需要切换运行模式以避免冲突。请通过选项 S 诊断确认 tproxy_ip 是否正确。"
            sleep 5
        fi
    done

    if [ "$FW_TYPE" = "fw4" ]; then
        echo "[INFO] fw4 系统检测：OpenClash 与 LeigodAcc 同时运行时，"
        echo "建议检查 acc_core_conf.json tproxy_ip 是否为正确 LAN IP，以避免 nftables 规则冲突"
    fi
}

check_bypass_gateway() {
    lan_gateway=$(uci get network.lan.gateway 2>/dev/null)
    lan_ipaddr=$(uci get network.lan.ipaddr 2>/dev/null)

    lan_network=$(echo "$lan_ipaddr" | awk -F. '{print $1"."$2"."$3}')
    gateway_network=$(echo "$lan_gateway" | awk -F. '{print $1"."$2"."$3}')

    if [ -n "$lan_gateway" ] && [ "$lan_gateway" != "0.0.0.0" ] && [ "$lan_gateway" != "$lan_ipaddr" ] && [ "$lan_network" = "$gateway_network" ]; then
        echo "[Tip] 检测到旁路网关配置:"
        echo "当前路由器IP: $lan_ipaddr"
        echo "配置的网关: $lan_gateway"
        echo
        echo "注意: 您正在使用旁路网关模式，需要特别注意以下事项:"
        echo "如果是单臂路由(网关不互指):"
        echo "需要在加速设备上配置安装加速器插件的网关&路由器地址"
        echo "如果是双软路由(网关互指):"
        echo "仅需要关闭主路由上的 UPnP 功能"
        echo
        sleep 5
    fi
}

check_service_status() {
    echo
    echo "============================="
    echo "  LeigodAcc 服务状态"
    echo "============================="
    echo "防火墙: $FW_NAME"

    # Installation status
    if [ -f /etc/init.d/acc ] && [ -d /usr/sbin/leigod ]; then
        echo "安装状态: 已安装"
    elif [ -f /etc/init.d/acc ] || [ -d /usr/sbin/leigod ]; then
        echo "安装状态: 部分安装 (状态异常!)"
    else
        echo "安装状态: 未安装"
        echo
        echo "请先使用选项 1 或 8 安装雷神加速器"
        return 0
    fi

    # Service running status
    # The init script's running() may not detect acc-gw on all systems.
    # Fall back to checking the process table directly.
    if /etc/init.d/acc running >/dev/null 2>&1; then
        echo "服务状态: 运行中"
    elif ps | grep -q "[a]cc-gw"; then
        echo "服务状态: 运行中 (init script 检测异常，但进程存在)"
    else
        echo "服务状态: 已停止"
    fi
    if /etc/init.d/acc enabled >/dev/null 2>&1; then
        echo "开机自启: 已启用"
    else
        echo "开机自启: 已禁用"
    fi

    # Current mode
    echo -n "加速模式: "
    if [ -d /usr/sbin/leigod ]; then
        if grep -qE -- "-m tun\b" /etc/init.d/acc 2>/dev/null; then
            echo "TUN"
        elif grep -qE -- "-m tproxy\b" /etc/init.d/acc 2>/dev/null; then
            echo "TPROXY"
        elif grep -q -- "--mode tun" /etc/init.d/acc 2>/dev/null; then
            echo "TUN (旧格式, 可能未生效)"
        elif grep -q -- "--mode tproxy" /etc/init.d/acc 2>/dev/null; then
            echo "TPROXY (旧格式, 可能未生效)"
        else
            echo "未知 (检查 /etc/init.d/acc)"
        fi
    else
        echo "N/A"
    fi

    # acc-gw binary status
    if pgrep -f "/usr/sbin/leigod/acc-gw" >/dev/null 2>&1; then
        acc_pid=$(pgrep -f "/usr/sbin/leigod/acc-gw" | head -1)
        echo "acc-gw 进程: 运行中 (PID: $acc_pid)"
        # Check if acc-gw is listening on the API port
        if ss -tlnp 2>/dev/null | grep -q ":5588.*acc-gw" || netstat -tlnp 2>/dev/null | grep -q ":5588.*acc-gw"; then
            echo "API 端口: TCP 5588 监听中"
        else
            echo "API 端口: TCP 5588 未监听! (手机APP将无法通信)"
        fi
    else
        echo "acc-gw 进程: 未运行"
    fi

    # Device acceleration states — check multiple sources:
    #  1. UCI accelerator.*.state (traditional)
    #  2. Running acc-gw child processes (most reliable)
    #  3. acc_core_conf.json acceleration list
    echo
    echo "设备加速状态:"
    # Collect active device types from running acc sub-processes
    local active_devs=""
    acc_procs=$(ps 2>/dev/null | grep "[a]cc-gw.*-r acc" | grep -o "\-t [A-Za-z]*" | awk '{print $2}')
    for dev in Phone PC Game Unknown; do
        local label="无设备"
        # Check UCI first
        dev_state=$(uci get "accelerator.${dev}.state" 2>/dev/null)
        case "$dev_state" in
            1) label="加速中" ;;
            2) label="已停止" ;;
            3) label="已暂停" ;;
        esac

        # Fallback: check running acc processes (more reliable than UCI)
        if [ "$label" = "无设备" ] && echo "$acc_procs" | grep -q "$dev"; then
            label="加速中 (进程检测)"
        fi

        echo "  $dev: $label"
    done

    # If nothing detected via UCI/processes, check JSON
    json_accel=$(sed -n 's/.*"acceleration":\[\([^]]*\)\].*/\1/p' /tmp/acc/acc_core_conf.json 2>/dev/null)
    if [ -n "$json_accel" ]; then
        echo "  JSON中: [$json_accel]"
    fi

    # Auto-pause status
    echo
    if [ -f "$AUTO_PAUSE_CONF" ]; then
        echo "自动暂停: 已配置"
        if grep -q "leigod-auto-pause" "$AUTO_PAUSE_CRON" 2>/dev/null; then
            echo "  cron: 已启用 (每2分钟)"
        else
            echo "  cron: 未启用"
        fi
        if [ -f /tmp/leigod-auto-pause.state ]; then
            local idc lp
            idc=$(grep idle_count /tmp/leigod-auto-pause.state 2>/dev/null | cut -d= -f2)
            lp=$(grep last_pause_epoch /tmp/leigod-auto-pause.state 2>/dev/null | cut -d= -f2)
            echo "  空闲计数: ${idc:-0}"
            if [ -n "$lp" ] && [ "$lp" != "0" ]; then
                echo "  上次暂停: $(date -d @"$lp" '+%m-%d %H:%M:%S' 2>/dev/null || date -r "$lp" '+%m-%d %H:%M:%S' 2>/dev/null || echo "$lp")"
            fi
        fi
    else
        echo "自动暂停: 未配置 (选项 9)"
    fi

    # Recent errors in log
    echo
    echo "最近日志 (异常):"
    if ls /tmp/acc/acc-gw.log-*.log >/dev/null 2>&1; then
        err_count=$(grep -i -E "error|fail|timeout|exec tc" /tmp/acc/acc-gw.log-*.log 2>/dev/null | tail -5 | wc -l)
        if [ "$err_count" -gt 0 ]; then
            grep -i -E "error|fail|timeout|exec tc" /tmp/acc/acc-gw.log-*.log 2>/dev/null | tail -5
        else
            echo "  (无)"
        fi
    else
        echo "  (无日志文件)"
    fi

    # Check acc_core_conf.json for invalid tproxy_ip
    echo
    local acc_conf="/tmp/acc/acc_core_conf.json"
    if [ -f "$acc_conf" ]; then
        local conf_tproxy_ip conf_acc_mode
        conf_tproxy_ip=$(sed -n 's/.*"tproxy_ip":"\([^"]*\)".*/\1/p' "$acc_conf" 2>/dev/null)
        conf_acc_mode=$(sed -n 's/.*"acc_mode":\([0-9]*\).*/\1/p' "$acc_conf" 2>/dev/null)
        lan_ip=$(uci get network.lan.ipaddr 2>/dev/null)

        if [ "$conf_tproxy_ip" != "$lan_ip" ] && [ -n "$lan_ip" ]; then
            echo "⚠ acc_core_conf.json tproxy_ip 异常: '$conf_tproxy_ip' (应为 '$lan_ip')"
            echo "  这会导致 Web 子进程崩溃、加速几秒后断开!"
            echo "  正在自动修复..."
            fix_acc_core_conf
        elif [ "$conf_acc_mode" = "1" ]; then
            echo "⚠ acc_core_conf.json acc_mode=1 (TUN) — 此二进制版本仅支持 TPROXY"
            echo "  正在自动修复..."
            fix_acc_core_conf
        else
            echo "acc_core_conf.json: 正常 (tproxy_ip=$conf_tproxy_ip, acc_mode=$conf_acc_mode)"
        fi
    fi

    # fw4 specific note
    if [ "$FW_TYPE" = "fw4" ]; then
        echo
        if [ -f /etc/hotplug.d/firewall/99-leigodacc-restart ]; then
            echo "[INFO] fw4 hotplug 脚本已安装"
        else
            echo "[INFO] fw4 hotplug 脚本未安装，防火墙重载后可能丢失加速规则"
            echo "  运行 '安装' 或 '重装' 将自动配置"
        fi

        # Ensure firewall allows phone → acc-gw API (TCP 5588)
        if ! grep -q "LeigodAcc" /etc/config/firewall 2>/dev/null; then
            echo "[INFO] 防火墙规则缺失，正在添加 LAN→TCP 5588 规则..."
            uci add firewall rule
            uci set firewall.@rule[-1].name='LeigodAcc'
            uci set firewall.@rule[-1].src='lan'
            uci set firewall.@rule[-1].dest_port='5588'
            uci set firewall.@rule[-1].proto='tcp'
            uci set firewall.@rule[-1].target='ACCEPT'
            uci commit firewall
            /etc/init.d/firewall restart >/dev/null 2>&1
            echo "[INFO] 防火墙规则已添加（下次状态检查生效）"
        fi
    fi
    echo "============================="
}

# ============================================================
# Latency fluctuation diagnosis
# ============================================================
# When acceleration works but game latency fluctuates (e.g.
# 50ms → 100ms+ spikes), the most common causes are:
#   1. Bufferbloat — WAN buffer overflow without SQM/QoS
#   2. GAMEACC hijacks ALL traffic, not just game traffic
#   3. conntrack table pressure causing connection drops
#   4. DNS relay latency through the TURN tunnel
diagnose_latency() {
    echo
    echo "============================="
    echo "  延迟波动诊断"
    echo "============================="

    local issues=0
    wan_if=$(ip route show default 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}' | head -1)
    [ -z "$wan_if" ] && wan_if=$(ip route show default 2>/dev/null | awk '{print $5}' | head -1)

    # --- 1. Bufferbloat: check queue discipline ---
    echo
    echo "[1/5] 队列管理 (QoS)"
    echo "  WAN 接口: ${wan_if:-unknown}"
    local has_fq_codel=0
    local has_cake=0
    local has_sqm=0
    local wan_noqdisc=0
    tc qdisc show 2>/dev/null | grep -q "fq_codel" && has_fq_codel=1
    tc qdisc show 2>/dev/null | grep -q "cake" && has_cake=1
    [ -f /etc/init.d/sqm ] || [ -f /etc/config/sqm ] && has_sqm=1

    # Check if the ACTUAL WAN interface has any qdisc
    if [ -n "$wan_if" ]; then
        wan_qdisc=$(tc qdisc show dev "$wan_if" 2>/dev/null | head -1)
        if echo "$wan_qdisc" | grep -q "noqueue\|qdisc noqueue"; then
            wan_noqdisc=1
        fi
    fi

    # PPPoE-specific: physical NIC may have fq_codel but the PPPoE tunnel does not
    if [ "$wan_noqdisc" = "1" ]; then
        echo "  [FAIL] WAN 接口 $wan_if 无队列管理!"
        if echo "$wan_if" | grep -qE "pppoe|ppp"; then
            echo "  → PPPoE 隧道口无 qdisc。注意: 不要在 pppoe 虚拟接口上加 qdisc"
            echo "  → 物理网卡 (eth0) 的 fq_codel 已覆盖出口流量"
            echo "  → 如延迟仍波动, 安装 SQM 对 PPPoE 做端到端整形:"
            echo "    opkg update && opkg install sqm-scripts luci-app-sqm"
        else
            echo "  → 请安装 SQM 或手动添加队列规则"
            echo -n "  是否立即添加 fq_codel? (y/n): "
            read add_fq
            case "$add_fq" in
                [Yy]|[Yy][Ee][Ss])
                    tc qdisc add dev "$wan_if" root fq_codel 2>/dev/null && \
                        echo "  [INFO] fq_codel 已添加" || \
                        echo "  [WARN] 添加失败"
                    ;;
            esac
        fi
        issues=$((issues + 1))
    elif [ "$has_sqm" = "1" ]; then
        echo "  [OK] SQM QoS 已配置 (最佳防抖动方案)"
    elif [ "$has_cake" = "1" ]; then
        echo "  [OK] cake qdisc 已启用 (优秀的防抖动方案)"
    elif [ "$has_fq_codel" = "1" ]; then
        echo "  [WARN] 仅 fq_codel (基础防抖动, 建议升级到 SQM)"
        echo "  → fq_codel 只控制出站队列, 入站流量无法管理"
        echo "  → 建议: opkg update && opkg install sqm-scripts luci-app-sqm"
        echo "  → 安装后在 LuCI → 网络 → SQM QoS 中配置 $wan_if 接口"
        issues=$((issues + 1))
    else
        echo "  [FAIL] 无队列管理! 延迟波动的主要根因"
        echo "  → 请立即安装: opkg update && opkg install sqm-scripts luci-app-sqm"
        issues=$((issues + 1))
    fi

    # --- 2. Check GAMEACC traffic distribution ---
    echo
    echo "[2/6] GAMEACC 流量分析"

    local tproxy_total_pkts=0
    # Use iptables-nft -x for exact counters (no K/M/G suffix), parse with awk
    # Fallback to plain iptables if iptables-nft is absent (some minimal builds only
    # symlink iptables → iptables-nft without providing a separate iptables-nft binary)
    local tproxy_lines ipt_cmd
    ipt_cmd="iptables-nft"
    [ -x /usr/sbin/iptables-nft ] || ipt_cmd="iptables"
    tproxy_lines=$($ipt_cmd -t mangle -L GAMEACC -n -v -x 2>/dev/null | grep "TPROXY")
    if [ -n "$tproxy_lines" ]; then
        tproxy_total_pkts=$(echo "$tproxy_lines" | awk '{s+=$1} END {print s+0}')
        echo "  TPROXY 总数据包: $tproxy_total_pkts"
        echo "  → 这是所有通过加速通道的流量"

        if [ "$tproxy_total_pkts" -gt 50000 ] 2>/dev/null; then
            echo "  [WARN] TPROXY 流量较大, 可能有非游戏流量被劫持"
            echo "  → 建议加速前关闭大流量下载/视频流"
            issues=$((issues + 1))
        fi
    else
        echo "  [WARN] 未找到 TPROXY 规则 — 加速可能未激活"
        issues=$((issues + 1))
    fi

    # --- 3. conntrack table pressure ---
    echo
    echo "[3/6] 连接追踪 (conntrack)"
    local ct_count ct_max
    ct_count=$(cat /proc/sys/net/netfilter/nf_conntrack_count 2>/dev/null)
    ct_max=$(cat /proc/sys/net/netfilter/nf_conntrack_max 2>/dev/null)

    if [ -n "$ct_count" ] && [ -n "$ct_max" ] && [ "$ct_max" -gt 0 ]; then
        local ct_pct=$((ct_count * 100 / ct_max))
        echo "  当前: $ct_count / $ct_max ($ct_pct%)"
        if [ "$ct_pct" -gt 80 ]; then
            local new_ct_max=$((ct_max * 2))
            echo "  [WARN] 连接追踪表使用率 > 80%, 可能导致新连接延迟"
            echo "  → 建议扩大: echo $new_ct_max > /proc/sys/net/netfilter/nf_conntrack_max"
            echo -n "  → 是否立即扩大到 ${new_ct_max}? (y/n): "
            read expand_ct
            case "$expand_ct" in
                [Yy]|[Yy][Ee][Ss])
                    echo "$new_ct_max" > /proc/sys/net/netfilter/nf_conntrack_max 2>/dev/null && \
                        echo "  [OK] conntrack_max 已扩大到 $new_ct_max" || \
                        echo "  [WARN] 写入失败, 请手动: echo $new_ct_max > /proc/sys/net/netfilter/nf_conntrack_max"
                    ;;
            esac
            issues=$((issues + 1))
        else
            echo "  [OK] 连接追踪表压力正常"
        fi
    else
        echo "  [INFO] 无法读取 conntrack 状态 (可能模块未加载)"
    fi

    # --- 4. DNS relay check ---
    echo
    echo "[4/6] DNS 中继延迟"
    dns_rule_pkts=$($ipt_cmd -t mangle -L GAMEACC -n -v 2>/dev/null | grep "dport 53" | awk '{print $1}')
    if [ -n "$dns_rule_pkts" ] && [ "$dns_rule_pkts" != "0" ] 2>/dev/null; then
        echo "  DNS 劫持包数: $dns_rule_pkts"
        echo "  → DNS 通过 TURN 中继解析会增加额外延迟"
        echo "  → 但 DNS 只在连接建立时发生, 不影响游戏中持续延迟"
    else
        echo "  [OK] DNS 未走加速通道或无流量"
    fi

    # --- 5. TURN relay stability & jitter ---
    echo
    echo "[5/6] TURN 中继稳定性"
    # Use the same hostname acc-gw resolves internally; ping lets the system handle DNS
    local turn_host="route-turn.xxghh.biz"
    ping_result=$(ping -c 5 -W 2 "$turn_host" 2>/dev/null | tail -1)
    if echo "$ping_result" | grep -q "0%"; then
        local avg_ms min_ms max_ms mdev_ms
        avg_ms=$(echo "$ping_result" | grep -oE "[0-9]+\.[0-9]+/[0-9]+\.[0-9]+/[0-9]+\.[0-9]+/[0-9]+\.[0-9]+" | cut -d/ -f2)
        min_ms=$(echo "$ping_result" | grep -oE "[0-9]+\.[0-9]+/[0-9]+\.[0-9]+/[0-9]+\.[0-9]+/[0-9]+\.[0-9]+" | cut -d/ -f1)
        max_ms=$(echo "$ping_result" | grep -oE "[0-9]+\.[0-9]+/[0-9]+\.[0-9]+/[0-9]+\.[0-9]+/[0-9]+\.[0-9]+" | cut -d/ -f3)
        mdev_ms=$(echo "$ping_result" | grep -oE "[0-9]+\.[0-9]+/[0-9]+\.[0-9]+/[0-9]+\.[0-9]+/[0-9]+\.[0-9]+" | cut -d/ -f4)
        echo "  [OK] $turn_host 可达, 平均: ${avg_ms:-N/A} ms"
        [ -n "$min_ms" ] && [ -n "$max_ms" ] && echo "  最小/最大: ${min_ms}/${max_ms} ms, 抖动(mdev): ${mdev_ms:-N/A} ms"
        # High jitter to the TURN relay is a red flag
        if [ -n "$mdev_ms" ] && [ "$(echo "$mdev_ms > 15" | bc 2>/dev/null)" = "1" ] 2>/dev/null; then
            echo "  [WARN] TURN 中继抖动 > 15ms — 中继侧网络可能不稳定"
            issues=$((issues + 1))
        elif [ -n "$mdev_ms" ] && [ "$(echo "$mdev_ms > 50" | bc 2>/dev/null)" = "1" ] 2>/dev/null; then
            echo "  [FAIL] TURN 中继抖动 > 50ms! 这是延迟波动的主要来源"
            echo "  → 中继服务可能过载, 建议联系雷神客服反馈"
            issues=$((issues + 1))
        fi
    elif ping -c 3 -W 2 "$turn_host" >/dev/null 2>&1; then
        echo "  [OK] $turn_host 连通正常"
    else
        echo "  [FAIL] TURN 中继不可达!"
        echo "  → 请手动: ping $turn_host"
        issues=$((issues + 1))
    fi

    # --- 6. PPPoE fragmentation / TCP MSS ---
    echo
    echo "[6/6] PPPoE MTU/分片检查"
    if echo "${wan_if:-}" | grep -qE "pppoe|ppp"; then
        echo "  检测到 PPPoE 接口: $wan_if"
        # Check if TCP MSS clamping is in place
        if iptables -t mangle -L FORWARD -n 2>/dev/null | grep -q "TCPMSS.*clamp-mss-to-pmtu"; then
            echo "  [OK] TCP MSS clamping 已配置 (避免分片)"
        else
            echo "  [WARN] PPPoE 缺少 TCP MSS clamping — 大包可能被分片, 增加延迟"
            echo "  → 分片会显著增加延迟抖动 (额外的重组等待)"
            echo -n "  → 是否立即添加 TCP MSS clamping? (y/n): "
            read add_mss
            case "$add_mss" in
                [Yy]|[Yy][Ee][Ss])
                    iptables -t mangle -A FORWARD -o "$wan_if" -p tcp --tcp-flags SYN,RST SYN \
                        -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null && \
                        echo "  [OK] TCP MSS clamping 已添加" || \
                        echo "  [WARN] 添加失败, 请手动添加"
                    ;;
            esac
            issues=$((issues + 1))
        fi
        # Check MTU sanity
        ppp_mtu=$(ip link show "$wan_if" 2>/dev/null | grep -o "mtu [0-9]*" | awk '{print $2}')
        if [ -n "$ppp_mtu" ] && [ "$ppp_mtu" -lt 1492 ] 2>/dev/null; then
            echo "  [WARN] PPPoE MTU 偏低: $ppp_mtu (标准 1492)"
            echo "  → MTU 过小会增加包数和每包开销, 建议设为 1492"
            issues=$((issues + 1))
        elif [ -n "$ppp_mtu" ]; then
            echo "  [OK] PPPoE MTU: $ppp_mtu"
        fi
    else
        echo "  [OK] 非 PPPoE 接口 (${wan_if:-unknown}), 无需 MSS clamping"
    fi

    # --- Summary ---
    echo
    echo "============================="
    if [ "$issues" -eq 0 ]; then
        echo "  诊断结果: 未发现明显问题"
        echo "  延迟波动可能来自:"
        echo "  1. 雷神中继 → 游戏服务器 路径抖动 (无法控制)"
        echo "  2. 游戏服务器自身负载波动"
        echo "  3. ISP 骨干网拥堵"
    else
        echo "  诊断结果: 发现 $issues 个潜在问题 (见上方 [WARN]/[FAIL])"
        echo ""
        echo "  推荐操作顺序:"
        echo "  1. 安装 SQM QoS (解决 bufferbloat — 最可能根因)"
        echo "  2. 加速前暂停大流量下载/视频"
        echo "  3. 扩大 conntrack 表 (如使用率 > 80%)"
        echo "  4. 运行 leigod-fw4.sh tune-network 应用内核优化"
    fi

    # SQM offer
    # Offer SQM if no SQM/cake, OR if WAN interface has no qdisc (e.g. PPPoE)
    if [ "$has_sqm" = "0" ] && [ "$has_cake" = "0" ]; then
        echo
        echo -n "是否立即安装 SQM QoS? (y/n): "
        read install_sqm_choice
        case "$install_sqm_choice" in
            [Yy]|[Yy][Ee][Ss])
                install_sqm
                ;;
        esac
    fi
    echo "============================="
}

# ============================================================
# Install SQM QoS (CAKE qdisc) for bufferbloat prevention
# ============================================================
install_sqm() {
    wan_if=$(ip route show default 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}' | head -1)
    [ -z "$wan_if" ] && wan_if=$(ip route show default 2>/dev/null | awk '{print $5}' | head -1)
    [ -z "$wan_if" ] && wan_if="eth0"

    echo "[INFO] 检测到 WAN 接口: $wan_if"

    local is_pppoe=0
    echo "$wan_if" | grep -qE "pppoe|ppp" && is_pppoe=1

    # Remove any previously-added fq_codel on PPPoE from rc.local (bug fix: PPPoE double-queueing)
    if [ "$is_pppoe" = "1" ] && [ -f /etc/rc.local ]; then
        sed -i "/tc qdisc.*$wan_if.*fq_codel/d" /etc/rc.local 2>/dev/null
    fi

    # Try package-based SQM first
    echo "[INFO] 尝试安装 SQM 包..."
    opkg update >/dev/null 2>&1
    local pkg_ok=0
    if opkg install sqm-scripts luci-app-sqm 2>/dev/null; then
        pkg_ok=1
        local linklayer="ethernet"
        local overhead=44
        if [ "$is_pppoe" = "1" ]; then
            linklayer="atm"
            overhead=40  # PPPoE: 8 (PPPoE header) + 32 (ATM/AAL5)
        fi
        uci set sqm.@queue[0].enabled='1'
        uci set sqm.@queue[0].interface="$wan_if"
        uci set sqm.@queue[0].download='0'
        uci set sqm.@queue[0].upload='0'
        uci set sqm.@queue[0].qdisc='cake'
        uci set sqm.@queue[0].script='piece_of_cake.qos'
        uci set sqm.@queue[0].linklayer="$linklayer"
        uci set sqm.@queue[0].overhead="$overhead"
        uci commit sqm
        /etc/init.d/sqm enable 2>/dev/null
        /etc/init.d/sqm start 2>/dev/null
        echo "[INFO] SQM 已安装并启动。请在 LuCI → 网络 → SQM QoS 中设置带宽值"
    else
        echo "[WARN] SQM 包不可用"
    fi

    # For NON-PPPoE interfaces with no qdisc, add fq_codel fallback
    # IMPORTANT: Do NOT add qdisc to PPPoE virtual interfaces — the PPPoE
    # kernel module has its own internal TX queue. Adding fq_codel on top
    # creates double queueing and INCREASES latency.
    if [ "$is_pppoe" = "0" ]; then
        if tc qdisc show dev "$wan_if" 2>/dev/null | head -1 | grep -q "noqueue"; then
            echo "[INFO] $wan_if 无队列管理，正在添加 fq_codel..."
            if tc qdisc add dev "$wan_if" root fq_codel 2>/dev/null; then
                echo "[INFO] fq_codel 已添加到 $wan_if (立即生效)"
                if ! grep -q "tc qdisc.*$wan_if.*fq_codel" /etc/rc.local 2>/dev/null; then
                    [ ! -f /etc/rc.local ] && { echo "#!/bin/sh"; echo "exit 0"; } > /etc/rc.local
                    sed -i "/^exit 0/i tc qdisc add dev $wan_if root fq_codel 2>/dev/null" /etc/rc.local
                    echo "[INFO] 已添加到 /etc/rc.local"
                fi
            fi
        else
            echo "[INFO] $wan_if 已有队列管理"
        fi
    elif [ "$pkg_ok" = "0" ]; then
        # PPPoE without SQM: the physical ethX already has fq_codel via
        # OpenWrt defaults. No additional qdisc needed on pppoe-wan.
        echo "[INFO] PPPoE 接口，物理网卡已有 fq_codel 覆盖 — 无需额外配置"
        echo "[TIP] 如仍有延迟波动，请在 LuCI 中安装 SQM (if available)"
    fi

    # Clamp TCP MSS for PPPoE (avoid fragmentation)
    if [ "$is_pppoe" = "1" ]; then
        if ! iptables -t mangle -C FORWARD -o "$wan_if" -p tcp --tcp-flags SYN,RST SYN \
            -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null; then
            iptables -t mangle -A FORWARD -o "$wan_if" -p tcp --tcp-flags SYN,RST SYN \
                -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null && \
                echo "[INFO] TCP MSS clamping 已添加 (避免 PPPoE 分片)"
        fi
    fi
}

# ============================================================
# Apply kernel network tuning for low-latency gaming
# ============================================================
# Tunes kernel parameters that reduce latency jitter:
#   - Sets default qdisc to fq_codel (fair queuing + AQM)
#   - Enables BBR congestion control (better for lossy links)
#   - Increases socket buffers (reduces drops under burst)
#   - Reduces conntrack timeout for established TCP (frees table slots)
#   - Enables TCP fastopen (reduces connection setup latency)
#
# These changes are applied immediately and also written to
# /etc/sysctl.d/99-leigod-latency.conf for persistence across reboots.
apply_network_tuning() {
    local SYSCTL_CONF="/etc/sysctl.d/99-leigod-latency.conf"
    local applied=0

    echo
    echo "============================="
    echo "  内核网络调优 (低延迟游戏)"
    echo "============================="
    echo "[INFO] 正在应用调优参数..."

    # Back up existing conf if present
    [ -f "$SYSCTL_CONF" ] && cp "$SYSCTL_CONF" "${SYSCTL_CONF}.bak"

    cat > "$SYSCTL_CONF" << 'SYSCTLEOF'
# LeigodAcc low-latency gaming network tuning
# Generated by leigod-fw4.sh apply_network_tuning

# ----- Queuing discipline -----
# fq_codel: fair queuing with controlled delay — prevents bufferbloat
# by dropping packets from flows that are consuming too much bandwidth,
# which signals TCP senders to back off BEFORE the queue fills up.
net.core.default_qdisc = fq_codel

# ----- TCP congestion control -----
# BBR: Bottleneck Bandwidth and Round-trip propagation time.
# Better than cubic for lossy/gaming links — doesn't treat every
# packet loss as congestion, maintains higher throughput under jitter.
net.ipv4.tcp_congestion_control = bbr

# ----- Socket buffer sizes -----
# Larger buffers prevent packet drops during traffic bursts
# (e.g. game data + voice chat arriving simultaneously).
# Values in bytes. Defaults are ~212992; these allow up to 4MB.
net.core.rmem_max = 4194304
net.core.wmem_max = 4194304
# Increase the default send/receive buffer for all sockets
net.core.rmem_default = 262144
net.core.wmem_default = 262144

# ----- TCP fast open -----
# TFO allows data in the SYN packet, saving 1 RTT on connection setup.
# 3 = enable for both client and server.
net.ipv4.tcp_fastopen = 3

# ----- Conntrack -----
# Reduce established TCP timeout from default 432000 (5 days) to
# 3600 (1 hour). This frees conntrack table entries faster,
# preventing table pressure that causes connection delays.
net.netfilter.nf_conntrack_tcp_timeout_established = 3600
# Increase max conntrack entries to 65536 (default is often 16384).
# More headroom prevents "table full" drops.
net.netfilter.nf_conntrack_max = 65536

# ----- TCP keepalive -----
# Faster keepalive detection for broken connections (games often use
# long-lived UDP connections that don't benefit from this, but it
# helps with control-plane TCP connections to the TURN relay).
net.ipv4.tcp_keepalive_time = 120
net.ipv4.tcp_keepalive_intvl = 30
net.ipv4.tcp_keepalive_probes = 3

# ----- IPv6 -----
# Disable IPv6 if not needed (reduces DNS lookup latency and
# prevents games from inadvertently using IPv6 paths).
# Leave unset by default; enable via leigod-fw4.sh disable-ipv6
# net.ipv6.conf.all.disable_ipv6 = 1
SYSCTLEOF

    # Apply immediate
    sysctl -p "$SYSCTL_CONF" >/dev/null 2>&1 && applied=1

    echo ""
    echo "  已应用的调优项:"
    echo "  - 默认 qdisc:     fq_codel (防 bufferbloat)"
    echo "  - 拥塞控制:       BBR (更适合有损/抖动链路)"
    echo "  - Socket 缓冲区:  rmem/wmem = 4MB max, 256KB default"
    echo "  - TCP fastopen:   启用 (减少连接建立 1 RTT)"
    echo "  - Conntrack:      max=65536, tcp_timeout=3600s"
    echo "  - TCP keepalive:  120s (快速检测断连)"

    if [ "$applied" = "1" ]; then
        echo ""
        echo "  [OK] 参数已生效并持久化到: $SYSCTL_CONF"
        echo "  → 重启后自动加载, 无需额外配置"
    else
        echo "  [WARN] sysctl 应用可能未完全生效 (某些参数可能需要内核支持)"
        echo "  → BBR 需要内核编译支持: CONFIG_TCP_CONG_BBR=y"
    fi

    # Check if BBR is actually available
    if [ -f /proc/sys/net/ipv4/tcp_congestion_control ]; then
        current_cc=$(cat /proc/sys/net/ipv4/tcp_congestion_control 2>/dev/null)
        echo "  → 当前拥塞控制: $current_cc"
        if [ "$current_cc" != "bbr" ] && grep -q "bbr" /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null; then
            echo "  → BBR 可用但未激活, 可能被其他配置覆盖"
            echo "  → 手动: echo bbr > /proc/sys/net/ipv4/tcp_congestion_control"
        fi
    fi

    # Check conntrack max
    ct_max=$(cat /proc/sys/net/netfilter/nf_conntrack_max 2>/dev/null)
    [ -n "$ct_max" ] && echo "  → 当前 conntrack_max: $ct_max"

    echo "============================="
}

# ============================================================
# Auto-Pause — 自动暂停时长计费
# ============================================================
AUTO_PAUSE_SCRIPT="/usr/sbin/leigod-auto-pause.sh"
AUTO_PAUSE_CONF="/etc/leigod-auto-pause.conf"
AUTO_PAUSE_CRON="/etc/crontabs/root"

auto_pause_menu() {
    echo
    echo "============================="
    echo " 自动暂停时长管理"
    echo "============================="
    echo " 检测到设备停止加速后，自动调用"
    echo " 雷神 API 暂停时长计费，避免浪费。"
    echo
    echo "1. 安装/配置 自动暂停"
    echo "2. 卸载 自动暂停"
    echo "3. 查看运行状态"
    echo "4. 手动暂停一次 (测试)"
    echo "0. 返回主菜单"
    echo "============================="
    echo -n "选择: "
    read sub_choice
    case $sub_choice in
        1) auto_pause_install ;;
        2) auto_pause_uninstall ;;
        3) auto_pause_status ;;
        4) auto_pause_trigger ;;
        0) return ;;
        *) echo "[ERROR] 无效选项" ;;
    esac
}

auto_pause_install() {
    echo "[INFO] 配置自动暂停..."

    # Check if leigod-acc is installed
    if [ ! -f /etc/init.d/acc ] || [ ! -d /usr/sbin/leigod ]; then
        echo "[ERROR] 尚未安装雷神加速器（缺少 init 脚本或二进制目录），请先安装"
        return 1
    fi

    # Deploy the latest embedded auto-pause script (always overwrite)
    echo "[INFO] 正在部署脚本..."
    cat > "$AUTO_PAUSE_SCRIPT" << 'AUTOSCRIPT'
#!/bin/sh
# ============================================================
# LeigodAcc Auto-Pause — 自动暂停时长计费 (v2.5, inline)
#
# Token: LuCI 书签一键获取 → pause API 调用
#   登录 API 有 CloudWAF 保护，无法自动化登录。
#   使用 LuCI 自动暂停页面的书签获取 token。
#   每 7 天点击一次，5 秒完成。
#
# 空闲检测: cron 定时检查，连续空闲 N 次后触发暂停
#   总空闲时间 = IDLE_CHECK_INTERVAL(分钟) × IDLE_CHECKS_BEFORE_PAUSE(次)
# ============================================================

CONFIG_FILE="/etc/leigod-auto-pause.conf"
STATE_FILE="/tmp/leigod-auto-pause.state"
LOG_TAG="leigod-auto-pause"

load_config() {
    ACCOUNT_TOKEN=""
    IDLE_CHECKS_BEFORE_PAUSE=3
    IDLE_CHECK_INTERVAL=2
    API_TIMEOUT=10
    API_ENDPOINT="https://webapi.leigod.com"
    NOTIFY_ON_PAUSE=1
    MANUAL_DISABLE=0
    if [ -f "$CONFIG_FILE" ]; then . "$CONFIG_FILE"; fi
    [ -z "$IDLE_CHECKS_BEFORE_PAUSE" ] && IDLE_CHECKS_BEFORE_PAUSE=3
    [ -z "$IDLE_CHECK_INTERVAL" ] && IDLE_CHECK_INTERVAL=2
    [ -z "$API_TIMEOUT" ] && API_TIMEOUT=10
    [ -z "$MANUAL_DISABLE" ] && MANUAL_DISABLE=0
}

get_token() {
    if [ -n "$ACCOUNT_TOKEN" ]; then echo "$ACCOUNT_TOKEN"; return 0; fi
    return 1
}

check_all_idle() {
    if [ -f /tmp/acc/acc_core_conf.json ]; then
        if grep -q '"state":1' /tmp/acc/acc_core_conf.json 2>/dev/null; then return 1; fi
    fi
    for dev in Phone PC Game Unknown; do
        local state; state=$(uci get "accelerator.${dev}.state" 2>/dev/null)
        [ "$state" = "1" ] && return 1
    done
    return 0
}

is_idle() {
    if [ -f /etc/config/accelerator ]; then check_all_idle; return $?; fi
    if ! pgrep -f "acc-gw" >/dev/null 2>&1; then return 0; fi
    return 1
}

call_pause_api() {
    local token="$1" resp code
    resp=$(curl -sL --connect-timeout "$API_TIMEOUT" -X POST "${API_ENDPOINT}/api/user/pause" \
        -H 'Content-Type: application/json' -H 'User-Agent: LeigodAcc-AutoPause/2.5' \
        -d "{\"account_token\":\"${token}\",\"lang\":\"zh_CN\"}" 2>/dev/null)
    code=$(echo "$resp" | grep -o '"code": *[-0-9]*' | head -1 | grep -o '[-0-9]*$')
    echo "$code"
}

read_state() {
    local idle_count=0 last_pause_epoch=0
    if [ -f "$STATE_FILE" ]; then
        local key val
        while IFS='=' read -r key val; do
            case "$key" in idle_count) idle_count="$val" ;; last_pause_epoch) last_pause_epoch="$val" ;; esac
        done < "$STATE_FILE"
    fi
    IDLE_COUNT=$idle_count; LAST_PAUSE_EPOCH=$last_pause_epoch
}

write_state() {
    cat > "$STATE_FILE" << STATEOF
idle_count=${IDLE_COUNT}
last_pause_epoch=${LAST_PAUSE_EPOCH}
STATEOF
}

main() {
    load_config

    # Manual disable: skip all idle detection and pause logic
    if [ "$MANUAL_DISABLE" = "1" ]; then
        read_state
        IDLE_COUNT=0
        if [ ! -f /tmp/leigod-away.logged ]; then
            logger -t "$LOG_TAG" "离家模式已启用, 跳过本次自动暂停检测"
            touch /tmp/leigod-away.logged
        fi
        write_state
        return 0
    fi
    # Clean up away-mode marker when normal mode resumes
    rm -f /tmp/leigod-away.logged
    local TOKEN; TOKEN=$(get_token 2>/dev/null)
    if [ -z "$TOKEN" ]; then
        logger -t "$LOG_TAG" "account_token 未配置, 请通过 LuCI 自动暂停页面的书签获取"
        return 1
    fi
    read_state
    local now; now=$(date +%s)
    if [ "$LAST_PAUSE_EPOCH" != "0" ] && [ $((now - LAST_PAUSE_EPOCH)) -lt 600 ]; then return 0; fi
    if is_idle; then
        IDLE_COUNT=$((IDLE_COUNT + 1))
        logger -t "$LOG_TAG" "检测到空闲 (${IDLE_COUNT}/${IDLE_CHECKS_BEFORE_PAUSE})"
        if [ "$IDLE_COUNT" -ge "$IDLE_CHECKS_BEFORE_PAUSE" ]; then
            logger -t "$LOG_TAG" "空闲阈值达到, 正在调用暂停 API..."
            local api_code; api_code=$(call_pause_api "$TOKEN")
            case "$api_code" in
                0) logger -t "$LOG_TAG" "暂停成功!"; LAST_PAUSE_EPOCH=$now; IDLE_COUNT=0 ;;
                400803) logger -t "$LOG_TAG" "已经处于暂停状态"; LAST_PAUSE_EPOCH=$now; IDLE_COUNT=0 ;;
                400006) logger -t "$LOG_TAG" "token 已过期, 请重新通过书签获取"; IDLE_COUNT=$((IDLE_CHECKS_BEFORE_PAUSE - 1)) ;;
                "") logger -t "$LOG_TAG" "API 请求失败 (网络/curl 错误)" ;;
                *) logger -t "$LOG_TAG" "API 返回异常 (code=$api_code)" ;;
            esac
        fi
    else
        [ "$IDLE_COUNT" -gt 0 ] && logger -t "$LOG_TAG" "设备活跃, 重置空闲计数"
        IDLE_COUNT=0
    fi
    write_state
}
main "$@"
AUTOSCRIPT
    chmod +x "$AUTO_PAUSE_SCRIPT"
    echo "[INFO] 已部署内嵌脚本到 $AUTO_PAUSE_SCRIPT"

    # Configure account_token (OPTIONAL — daemon token is auto-used as fallback)
    echo ""
    echo "=========================================="
    echo "  Token 获取:"
    echo "  LuCI → 自动暂停 → 拖书签到浏览器书签栏"
    echo "  打开 leigod.com 登录后 → 点击书签 → 一键获取"
    echo ""
    echo "  或手动: 浏览器 F12 → localStorage → account_token"
    echo "=========================================="
    echo ""

    if [ -f "$AUTO_PAUSE_CONF" ]; then
        echo "[INFO] 配置文件已存在: $AUTO_PAUSE_CONF"
        echo -n "是否重新配置? (y/n/回车=保持现有): "
        read update_choice
        case "$update_choice" in
            [Yy]) ;;
            *)  auto_pause_setup_cron; return ;;
        esac
    fi

    printf '# LeigodAcc Auto-Pause configuration\n' > "$AUTO_PAUSE_CONF"

    # Account token
    echo -n "account_token (回车跳过, 稍后通过书签获取): "
    read -s token
    echo ""
    if [ -n "$token" ]; then
        printf "ACCOUNT_TOKEN='%s'\n" "$token" >> "$AUTO_PAUSE_CONF"
        echo "[INFO] 已配置 token"
    else
        echo "[INFO] 稍后可通过 LuCI 自动暂停页面书签一键获取 token"
    fi
    cat >> "$AUTO_PAUSE_CONF" << 'CONFOF'
IDLE_CHECKS_BEFORE_PAUSE=3
API_TIMEOUT=10
API_ENDPOINT="https://webapi.leigod.com"
NOTIFY_ON_PAUSE=1
MANUAL_DISABLE=0
CONFOF
    chmod 600 "$AUTO_PAUSE_CONF"
    echo "[INFO] 配置已保存: $AUTO_PAUSE_CONF"

    auto_pause_setup_cron
}

auto_pause_setup_cron() {
    # Read custom interval from config, default 2 minutes
    local interval=2
    if [ -f "$AUTO_PAUSE_CONF" ]; then
        cfg_int=$(grep "^IDLE_CHECK_INTERVAL=" "$AUTO_PAUSE_CONF" 2>/dev/null | cut -d= -f2)
        [ -n "$cfg_int" ] && [ "$cfg_int" -ge 1 ] && interval="$cfg_int"
    fi

    # Remove old cron entry, add new one with current interval
    sed -i '/leigod-auto-pause/d' "$AUTO_PAUSE_CRON" 2>/dev/null
    echo "*/${interval} * * * * $AUTO_PAUSE_SCRIPT >> /tmp/leigod-auto-pause.log 2>&1" >> "$AUTO_PAUSE_CRON"
    /etc/init.d/cron restart 2>/dev/null
    echo "[INFO] cron 已配置（每 ${interval} 分钟检查一次）"
    echo "[INFO] 安装完成！设备停止加速后约 $(( interval * 3 )) 分钟内自动暂停计费"
}

auto_pause_uninstall() {
    echo "[INFO] 卸载自动暂停..."

    # Remove cron entry
    if [ -f "$AUTO_PAUSE_CRON" ]; then
        sed -i '/leigod-auto-pause/d' "$AUTO_PAUSE_CRON"
        /etc/init.d/cron restart 2>/dev/null
    fi

    rm -f "$AUTO_PAUSE_SCRIPT"
    rm -f "$AUTO_PAUSE_CONF"
    rm -f /tmp/leigod-auto-pause.state
    rm -f /tmp/leigod-auto-pause.log
    echo "[INFO] 已卸载"
}

auto_pause_status() {
    echo
    if [ -f "$AUTO_PAUSE_CONF" ]; then
        echo "[配置] $AUTO_PAUSE_CONF: 已配置"
        . "$AUTO_PAUSE_CONF"
        if [ -n "$ACCOUNT_TOKEN" ]; then
            local token_len
            token_len=${#ACCOUNT_TOKEN}
            echo "  token: ${ACCOUNT_TOKEN:0:8}...${ACCOUNT_TOKEN:$((token_len - 4))}"
        fi
        # Show manual disable status
        if [ "$MANUAL_DISABLE" = "1" ]; then
            echo "[模式] 离家模式 (自动暂停已禁用)"
        else
            echo "[模式] 自动模式 (正常检测空闲)"
        fi
    else
        echo "[配置] 未配置"
    fi

    if grep -q "leigod-auto-pause" "$AUTO_PAUSE_CRON" 2>/dev/null; then
        echo "[cron] 已启用 (每2分钟)"
    else
        echo "[cron] 未启用"
    fi

    if [ -f /tmp/leigod-auto-pause.state ]; then
        echo "[状态]"
        cat /tmp/leigod-auto-pause.state
    fi

    # Show recent logs
    if [ -f /tmp/leigod-auto-pause.log ]; then
        echo "[最近日志]"
        tail -5 /tmp/leigod-auto-pause.log
    fi

    # Show current UCI accelerator state
    if [ -f /etc/config/accelerator ]; then
        echo "[加速状态]"
        for dev in Phone PC Game Unknown; do
            local state
            state=$(uci get "accelerator.${dev}.state" 2>/dev/null)
            case "$state" in
                1) echo "  $dev: 加速中" ;;
                2) echo "  $dev: 已停止" ;;
                3) echo "  $dev: 已暂停" ;;
                *) echo "  $dev: 无" ;;
            esac
        done
    fi
    echo
}

auto_pause_trigger() {
    if [ ! -f "$AUTO_PAUSE_SCRIPT" ]; then
        echo "[ERROR] 脚本未安装，请先执行选项1"
        return 1
    fi
    echo "[INFO] 手动触发暂停检查..."
    sh "$AUTO_PAUSE_SCRIPT"
    echo "[INFO] 执行完毕，请查看上方输出或 /tmp/leigod-auto-pause.log"
}

# ============================================================
# Help
# ============================================================
help() {
    echo ""
    echo "BLOG: https://www.miaoer.net/posts/blog/openwrt-leigodacc-manager"
    echo "[Tip] LeigodAcc 特指雷神加速器，leigod-acc 特指 Lean 版雷神插件"
    echo ""
    echo "HELP："
    echo "1. 安装：安装 LeigodAcc"
    echo "2. 卸载：卸载 LeigodAcc"
    echo "3. 重装：重装 LeigodAcc"
    echo "4. 禁用/启用：禁用或启用 LeigodAcc 服务"
    echo "5. 切换运行模式：在 TUN 和 Tproxy 模式之间切换"
    echo "6. 安装兼容性依赖：尝试使用天灵 immortalwrt pku 源安装常见缺失依赖"
    echo "7. 禁用 IPv6: 可以使手机部分手机游戏也能正常加速，会禁用掉 IPv6 网络"
    echo "8. 切换为 Lean IPKG 版：可以通过 opkg 安装 leigod-acc 插件，为实验性版本"
    echo "9. 自动暂停时长：检测到游戏结束自动暂停计费，省时长"
    echo "S. 查看服务状态：显示安装、运行、设备、日志等诊断信息"
    echo "L. 延迟波动诊断：检查 bufferbloat/QoS/GAMEACC 流量等延迟波动根因，可安装 SQM"
    echo "T. 内核网络调优：应用 fq_codel/BBR/conntrack 等低延迟优化参数"
    echo "H. 帮助：显示帮助信息"
    echo "0. 退出：退出管理器"
    echo ""
    echo "防火墙适配："
    echo "  当前防火墙: $FW_NAME"
    if [ "$FW_TYPE" = "fw4" ]; then
        echo "  已适配 OpenWrt 24.10+ fw4/nftables"
        echo "  已适配 fw4/nftables。请使用选项 S 诊断检查 tproxy_ip 是否匹配 LAN IP"
    else
        echo "  使用传统 fw3/iptables 模式"
    fi
    echo ""
    sleep 3
}

# ============================================================
# CLI: leigod-fw4.sh fix-tproxy
# Called by cron watcher to repair tproxy_ip when daemon
# overwrites acc_core_conf.json with hardcoded fake IP.
# ============================================================
if [ "$1" = "fix-tproxy" ]; then
    detect_firewall
    set_fw_packages
    if [ -f /tmp/acc/acc_core_conf.json ]; then
        fix_acc_core_conf
    fi
    exit 0
fi

# ============================================================
# CLI: leigod-fw4.sh tune-network
# Apply kernel network tuning optimizations for low-latency gaming.
# Safe to run repeatedly — subsequent runs will refresh parameters.
# ============================================================
if [ "$1" = "tune-network" ]; then
    detect_firewall
    set_fw_packages
    apply_network_tuning
    exit 0
fi

# ============================================================
# CLI: leigod-fw4.sh diagnose
# Non-interactive latency diagnosis (no y/n prompts — report only).
# Useful for cron jobs or scripting.
# ============================================================
if [ "$1" = "diagnose" ]; then
    detect_firewall
    set_fw_packages

    echo "============================="
    echo "  LeigodAcc 快速诊断报告"
    echo "  $(date '+%Y-%m-%d %H:%M:%S')"
    echo "============================="

    # System summary
    echo ""
    echo "--- 系统 ---"
    model=$(grep "model name" /proc/cpuinfo 2>/dev/null | head -1 | cut -d: -f2 | sed 's/^[ \t]*//')
    [ -z "$model" ] && model=$(uname -m)
    echo "  设备: $model"
    echo "  固件: $(grep DISTRIB_DESCRIPTION /etc/openwrt_release 2>/dev/null | cut -d"'" -f2)"
    echo "  内核: $(uname -r)"
    echo "  防火墙: $FW_NAME"

    # acc-gw process check
    echo ""
    echo "--- 进程 ---"
    if ps | grep -q "[a]cc-gw"; then
        pid=$(ps | grep "[a]cc-gw" | head -1 | awk '{print $1}')
        mode=$(ps ww | grep "[a]cc-gw" | head -1 | grep -oE -- "-m (tun|tproxy)" | awk '{print $2}')
        echo "  acc-gw: 运行中 (PID=$pid, mode=${mode:-unknown})"
        if netstat -tlnp 2>/dev/null | grep -q 5588 || ss -tlnp 2>/dev/null | grep -q 5588; then
            echo "  API 端口 5588: 监听中"
        else
            echo "  API 端口 5588: 未监听!"
        fi
    else
        echo "  acc-gw: 未运行"
    fi

    # acc_core_conf.json check
    echo ""
    echo "--- CoreConfig ---"
    conf="/tmp/acc/acc_core_conf.json"
    if [ -f "$conf" ]; then
        cip=$(sed -n 's/.*"tproxy_ip":"\([^"]*\)".*/\1/p' "$conf" 2>/dev/null)
        cmode=$(sed -n 's/.*"acc_mode":\([0-9]*\).*/\1/p' "$conf" 2>/dev/null)
        lan_ip=$(uci get network.lan.ipaddr 2>/dev/null)
        echo "  tproxy_ip: $cip $( [ "$cip" = "$lan_ip" ] && echo '[OK]' || echo '[MISMATCH!]')"
        echo "  acc_mode: $cmode $( [ "$cmode" = "2" ] && echo '[OK]' || echo '[UNSTABLE!]')"
    else
        echo "  文件不存在"
    fi

    # Network: conntrack + qdisc
    echo ""
    echo "--- 网络 ---"
    ct_count=$(cat /proc/sys/net/netfilter/nf_conntrack_count 2>/dev/null)
    ct_max=$(cat /proc/sys/net/netfilter/nf_conntrack_max 2>/dev/null)
    if [ -n "$ct_count" ] && [ -n "$ct_max" ] && [ "$ct_max" -gt 0 ]; then
        ct_pct=$((ct_count * 100 / ct_max))
        echo "  conntrack: $ct_count / $ct_max ($ct_pct%)"
    fi
    wan_if=$(ip route show default 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}' | head -1)
    [ -z "$wan_if" ] && wan_if=$(ip route show default 2>/dev/null | awk '{print $5}' | head -1)
    echo "  WAN: ${wan_if:-unknown}"
    if [ -n "$wan_if" ]; then
        qdisc=$(tc qdisc show dev "$wan_if" 2>/dev/null | head -1)
        echo "  qdisc: ${qdisc:-none}"
    fi

    # GAMEACC
    echo ""
    echo "--- GAMEACC ---"
    ipt_cmd="iptables-nft"
    [ -x /usr/sbin/iptables-nft ] || ipt_cmd="iptables"
    gc_count=$($ipt_cmd -t mangle -L GAMEACC -n 2>/dev/null | grep -c "TPROXY\|RETURN")
    echo "  活跃规则数: $gc_count"

    # TURN relay ping
    echo ""
    echo "--- TURN ---"
    ping -c 3 -W 2 route-turn.xxghh.biz >/dev/null 2>&1 && \
        echo "  route-turn.xxghh.biz: 可达" || \
        echo "  route-turn.xxghh.biz: 不可达!"

    echo ""
    echo "============================="
    exit 0
fi

# ============================================================
# CLI: leigod-fw4.sh verify-luci
# Verify LuCI installation integrity: 12 files + luci-compat
# + UCI config + auto-pause config.  Auto-repairs if possible.
# ============================================================
if [ "$1" = "verify-luci" ]; then
    detect_firewall
    set_fw_packages
    verify_luci
    exit 0
fi

# ============================================================
# Main - Initialize and start
# ============================================================
detect_firewall
set_fw_packages

check_openclash_mode
check_acceleration
check_logs
check_bypass_gateway

# Brief pause so diagnostic messages above are readable before the menu renders
if [ "$FW_TYPE" = "fw4" ] || [ -n "$(pgrep -f openclash 2>/dev/null)" ]; then
    echo ""
    sleep 2
fi

while true; do
    leigod_menu
    read choice
    case $choice in
        1)
            install_leigodacc
            ;;
        2)
            uninstall_leigodacc
            ;;
        3)
            reinstall_leigodacc
            ;;
        4)
            service
            ;;
        5)
            switch_mode
            ;;
        6)
            install_compatibility_dependencies
            ;;
        7)
            disabled_ipv6
            ;;
        8)
            install_lean_ipkg_version
            ;;
        9)
            auto_pause_menu
            ;;
        [sS])
            check_service_status
            ;;
        [lL])
            diagnose_latency
            ;;
        [tT])
            apply_network_tuning
            ;;
        [hH])
            help
            ;;
        0)
            exit 0
            ;;
        *)
            echo "[ERROR] 请重新输入对应功能的数字/字母并回车!"
            ;;
    esac
done
