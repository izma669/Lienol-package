module("luci.controller.vhusbd", package.seeall)

local uci = require "luci.model.uci".cursor()
local fs  = require "nixio.fs"

local PORT   = "7575"
local CONFIG = "vhusbd"
local CTYPE  = "vhusbd"

function index()
	entry({"admin", "services", "vhusbd"}, template("vhusbd/status"), _("VirtualHere"), 60)
	entry({"admin", "services", "vhusbd", "action"}, call("action_dispatch")).leaf = true
end

-- ---------------------------------------------------------------------------
-- UCI helpers
-- ---------------------------------------------------------------------------

local function uci_section()
	local s = uci:get_first(CONFIG, CTYPE)
	if s then
		return s
	end

	s = uci:section(CONFIG, CTYPE, nil, {})
	if s then
		uci:commit(CONFIG)
	end
	return s
end

local function uci_get(opt)
	local s = uci:get_first(CONFIG, CTYPE)
	if not s then
		return nil
	end
	return uci:get(CONFIG, s, opt)
end

local function uci_set(opt, val)
	local s = uci_section()
	if not s then
		return false
	end
	uci:set(CONFIG, s, opt, val)
	return uci:commit(CONFIG) and true or false
end

-- Returns a string, never nil/false, so callers can compare safely.
local function opt(name, default)
	local v = uci_get(name)
	if v == nil or v == false or v == "" then
		return default
	end
	return tostring(v)
end

-- Missing option means enabled, for compatibility with old installations.
local function is_enabled()
	local v = opt("enabled", "1"):lower()
	return not (v == "0" or v == "no" or v == "false" or v == "off" or v == "disabled")
end

-- Cut a UTF-8 string to at most n characters, never in the middle of a
-- multi-byte sequence (server names are often Chinese).
local function utf8_sub(s, n)
	local i, count = 1, 0
	while i <= #s and count < n do
		local c = s:byte(i)
		if c >= 0xF0 then
			i = i + 4
		elseif c >= 0xE0 then
			i = i + 3
		elseif c >= 0xC0 then
			i = i + 2
		else
			i = i + 1
		end
		count = count + 1
	end
	return s:sub(1, i - 1)
end

-- ---------------------------------------------------------------------------
-- Service / firewall helpers
-- ---------------------------------------------------------------------------

local function service_running()
	-- pidof matches the process name only, so helper shells containing
	-- "/etc/init.d/vhusbd" in their command line are not mistaken for the server.
	local rc = luci.sys.call("pidof vhusbd >/dev/null 2>&1")
	if rc == 0 then
		return true
	end
	if rc ~= 127 then
		return false
	end

	-- pidof is not available (unusual BusyBox build): fall back to ps.
	local n = luci.sys.exec("ps | grep '[v]husbd' | grep -v 'Z' | wc -l")
	return (tonumber((n:gsub("%s+", ""))) or 0) > 0
end

-- Any /etc/rc.d/S??vhusbd link (START may be 95 or 99 in older installs).
local function autostart_linked()
	for f in fs.glob("/etc/rc.d/S??vhusbd") do
		if fs.access(f) then
			return true
		end
	end
	return false
end

local function run_init(action)
	return luci.sys.call("/etc/init.d/vhusbd " .. action .. " >/dev/null 2>&1") == 0
end

local function wait_running(want, tries)
	tries = tries or 5
	local i
	for i = 1, tries do
		if service_running() == want then
			return true
		end
		if i < tries then
			luci.sys.exec("sleep 1")
		end
	end
	return service_running() == want
end

local function fw_off()
	luci.sys.exec("i=0; while [ $i -lt 10 ] && iptables -C INPUT -p tcp --dport " .. PORT .. " -j ACCEPT >/dev/null 2>&1; do iptables -D INPUT -p tcp --dport " .. PORT .. " -j ACCEPT >/dev/null 2>&1 || break; i=$((i+1)); done")
	luci.sys.exec("i=0; while [ $i -lt 10 ] && ip6tables -C INPUT -p tcp --dport " .. PORT .. " -j ACCEPT >/dev/null 2>&1; do ip6tables -D INPUT -p tcp --dport " .. PORT .. " -j ACCEPT >/dev/null 2>&1 || break; i=$((i+1)); done")
end

local function fw_apply()
	fw_off()
	if opt("ExtAccess", "0") == "1" then
		luci.sys.exec("iptables -I INPUT -p tcp --dport " .. PORT .. " -j ACCEPT >/dev/null 2>&1")
	end
	if opt("IPv6Access", "0") == "1" then
		luci.sys.exec("ip6tables -I INPUT -p tcp --dport " .. PORT .. " -j ACCEPT >/dev/null 2>&1")
	end
end

-- ---------------------------------------------------------------------------
-- Actions
-- ---------------------------------------------------------------------------

function action_dispatch()
	local action = luci.http.formvalue("action") or ""
	local out = "ERROR:未知操作"

	if action == "status" then
		out = service_running() and "RUNNING" or "STOPPED"

	elseif action == "get_enabled" then
		out = "ENABLED:" .. (is_enabled() and "1" or "0")

	elseif action == "get_state" then
		-- STATE:<running>,<enabled>,<autostart-link>
		out = "STATE:"
			.. (service_running() and "1" or "0") .. ","
			.. (is_enabled() and "1" or "0") .. ","
			.. (autostart_linked() and "1" or "0")

	elseif action == "enable" then
		if not uci_set("enabled", "1") then
			out = "ERROR:保存设置失败，请检查 /etc/config/vhusbd 是否可写"
		else
			if not autostart_linked() then
				run_init("enable")
			end
			run_init("start")

			if wait_running(true, 5) then
				if autostart_linked() then
					out = "SUCCESS:服务已启用并启动，以后开机会自动启动"
				else
					out = "SUCCESS:服务已启动，但开机自启链接创建失败，请检查 /etc/rc.d 权限"
				end
			else
				out = "ERROR:设置已保存，但服务未能启动，请点“查看日志”排查"
			end
		end

	elseif action == "disable" then
		if not uci_set("enabled", "0") then
			out = "ERROR:保存设置失败，请检查 /etc/config/vhusbd 是否可写"
		else
			run_init("stop")
			run_init("disable")
			fw_off()

			if not wait_running(false, 5) then
				out = "ERROR:设置已保存，但服务进程未能停止，请点“查看日志”排查"
			elseif autostart_linked() then
				out = "SUCCESS:服务已停用并停止，但开机启动项移除失败；init 脚本仍会在启动时拒绝运行"
			else
				out = "SUCCESS:服务已停用并停止，以后开机不会再自动启动"
			end
		end

	elseif action == "start" then
		if not is_enabled() then
			out = "ERROR:服务当前是停用状态，请先打开上面的“启用服务”开关"
		elseif service_running() then
			out = "SUCCESS:服务已经在运行"
		else
			if not autostart_linked() then
				run_init("enable")
			end
			run_init("start")

			if wait_running(true, 5) then
				out = "SUCCESS:服务已启动"
			else
				out = "ERROR:服务未能启动，请点“查看日志”排查"
			end
		end

	elseif action == "stop" then
		run_init("stop")
		fw_off()

		if not wait_running(false, 5) then
			out = "ERROR:服务进程未能停止，请点“查看日志”排查"
		elseif is_enabled() then
			out = "SUCCESS:服务已停止；开机自启仍为开启，重启后会自动启动。要永久停止，请关闭上方开关"
		else
			out = "SUCCESS:服务已停止（开机自启为关闭状态）"
		end

	elseif action == "restart" then
		if not is_enabled() then
			out = "ERROR:服务当前是停用状态，请先打开上面的“启用服务”开关"
		else
			if not autostart_linked() then
				run_init("enable")
			end
			run_init("restart")
			if wait_running(true, 5) then
				out = "SUCCESS:服务已重启"
			else
				out = "ERROR:服务重启后未能运行，请点“查看日志”排查"
			end
		end

	elseif action == "get_name" then
		local filepath = "/usr/bin/config.ini"
		if fs.access(filepath) then
			local content = fs.readfile(filepath) or ""
			local name = content:match("ServerName=([^\r\n]*)")
			out = "NAME:" .. (name or "")
		else
			out = "NAME:"
		end

	elseif action == "rename" then
		local name = luci.http.formvalue("name")
		if type(name) ~= "string" or name == "" then
			out = "ERROR:名称不能为空"
		else
			name = utf8_sub(name:gsub("%c", ""), 64)
			local filepath = "/usr/bin/config.ini"

			if not fs.access(filepath) then
				out = "ERROR:配置文件 " .. filepath .. " 不存在"
			else
				local content = fs.readfile(filepath) or ""
				if content:match("ServerName=") then
					content = content:gsub("ServerName=[^\r\n]*", function()
						return "ServerName=" .. name
					end)
				else
					content = content .. "\nServerName=" .. name
				end

				if not fs.writefile(filepath, content) then
					out = "ERROR:写入 " .. filepath .. " 失败"
				elseif is_enabled() and service_running() then
					run_init("restart")
					if wait_running(true, 5) then
						out = "SUCCESS:服务器已重命名为 " .. name .. " 并已重启"
					else
						out = "ERROR:名称已保存，但服务重启后未能运行，请查看日志"
					end
				elseif is_enabled() then
					out = "SUCCESS:服务器已重命名为 " .. name .. "；服务当前未运行，下次启动时生效"
				else
					out = "SUCCESS:服务器已重命名为 " .. name .. "；服务未启用，未重启"
				end
			end
		end

	elseif action == "register" then
		local ifname = luci.sys.exec("uci -q get network.lan.device 2>/dev/null"):gsub("%s+", "")
		if ifname == "" then
			ifname = luci.sys.exec("uci -q get network.lan.ifname 2>/dev/null"):gsub("%s+", "")
		end
		if ifname == "" then
			ifname = "br-lan"
		end

		local mac = luci.sys.exec("cat /sys/class/net/" .. ifname .. "/address 2>/dev/null"):gsub("[:\n%s]", ""):lower()
		if #mac ~= 12 then
			mac = luci.sys.exec("cat /sys/class/net/eth0/address 2>/dev/null"):gsub("[:\n%s]", ""):lower()
		end

		if #mac ~= 12 then
			out = "ERROR:无法获取有效 MAC 地址"
		elseif not fs.access("/usr/bin/config.ini") then
			out = "ERROR:配置文件 /usr/bin/config.ini 不存在"
		else
			local filepath = "/usr/bin/config.ini"
			luci.sys.exec(string.format("sed -i 's/^License=.\\{12\\},/License=%s,/' %s", mac, filepath))
			local after = fs.readfile(filepath) or ""

			if after:find("License=" .. mac .. ",", 1, true) then
				out = "SUCCESS:注册成功，序列号: " .. mac
			else
				out = "ERROR:未找到可替换的 License 行，请检查 " .. filepath
			end
		end

	elseif action == "get_prefs" then
		out = "PREFS:" .. opt("ExtAccess", "0") .. "," .. opt("IPv6Access", "0") .. "," .. (is_enabled() and "1" or "0")

	elseif action == "get_fw" then
		local wan_on = luci.sys.call("iptables -C INPUT -p tcp --dport " .. PORT .. " -j ACCEPT >/dev/null 2>&1") == 0
		local ipv6_on = luci.sys.call("ip6tables -C INPUT -p tcp --dport " .. PORT .. " -j ACCEPT >/dev/null 2>&1") == 0
		out = "FW:" .. (wan_on and "1" or "0") .. "," .. (ipv6_on and "1" or "0")

	elseif action == "set_fw" then
		local fw_type = luci.http.formvalue("type")
		local fw_val = (luci.http.formvalue("val") == "1") and "1" or "0"

		if fw_type ~= "wan" and fw_type ~= "ipv6" then
			out = "ERROR:未知的网络类型"
		else
			local name = (fw_type == "wan") and "ExtAccess" or "IPv6Access"
			if not uci_set(name, fw_val) then
				out = "ERROR:保存设置失败，请检查 /etc/config/vhusbd 是否可写"
			elseif is_enabled() then
				fw_apply()
				if fw_type == "wan" then
					out = (fw_val == "1") and "SUCCESS:外网访问已开启并保存" or "SUCCESS:外网访问已关闭并保存"
				else
					out = (fw_val == "1") and "SUCCESS:IPv6 访问已开启并保存" or "SUCCESS:IPv6 访问已关闭并保存"
				end
			else
				fw_off()
				out = "SUCCESS:偏好已保存；服务当前已停用，网络访问会在启用服务后自动生效"
			end
		end

	elseif action == "logs" then
		out = luci.sys.exec("logread 2>/dev/null | grep -i vhusbd | tail -n 50")
		if out == "" then
			out = "暂无日志信息"
		end
	end

	luci.http.prepare_content("text/plain")
	luci.http.write(out)
end
