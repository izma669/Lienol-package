module("luci.controller.gmediarender", package.seeall)

function index()
    if not nixio.fs.access("/etc/config/gmediarender") then return end
    entry({"admin", "services", "gmediarender"}, cbi("gmediarender"), _("GMediaRender"), 60).dependent = true
    entry({"admin", "services", "gmediarender", "status"}, call("action_status")).leaf = true
    entry({"admin", "services", "gmediarender", "nowplaying"}, call("action_nowplaying")).leaf = true
    entry({"admin", "services", "gmediarender", "control"}, call("action_control")).leaf = true
    entry({"admin", "services", "gmediarender", "download"}, call("action_download")).leaf = true
    entry({"admin", "services", "gmediarender", "download_log"}, call("action_download_log")).leaf = true
    -- 新增浏览目录接口
    entry({"admin", "services", "gmediarender", "browse"}, call("action_browse")).leaf = true
end

function action_browse()
    local http = require "luci.http"
    local fs = require "nixio.fs"
    local path = http.formvalue("path") or "/mnt"
    if not path:match("^/mnt") then path = "/mnt" end
    if not path:match("/$") then path = path .. "/" end
    
    local dirs = {}
    if fs.access(path) then
        for name in fs.dir(path) do
            if name ~= "." and name ~= ".." then
                local fpath = path .. name
                if fs.stat(fpath, "type") == "dir" then
                    table.insert(dirs, name)
                end
            end
        end
    end
    table.sort(dirs)
    
    http.prepare_content("application/json")
    http.write_json(dirs)
end

function action_status()
    local sys = require "luci.sys"
    local uci = require "luci.model.uci".cursor()
    local running = sys.call("pidof gmediarender >/dev/null") == 0
    local enabled = uci:get("gmediarender", "main", "enabled")
    luci.http.prepare_content("application/json")
    luci.http.write_json({ running = running, enabled = enabled == "1" })
end

function action_download_log()
    local fs = require "nixio.fs"
    local logfile = "/tmp/gmediarender_dl.log"
    local data = ""
    if fs.access(logfile) then
        data = fs.readfile(logfile) or ""
        if #data > 3000 then data = data:sub(-3000) end
        data = data:gsub("\\(%d%d%d)", function(oct) return string.char(tonumber(oct, 8)) end)
    end
    luci.http.prepare_content("application/json")
    luci.http.write_json({ log = data })
end

local function trigger_download(url, title, artist)
    local uci = require "luci.model.uci".cursor()
    local sys = require "luci.sys"
    local fs = require "nixio.fs"
    
    -- 【修复 403】解决 XML 转义导致的 URL 问题
    url = url:gsub("&amp;", "&")
    
    local tool = nil
    if sys.call("which wget >/dev/null 2>&1") == 0 then tool = "wget"
    elseif sys.call("which uclient-fetch >/dev/null 2>&1") == 0 then tool = "uclient-fetch" end
    if not tool then return false, "无下载工具" end
    
    local dir = uci:get("gmediarender", "main", "download_dir")
    if not dir or dir == "" then return false, "下载路径未配置，已取消下载" end
    -- 【防爆盘保护】强制必须在 /mnt 下，且必须已存在
    if not dir:match("^/mnt") then return false, "安全限制：下载目录必须在 /mnt 下，已取消。" end
    if not fs.access(dir) then return false, "目录不存在，已取消下载。请手动创建或重新选择：" .. dir end
    
    local function sanitize(s)
        if not s then return "" end
        s = s:gsub("[\\/:*?\"<>|]", "_")
        return s:gsub("^%s+", ""):gsub("%s+$", "")
    end
    
    local safe_title = sanitize(title)
    local safe_artist = sanitize(artist)
    if safe_title == "暂无播放" or safe_title == "空闲" then safe_title = "" end
    if safe_artist == "-" or safe_artist == "未知艺术家" then safe_artist = "" end
    
    local filename = ""
    if safe_title ~= "" and safe_artist ~= "" then filename = safe_title .. "-" .. safe_artist
    elseif safe_title ~= "" then filename = safe_title
    else filename = url:match("([^/]+)$") or "download_song" end
    
    local ext = url:gsub("%?.*$", ""):match("%.([%a%d]+)$")
    if not ext or #ext > 4 then ext = "mp3" end
    if not filename:match("%.%w+$") then filename = filename .. "." .. ext end
    
    local filepath = dir .. "/" .. filename
    local logfile = "/tmp/gmediarender_dl.log"
    sys.call("echo '开始下载...' > " .. logfile)
    
    local safe_filepath = "'" .. filepath:gsub("'", "'\\''") .. "'"
    local safe_url = "'" .. url:gsub("'", "'\\''") .. "'"
    local safe_logfile = "'" .. logfile:gsub("'", "'\\''") .. "'"
    
    local cmd = ""
    if tool == "wget" then
        cmd = string.format("( env LANG=C.UTF-8 LC_ALL=C.UTF-8 wget -O %s %s >> %s 2>&1 & )", safe_filepath, safe_url, safe_logfile)
    else
        cmd = string.format("( env LANG=C.UTF-8 LC_ALL=C.UTF-8 uclient-fetch -O %s %s >> %s 2>&1 & )", safe_filepath, safe_url, safe_logfile)
    end
    sys.call(cmd)
    return true, "已开始后台下载:\n" .. filename
end

function action_download()
    local http = require "luci.http"
    local url = http.formvalue("url")
    local title = http.formvalue("title") or ""
    local artist = http.formvalue("artist") or ""
    if not url or url == "" or not url:match("^https?://") then
        http.prepare_content("application/json"); http.write_json({success = false, msg = "无效链接"}); return
    end
    local ok, msg = trigger_download(url, title, artist)
    http.prepare_content("application/json"); http.write_json({success = ok, msg = msg})
end

local function get_host_ip()
    local uci = require "luci.model.uci".cursor()
    local ip = uci:get("network", "lan", "ipaddr")
    if not ip or ip == "" then ip = "127.0.0.1" end
    return ip
end

local function upnp_request(host, port, action, body_inner)
    local nixio = require "nixio"
    local service_type = "urn:schemas-upnp-org:service:AVTransport:1"
    local control_url = "/upnp/control/rendertransport1"
    
    if action == "GetVolume" or action == "SetVolume" then
        service_type = "urn:schemas-upnp-org:service:RenderingControl:1"
        control_url = "/upnp/control/rendercontrol1"
    end
    
    local soap_body = string.format([[
<?xml version="1.0" encoding="utf-8"?>
<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
  <s:Body><u:%s xmlns:u="%s">%s</u:%s></s:Body>
</s:Envelope>]], action, service_type, body_inner, action)

    local http_req = string.format(
        "POST %s HTTP/1.1\r\n" ..
        "Host: %s:%d\r\n" ..
        "Content-Type: text/xml; charset=\"utf-8\"\r\n" ..
        "SOAPAction: \"%s#%s\"\r\n" ..
        "Content-Length: %d\r\n" ..
        "Connection: close\r\n\r\n%s",
        control_url, host, port, service_type, action, #soap_body, soap_body
    )

    local sock = nixio.socket("inet", "stream")
    pcall(function() sock:setopt("socket", "rcvtimeo", 1000) end)
    pcall(function() sock:setopt("socket", "sndtimeo", 1000) end)
    
    if not sock:connect(host, port) then sock:close() return nil end
    if not sock:send(http_req) then sock:close() return nil end
    
    local response = ""
    while true do
        local data = sock:recv(4096)
        if not data then break end
        response = response .. data
        if response:find("</s:Envelope>") then break end
    end
    sock:close()
    
    if response == "" then return nil end
    return response
end

function action_control()
    local http = require "luci.http"
    local uci = require "luci.model.uci".cursor()
    local host = get_host_ip()
    local port = tonumber(uci:get("gmediarender", "main", "port")) or 49152
    
    local act = http.formvalue("action")
    local val = http.formvalue("value")
    local instance = "<InstanceID>0</InstanceID>"
    local res = nil
    
    if act == "play" then
        res = upnp_request(host, port, "Play", instance .. "<Speed>1</Speed>")
    elseif act == "pause" then
        res = upnp_request(host, port, "Pause", instance)
    elseif act == "stop" then
        res = upnp_request(host, port, "Stop", instance)
    elseif act == "next" then
        res = upnp_request(host, port, "Next", instance)
    elseif act == "previous" then
        res = upnp_request(host, port, "Previous", instance)
    elseif act == "seek" and val then
        res = upnp_request(host, port, "Seek", instance .. "<Unit>REL_TIME</Unit><Target>" .. val .. "</Target>")
    elseif act == "volume" and val then
        local v_num = tonumber(val) or 0
        res = upnp_request(host, port, "SetVolume", instance .. "<Channel>Master</Channel><DesiredVolume>" .. v_num .. "</DesiredVolume>")
    end
    
    http.prepare_content("application/json")
    http.write_json({ success = (res ~= nil) })
end

function action_nowplaying()
    local uci = require "luci.model.uci".cursor()
    local fs  = require "nixio.fs"
    
    local info = {
        playing=false, position="", duration="", title="", artist="", album="", albumart="",
        streamurl="", format="", quality="", volume="0", mediatype="", debug="", soundcard="",
        auto_download_triggered=false
    }

    local host = get_host_ip()
    local port = tonumber(uci:get("gmediarender", "main", "port")) or 49152
    local instance = "<InstanceID>0</InstanceID>"

    local pos_resp = upnp_request(host, port, "GetPositionInfo", instance)
    if pos_resp then
        info.position = pos_resp:match("<RelTime>([^<]+)</RelTime>") or pos_resp:match("<[^>]*RelTime[^>]*>([^<]+)</[^>]*RelTime>") or ""
        info.duration = pos_resp:match("<TrackDuration>([^<]+)</TrackDuration>") or pos_resp:match("<[^>]*TrackDuration[^>]*>([^<]+)</[^>]*TrackDuration>") or ""
        
        local meta = pos_resp:match("<TrackMetaData>([^<]+)</TrackMetaData>") or pos_resp:match("<[^>]*TrackMetaData[^>]*>([^<]+)</[^>]*TrackMetaData>")
        if meta and meta ~= "" then
            meta = meta:gsub("&lt;","<"):gsub("&gt;",">"):gsub("&quot;",'"'):gsub("&apos;","'"):gsub("&amp;","&")
            
            info.title    = meta:match("<dc:title>([^<]+)</dc:title>") or ""
            info.artist   = meta:match("<upnp:artist>([^<]+)</upnp:artist>") or ""
            info.album    = meta:match("<upnp:album>([^<]+)</upnp:album>") or ""
            info.albumart = meta:match("<upnp:albumArtURI>([^<]+)</upnp:albumArtURI>") or ""
            if info.albumart ~= "" and not info.albumart:match("^https?://") then info.albumart = "" end
            
            info.streamurl = meta:match("<res[^>]*>([^<]+)</res>") or ""
            if info.streamurl == "" then info.streamurl = pos_resp:match("<TrackURI>([^<]+)</TrackURI>") or "" end

            local cls = meta:match("<upnp:class>([^<]+)</upnp:class>")
            if cls then
                if cls:match("musicTrack") then info.mediatype = "歌曲"
                elseif cls:match("audioBroadcast") then info.mediatype = "电台"
                elseif cls:match("audioItem") then info.mediatype = "音频" end
            end
            
            local mime = meta:match("protocolInfo=\"[^\"]*:(audio/[^:;]+)")
            if mime then
                if mime:match("mpeg") then info.format = "MP3"
                elseif mime:match("flac") then info.format = "FLAC"
                elseif mime:match("mp4") or mime:match("m4a") then info.format = "M4A/AAC"
                elseif mime:match("wav") then info.format = "WAV"
                elseif mime:match("ogg") then info.format = "OGG"
                elseif mime:match("opus") then info.format = "OPUS"
                else info.format = mime end
            end
        end
    end

    local trans_resp = upnp_request(host, port, "GetTransportInfo", instance)
    if trans_resp then
        local state = trans_resp:match("<CurrentTransportState>([^<]+)</CurrentTransportState>")
        if state == "PLAYING" then info.playing = true end
    end

    local vol_resp = upnp_request(host, port, "GetVolume", instance .. "<Channel>Master</Channel>")
    if vol_resp then
        local vol = vol_resp:match("<CurrentVolume>([^<]+)</CurrentVolume>")
        if vol then info.volume = vol end
    end

    local sys = require "luci.sys"
    local ps_out = sys.exec("ps w | grep gmediarender | grep -v grep")
    local out_arg = ps_out:match("%-o%s+([%w:%,%-]+)") or ps_out:match("%-d%s+([%w:%,%-]+)")
    local soundcard = out_arg
    if not soundcard or soundcard == "" then
        local proc_cards = sys.exec("cat /proc/asound/cards 2>/dev/null")
        if proc_cards and proc_cards ~= "" then
            local card_num, card_name = proc_cards:match("(%d+) %[.-%]:.-%-%s+([^\n]+)")
            if card_num and card_name then soundcard = "hw:" .. card_num .. " (" .. card_name .. ")" end
        end
    end
    if not soundcard or soundcard == "" then soundcard = "-" end
    info.soundcard = soundcard:gsub("%s+", " ")

    local auto_dl = uci:get("gmediarender", "main", "auto_download")
    if auto_dl == "1" then
        if info.playing and info.streamurl and info.streamurl:match("^https?://") then
            local last_dl_file = "/tmp/gmediarender_last_dl.txt"
            local last_url = ""
            if fs.access(last_dl_file) then last_url = fs.readfile(last_dl_file) or "" end
            last_url = last_url:gsub("%s+$", "")
            
            if info.streamurl ~= last_url then
                fs.writefile(last_dl_file, info.streamurl)
                local ok, msg = trigger_download(info.streamurl, info.title, info.artist)
                if ok then info.auto_download_triggered = true end
            end
        end
    end

    luci.http.prepare_content("application/json")
    luci.http.write_json(info)
end
