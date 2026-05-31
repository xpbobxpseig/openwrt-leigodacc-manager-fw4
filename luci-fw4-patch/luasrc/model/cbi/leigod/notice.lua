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
