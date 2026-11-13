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
    entry({"admin", "nas", "owntone", "usb_audio_refresh"}, call("action_usb_audio_refresh")).leaf = true
    entry({"admin", "nas", "owntone", "apply_schedule"}, call("action_apply_schedule")).leaf = true
    entry({"admin", "nas", "owntone", "sync_schedule"}, call("action_sync_schedule")).leaf = true
    entry({"admin", "nas", "owntone", "restart_service"}, call("action_restart_service")).leaf = true
    entry({"admin", "nas", "owntone", "player_control"}, call("player_control")).leaf = true
    entry({"admin", "nas", "owntone", "browse_dir"}, call("action_browse_dir")).leaf = true
    entry({"admin", "nas", "owntone", "get_softvol"}, call("action_get_softvol")).leaf = true
    entry({"admin", "nas", "owntone", "set_softvol"}, call("action_set_softvol")).leaf = true
end

-- 读取 OwnTone 日志末尾（和「日志查看」用的是同一份日志）
local function read_owntone_log(n)
    local fs = require "nixio.fs"
    local out = ""
    if fs.access("/var/log/owntone.log") then
        out = luci.sys.exec("tail -n " .. tostring(n) .. " /var/log/owntone.log 2>/dev/null") or ""
    end
    if out == "" then
        out = luci.sys.exec("logread -e owntone 2>/dev/null | tail -n " .. tostring(n)) or ""
    end
    return out
end

-- 取某个报错最后一次出现的时间距今多少秒（用来过滤已经过期的提示）
local function last_event_age(log, needle)
    local pos = nil
    local i = 1
    while true do
        local p = log:find(needle, i, true)
        if not p then break end
        pos = p
        i = p + #needle
    end
    if not pos then return nil end

    local head = log:sub(1, pos)
    local nl = head:match(".*()\n")
    local line_start = nl and (nl + 1) or 1
    local line = log:sub(line_start, pos + #needle)
    local y, mo, d, h, mi, s =
        line:match("(%d%d%d%d)%-(%d%d)%-(%d%d) (%d%d):(%d%d):(%d%d)")
    if not y then return nil end
    local t = os.time({ year = tonumber(y), month = tonumber(mo), day = tonumber(d),
                        hour = tonumber(h), min = tonumber(mi), sec = tonumber(s) })
    return os.time() - t
end

-- 把日志里那些“JSON api request failed with error code 500”翻译成人话
local function build_hints(e, log)
    local hints = {}
    local function add(level, text)
        hints[#hints + 1] = { level = level, text = text }
    end

    if not e.running then
        add("error", "OwnTone 服务没有运行。请到「基本设置」勾选 Enabled 并保存，或重启服务；如果启动后又退出，请看「日志查看」里的提示。")
        return hints
    end

    if not e.api_ok then
        add("warn", "OwnTone 进程在，但 3689 接口没有响应：可能还在启动（等 10 秒刷新看看），或者已经卡住（重启服务）。")
    end

    local lib = e.library or {}
    if (lib.songs or 0) == 0 then
        if lib.updating then
            add("info", "正在扫描音乐库，还没有扫描到歌曲。首次扫描大约需要 1 分钟，扫描完成后才能播放。")
        else
            add("error", "音乐库是空的：一首歌都没有扫描到。请到「基本设置」检查“音乐目录”（当前：" ..
                (e.directories ~= "" and e.directories or "未配置") .. "），确认目录存在后保存并重启服务。")
        end
    end

    if log and log ~= "" then
        local dir = log:match("Skipping library directory%s+([^,%s]+)")
        if dir and (lib.songs or 0) == 0 then
            add("error", "日志里出现「Skipping library directory " .. dir ..
                "」：这个目录不存在或 SD 卡没有挂载，所以一首歌都没导入。")
        end

        local _, db_ok  = log:gsub("Database OK", "")
        local _, db_bad = log:gsub("Database init failed", "")
        local n2 = select(2, log:gsub("incompatible database", ""))
        local n3 = select(2, log:gsub("database disk image is malformed", ""))
        db_bad = db_bad + n2 + n3
        if db_bad > db_ok then
            add("error", "数据库 songs.db 打不开或已损坏。先重启一次服务；仍不行就检查 SD 卡文件系统，或删掉 songs.db 让它重新扫描。")
        end

        local _, busy    = log:gsub("device or resource busy", "")
        local _, nodev   = log:gsub("Could not open audio device", "")
        local age_busy = last_event_age(log, "device or resource busy")
        local age_nodev = last_event_age(log, "Could not open audio device")
        if (busy + nodev > 0) and ((age_busy and age_busy <= 600) or (age_nodev and age_nodev <= 600)) then
            add("warn", "音频设备被占用或没就绪：检查 USB 声卡是否插好，或到「高级设置」点“恢复 USB 声卡”。")
        end

        local age_play = last_event_age(log, "Error starting playback")
        if age_play and age_play <= 600 then
            add("warn", "刚刚有“开始播放失败”的记录。常见原因：播放队列是空的、音乐库还在扫描、或声卡被别的程序占用——不是网络问题。")
        end

        local age_dead = last_event_age(log, "Database deadlocked")
        local age_lock = last_event_age(log, "database table is locked")
        if (age_dead and age_dead <= 600) or (age_lock and age_lock <= 600) then
            add("info", "日志里有数据库写入冲突（扫描和播放同时进行时会出现），属于临时现象，稍等几秒再点播放即可。")
        end
    end

    if #hints == 0 then
        add("ok", "运行正常。")
    end
    return hints
end

function act_status()
    local e = { running = false, state = "unknown", title = "", artist = "", album = "",
                api_ok = false, directories = "",
                library = { songs = 0, updating = false } }
    e.running = luci.sys.call("pgrep owntone >/dev/null") == 0

    local uci = require "luci.model.uci".cursor()
    local port = uci:get("owntone", "owntone", "port") or "3689"
    e.directories = uci:get_first("owntone", "owntone", "directories") or ""

    if e.running then
        local player_json = luci.sys.exec(string.format(
            "curl -s --max-time 2 http://127.0.0.1:%s/api/player 2>/dev/null", port))

        if player_json and #player_json > 0 then
            e.api_ok = true
            local st = player_json:match('"state"%s*:%s*"([^"]+)"')
            if st then e.state = st end
            local item_id = player_json:match('"item_id"%s*:%s*(%d+)')

            if (e.state == "play" or e.state == "pause") and item_id then
                local q_json = luci.sys.exec(string.format(
                    "curl -s --max-time 2 \"http://127.0.0.1:%s/api/queue?id=now_playing\" 2>/dev/null", port))
                if q_json and #q_json > 0 then
                    e.title  = q_json:match('"title"%s*:%s*"([^"]*)"')  or ""
                    e.artist = q_json:match('"artist"%s*:%s*"([^"]*)"') or ""
                    e.album  = q_json:match('"album"%s*:%s*"([^"]*)"')  or ""
                end
            end
        end

        local lib_json = luci.sys.exec(string.format(
            "curl -s --max-time 2 http://127.0.0.1:%s/api/library 2>/dev/null", port))
        if lib_json and #lib_json > 0 then
            e.library.songs = tonumber(lib_json:match('"songs"%s*:%s*(%d+)')) or 0
            e.library.updating = (lib_json:match('"updating"%s*:%s*(%a+)') == "true")
        end
    end

    e.hints = build_hints(e, read_owntone_log(200))

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

-------------------------------------------------------------------------------
-- SOFTVOL（asound.conf 里 softvol 插件创建的软件音量控件）
-------------------------------------------------------------------------------
local function asound_card_num()
    local fs = require "nixio.fs"
    local num = "0"
    if fs.access("/etc/asound.conf") then
        local conf = fs.readfile("/etc/asound.conf") or ""
        local name = conf:match('pcm%s+"hw:([^,]+),')
        if name then
            if name:match("^%d+$") then
                num = name
            else
                local cards = luci.sys.exec("cat /proc/asound/cards 2>/dev/null") or ""
                for n, cname in cards:gmatch("(%d+) %[([^%]]+)%]") do
                    if cname:gsub("%s+$", "") == name then num = n; break end
                end
            end
        end
    end
    return num
end

local function softvol_state()
    local card = asound_card_num()
    local out = luci.sys.exec("amixer -c " .. card .. " sget Softvol 2>/dev/null") or ""
    if not out:match("Softvol") then
        -- softvol 控件要等 softvol 设备被打开一次之后才会出现
        luci.sys.exec("aplay -D softvol /dev/zero -d 1 >/dev/null 2>&1")
        out = luci.sys.exec("amixer -c " .. card .. " sget Softvol 2>/dev/null") or ""
    end
    local vol = out:match("%[(%d+)%%%]")
    return {
        available = (vol ~= nil),
        card = card,
        control = "Softvol",
        volume = tonumber(vol) or 0,
    }
end

function action_get_softvol()
    local st = softvol_state()
    luci.http.prepare_content("application/json")
    luci.http.write_json({
        success   = st.available,
        available = st.available,
        card      = st.card,
        control   = st.control,
        volume    = st.volume,
        error     = (not st.available) and "没有找到 SOFTVOL 控件（声卡可能还没就绪，先播放一次）" or nil,
    })
end

function action_set_softvol()
    local vol = luci.http.formvalue("volume") or ""
    local ok, err = false, nil
    if vol:match("^%d+$") then
        local v = math.max(0, math.min(100, tonumber(vol)))
        local card = asound_card_num()
        local rc = luci.sys.call("amixer -c " .. card .. " sset Softvol " .. tostring(v) .. "% unmute >/dev/null 2>&1")
        ok = (rc == 0)
        if ok then
            -- 同步给 OwnTone 的软件音量，避免它下次把自己的旧音量写回这个控件
            local uci = require "luci.model.uci".cursor()
            local port = uci:get("owntone", "owntone", "port") or "3689"
            luci.sys.exec(string.format(
                "curl -s -o /dev/null -X PUT 'http://127.0.0.1:%s/api/player/volume?volume=%d' 2>/dev/null", port, v))
        else
            err = "设置 SOFTVOL 失败（控件可能不存在，先播放一次再试）"
        end
    else
        err = "音量值无效"
    end
    luci.http.prepare_content("application/json")
    luci.http.write_json({ success = ok, volume = tonumber(vol) or 0, error = err })
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

function action_usb_audio_refresh()
    local sys = require "luci.sys"
    local out = sys.exec("/usr/bin/usb-audio-refresh.sh -r 2>&1") or ""
    local cards = sys.exec("cat /proc/asound/cards 2>/dev/null") or ""
    local pcm = sys.exec("cat /proc/asound/pcm 2>/dev/null") or ""
    luci.http.prepare_content("application/json")
    luci.http.write_json({
        success = (#pcm > 0),
        cards = cards,
        pcm = pcm,
        output = out
    })
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

    -- 队列为空时 owntone 的 /api/player/toggle 会返回 500，
    -- 自动把音乐库加入队列后再重试一次，避免第一次点播放就报错
    if http_code ~= "200" and http_code ~= "204" and action == "toggle" then
        local q = luci.sys.exec(string.format(
            "curl -s --connect-timeout 2 'http://127.0.0.1:%s/api/queue' 2>/dev/null", port))
        if q and q:match('"count"%s*:%s*0') then
            luci.sys.exec(string.format(
                "curl -s -X POST 'http://127.0.0.1:%s/api/queue/items/add?expression=media_kind+is+music&clear=false' >/dev/null 2>&1", port))
            luci.sys.exec("sleep 2")
            http_code = luci.sys.exec(cmd)
            http_code = http_code:gsub("%s+", "")
        end
    end

    if http_code == "200" or http_code == "204" then
        luci.http.prepare_content("application/json")
        luci.http.write_json({ success = true })
    else
        -- 不再直接甩“500”，而是告诉用户实际原因和解法
        local lib = luci.sys.exec(string.format(
            "curl -s --max-time 2 'http://127.0.0.1:%s/api/library' 2>/dev/null", port))
        local songs = tonumber(lib:match('"songs"%s*:%s*(%d+)')) or 0
        local updating = (lib:match('"updating"%s*:%s*(%a+)') == "true")
        local msg
        if songs == 0 and updating then
            msg = "音乐库正在扫描，还没有歌曲。等扫描完成（大约 1 分钟）再点播放。"
        elseif songs == 0 then
            msg = "音乐库是空的，没有可播放的歌曲。请到「基本设置」检查音乐目录是否正确。"
        else
            msg = "OwnTone 没能执行这个操作：播放队列可能是空的，或者音频设备被占用。可以到「日志查看」看具体原因。"
        end
        luci.http.status(500, "API Error")
        luci.http.prepare_content("application/json")
        luci.http.write_json({ success = false, error = msg })
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
