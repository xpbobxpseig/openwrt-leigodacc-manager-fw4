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
