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
