module("luci.controller.owntone", package.seeall)

function index()
    if not nixio.fs.access("/etc/config/owntone") then
        return
    end

    entry({"admin", "nas", "owntone"}, cbi("owntone"), _("Music Remote Center")).dependent = true
    entry({"admin", "nas", "owntone", "status"}, call("act_status")).leaf = true
    entry({"admin", "nas", "owntone", "set_volume"}, call("action_set_volume")).leaf = true
    entry({"admin", "nas", "owntone", "get_soundcard_info"}, call("action_get_soundcard_info")).leaf = true
    entry({"admin", "nas", "owntone", "refresh_soundcard"}, call("action_refresh_soundcard")).leaf = true
    entry({"admin", "nas", "owntone", "apply_schedule"}, call("action_apply_schedule")).leaf = true
    entry({"admin", "nas", "owntone", "sync_schedule"}, call("action_sync_schedule")).leaf = true
    entry({"admin", "nas", "owntone", "restart_service"}, call("action_restart_service")).leaf = true
    entry({"admin", "nas", "owntone", "player_control"}, call("player_control")).leaf = true
    entry({"admin", "nas", "owntone", "browse_dir"}, call("action_browse_dir")).leaf = true
end

function act_status()
    local e = { running = false, state = "unknown", title = "", artist = "", album = "" }
    e.running = luci.sys.call("pgrep owntone >/dev/null") == 0

    if e.running then
        local uci = require "luci.model.uci".cursor()
        local port = uci:get("owntone", "owntone", "port") or "3689"
        local player_json = luci.sys.exec(string.format(
            "curl -s --connect-timeout 2 http://127.0.0.1:%s/api/player 2>/dev/null", port))

        if player_json and #player_json > 0 then
            local st = player_json:match('"state"%s*:%s*"([^"]+)"')
            if st then e.state = st end
            local item_id = player_json:match('"item_id"%s*:%s*(%d+)')

            if (e.state == "play" or e.state == "pause") and item_id then
                local q_json = luci.sys.exec(string.format(
                    "curl -s --connect-timeout 2 \"http://127.0.0.1:%s/api/queue?id=now_playing\" 2>/dev/null", port))
                if q_json and #q_json > 0 then
                    e.title  = q_json:match('"title"%s*:%s*"([^"]*)"')  or ""
                    e.artist = q_json:match('"artist"%s*:%s*"([^"]*)"') or ""
                    e.album  = q_json:match('"album"%s*:%s*"([^"]*)"')  or ""
                end
            end
        end
    end

    luci.http.prepare_content("application/json")
    luci.http.write_json(e)
end

local function parse_asound_card()
    local fs = require "nixio.fs"
    if not fs.access("/etc/asound.conf") then return nil end
    local data = fs.readfile("/etc/asound.conf") or ""
    return data:match('pcm%s+"hw:([^,]+),')
end

local function resolve_card(name)
    local sys = require "luci.sys"
    local card_num, card_name, control_name = "0", "Headset", "Headphone"
    local cards = sys.exec("cat /proc/asound/cards 2>/dev/null")

    if name and name ~= "" then
        if name:match("^%d+$") then
            card_num = name
            local _, cname = cards:match("(" .. name .. ") %[([^%]]+)%]")
            if cname then card_name = cname:gsub("%s+$", "") end
        else
            for num, cname in cards:gmatch("(%d+) %[([^%]]+)%]") do
                if cname:gsub("%s+$", "") == name then
                    card_num = num
                    card_name = cname:gsub("%s+$", "")
                    break
                end
            end
        end
    end
    if not card_name or card_name == "" then
        local num, cname = cards:match("(%d+) %[([^%]]+)%]")
        if num then card_num = num; card_name = cname:gsub("%s+$", "") end
    end

    local scontrols = sys.exec("amixer -c " .. card_num .. " scontrols 2>/dev/null")
    if scontrols:match("'Headphone'") then control_name = "Headphone"
    elseif scontrols:match("'Master'") then control_name = "Master"
    elseif scontrols:match("'PCM'") then control_name = "PCM"
    else
        local first = scontrols:match("'([^']+)'")
        if first then control_name = first end
    end
    return card_num, card_name, control_name
end

function action_get_soundcard_info()
    local sys = require "luci.sys"
    local card_name = parse_asound_card()
    local card_num, cname, control = resolve_card(card_name)
    local vol_out = sys.exec("amixer -c " .. card_num .. " sget '" .. control .. "' 2>/dev/null")
    local vol = vol_out:match("%[(%d+)%%%]") or "80"
    luci.http.prepare_content("application/json")
    luci.http.write_json({
        success = true, card = card_num, name = cname,
        control = control, volume = tonumber(vol)
    })
end

function action_set_volume()
    local vol = luci.http.formvalue("volume")
    local card = luci.http.formvalue("card") or "0"
    local control = luci.http.formvalue("control") or "Headphone"
    if vol and vol:match("^%d+$") then
        luci.sys.exec("amixer -c " .. card .. " sset '" .. control .. "' " .. vol .. "% unmute >/dev/null 2>&1")
    end
    luci.http.prepare_content("application/json")
    luci.http.write_json({ success = true })
end

function action_refresh_soundcard()
    local sys = require "luci.sys"
    local fs = require "nixio.fs"

    local cards = sys.exec("cat /proc/asound/cards 2>/dev/null")
    local card_num, card_name = "0", "Headset"
    local num, name = cards:match("(%d+) %[([^%]]+)%]")
    if num then
        card_num = num
        card_name = name:gsub("%s+$", "")
    end

    local control_name = "Headphone"
    local scontrols = sys.exec("amixer -c " .. card_num .. " scontrols 2>/dev/null")
    if scontrols:match("'Headphone'") then control_name = "Headphone"
    elseif scontrols:match("'Master'") then control_name = "Master"
    elseif scontrols:match("'PCM'") then control_name = "PCM"
    else
        local first = scontrols:match("'([^']+)'")
        if first then control_name = first end
    end

    local new_conf = string.format([[
defaults.pcm.dmix.rate 44100
defaults.pcm.dmix.format S16_LE

pcm.!default {
    type plug
    slave.pcm "dmixer"
}

pcm.dmixer {
    type dmix
    ipc_key 1024
    ipc_perm 0666
    slave {
        pcm "hw:%s,0"
        period_time 0
        period_size 1024
        buffer_size 8192
        rate 44100
        format S16_LE
    }
    bindings { 0 0 1 1 }
}
ctl.dmixer {
    type hw
    card %s
}

pcm.softvol {
    type softvol
    slave.pcm "plug:dmixer"
    control {
        name "Softvol"
        card %s
    }
}
]], card_name, card_name, card_name)

    fs.writefile("/etc/asound.conf", new_conf)

    sys.exec("aplay -D softvol /dev/zero -d 1 >/dev/null 2>&1")
    sys.exec("/etc/init.d/owntone restart >/dev/null 2>&1")
    sys.exec("/etc/init.d/shairport-sync restart >/dev/null 2>&1")
    sys.exec("/etc/init.d/gmediarender restart >/dev/null 2>&1")

    local vol_out = sys.exec("amixer -c " .. card_num .. " sget '" .. control_name .. "' 2>/dev/null")
    local vol = vol_out:match("%[(%d+)%%%]") or "0"

    luci.http.prepare_content("application/json")
    luci.http.write_json({
        success = true, card = card_num, name = card_name,
        control = control_name, volume = tonumber(vol)
    })
end

function action_restart_service()
    luci.sys.call("/etc/init.d/owntone restart >/dev/null 2>&1")
    luci.http.prepare_content("application/json")
    luci.http.write_json({ success = true })
end

-- 应用定时音量计划（写 UCI + crontab，带 # owntone-vol-N 标识）
function action_apply_schedule()
    local uci = require "luci.model.uci".cursor()
    local sys = require "luci.sys"
    local fs = require "nixio.fs"

    local params = {}
    for i = 1, 4 do
        params["enable_time" .. i] = luci.http.formvalue("enable_time" .. i) or "0"
        params["time" .. i]        = luci.http.formvalue("time" .. i) or ""
        params["target" .. i]      = luci.http.formvalue("target" .. i) or "softvol"
        params["volume" .. i]      = luci.http.formvalue("volume" .. i) or ""
    end

    for k, v in pairs(params) do
        uci:set("owntone", "owntone", k, v)
    end
    uci:commit("owntone")

    local card_num, control_name = "0", "Headphone"
    if fs.access("/etc/asound.conf") then
        local conf = fs.readfile("/etc/asound.conf") or ""
        local name = conf:match('pcm%s+"hw:([^,]+),')
        if name then
            if name:match("^%d+$") then
                card_num = name
            else
                local cards = sys.exec("cat /proc/asound/cards 2>/dev/null")
                for num, cname in cards:gmatch("(%d+) %[([^%]]+)%]") do
                    if cname:gsub("%s+$", "") == name then
                        card_num = num
                        break
                    end
                end
            end
        end
    end
    local scontrols = sys.exec("amixer -c " .. card_num .. " scontrols 2>/dev/null")
    if scontrols:match("'Headphone'") then control_name = "Headphone"
    elseif scontrols:match("'Master'") then control_name = "Master"
    elseif scontrols:match("'PCM'") then control_name = "PCM"
    else
        local first = scontrols:match("'([^']+)'")
        if first then control_name = first end
    end

    local new_lines = {}
    for i = 1, 4 do
        if params["enable_time" .. i] == "1" then
            local t = params["time" .. i]
            local v = params["volume" .. i]
            local target = params["target" .. i]
            if t ~= "" and v:match("^%d+$") and tonumber(v) <= 100 then
                v = tostring(tonumber(v))
                local hh, mm = t:match("^(%d?%d):(%d%d)$")
                if hh and mm then
                    if target == "hw" then
                        table.insert(new_lines, string.format(
                            "%d %d * * * amixer -c %s sset '%s' %s%% unmute >/dev/null 2>&1 # owntone-vol-%d",
                            tonumber(mm), tonumber(hh), card_num, control_name, v, i))
                    else
                        table.insert(new_lines, string.format(
                            "%d %d * * * curl -s -X PUT 'http://127.0.0.1:3689/api/player/volume?volume=%s' >/dev/null 2>&1 # owntone-vol-%d",
                            tonumber(mm), tonumber(hh), v, i))
                    end
                end
            end
        end
    end

    local crontab = "/etc/crontabs/root"
    local kept = {}
    local f = io.open(crontab, "r")
    if f then
        for line in f:lines() do
            if not line:match("# owntone%-vol%-%d") then
                table.insert(kept, line)
            end
        end
        f:close()
    end
    for _, l in ipairs(new_lines) do table.insert(kept, l) end
    f = io.open(crontab, "w")
    if f then
        f:write(table.concat(kept, "\n") .. "\n")
        f:close()
    end
    sys.call("/etc/init.d/cron restart >/dev/null 2>&1")

    luci.http.prepare_content("application/json")
    luci.http.write_json({ success = true, count = #new_lines })
end

-- 从 crontab 反向解析定时任务，返回给前端回填显示
function action_sync_schedule()
    local fs = require "nixio.fs"

    local result = {}
    for i = 1, 4 do
        result[i] = { enable = "0", time = "", target = "softvol", volume = "" }
    end

    if fs.access("/etc/crontabs/root") then
        local data = fs.readfile("/etc/crontabs/root") or ""
        for line in data:gmatch("[^\r\n]+") do
            local idx = line:match("# owntone%-vol%-(%d)")
            if idx then
                idx = tonumber(idx)
                if idx and idx >= 1 and idx <= 4 then
                    local mm = line:match("^(%d+)%s+%d+%s")
                    local hh = line:match("^%d+%s+(%d+)%s")
                    local vol = line:match("volume=(%d+)") or line:match("%s(%d+)%%%s+unmute")
                    local target = line:match("amixer") and "hw" or "softvol"
                    if mm and hh and vol then
                        result[idx].enable = "1"
                        result[idx].time   = string.format("%02d:%02d", tonumber(hh), tonumber(mm))
                        result[idx].target = target
                        result[idx].volume = vol
                    end
                end
            end
        end
    end

    luci.http.prepare_content("application/json")
    luci.http.write_json({ success = true, tasks = result })
end

-- ==================== 播放控制 ====================
function player_control()
    local action = luci.http.formvalue("action")
    if not action then
        luci.http.status(400, "Bad Request")
        luci.http.prepare_content("application/json")
        luci.http.write_json({ success = false, error = "缺少 action 参数" })
        return
    end

    local running = luci.sys.call("pgrep owntone >/dev/null") == 0
    if not running then
        luci.http.status(500, "Not Running")
        luci.http.prepare_content("application/json")
        luci.http.write_json({ success = false, error = "OwnTone 服务未运行，请等待服务启动或手动重启服务！" })
        return
    end

    local uci = require("luci.model.uci").cursor()
    local port = uci:get("owntone", "owntone", "port") or "3689"

    local api_path = ""
    if action == "next" then api_path = "next"
    elseif action == "previous" then api_path = "previous"
    elseif action == "toggle" then api_path = "toggle"
    else
        luci.http.status(400, "Invalid action")
        luci.http.prepare_content("application/json")
        luci.http.write_json({ success = false, error = "无效的 action: " .. action })
        return
    end

    local cmd = string.format("curl -s -o /dev/null -w '%%{http_code}' -X PUT http://127.0.0.1:%s/api/player/%s", port, api_path)
    local http_code = luci.sys.exec(cmd)
    http_code = http_code:gsub("%s+", "")

    if http_code == "200" or http_code == "204" then
        luci.http.prepare_content("application/json")
        luci.http.write_json({ success = true })
    else
        luci.http.status(500, "API Error")
        luci.http.prepare_content("application/json")
        luci.http.write_json({ success = false, error = "OwnTone API 返回状态码: " .. (http_code or "空") })
    end
end

-- ==================== 目录浏览（供"选择目录"弹窗使用） ====================
function action_browse_dir()
    local sys = require "luci.sys"
    local path = luci.http.formvalue("path") or "/mnt"

    -- 规范化
    if path == "" or path == "/" or path == "/mnt/" then path = "/mnt" end
    path = path:gsub("/+$", "")
    if path == "" then path = "/mnt" end

    -- 限制在 /mnt 下
    if not path:match("^/mnt") then
        path = "/mnt"
    end

    -- 转义单引号，避免 shell 注入
    local safe_path = path:gsub("'", "'\\''")

    local dirs = {}
    local cmd = string.format(
        "find '%s' -mindepth 1 -maxdepth 1 -type d 2>/dev/null", safe_path)
    local out = sys.exec(cmd) or ""

    for line in out:gmatch("[^\r\n]+") do
        local name = line:match("([^/]+)$")
        if name and name ~= "" and not name:match("^%.") then
            table.insert(dirs, name)
        end
    end
    table.sort(dirs)

    -- 上级目录
    local parent = nil
    if path ~= "/mnt" then
        parent = path:match("^(.*)/[^/]+$")
        if not parent or not parent:match("^/mnt") then
            parent = "/mnt"
        end
    end

    luci.http.prepare_content("application/json")
    luci.http.write_json({
        success = true,
        path    = path,
        parent  = parent,
        dirs    = dirs
    })
end
