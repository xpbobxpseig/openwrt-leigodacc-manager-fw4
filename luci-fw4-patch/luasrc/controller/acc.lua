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
    -- Record pause timestamp
    local now = os.date("%s")
    util.exec(string.format(
      "echo 'idle_count=0\nlast_pause_epoch=%s' > %s", now, AP_STATE))
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
    for ip, ping_val in raw:gmatch('//[^@]+@([%d.]+):(%d+)"[^}]-"ping":(%d+)') do
      resp.latency.nodes[#resp.latency.nodes + 1] = {
        ip = ip, port = ping_val, ping_ms = tonumber(ping_val) }
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
