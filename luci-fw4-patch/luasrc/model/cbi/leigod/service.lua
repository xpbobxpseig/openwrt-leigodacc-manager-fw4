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
