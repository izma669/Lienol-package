-- Copyright 2020 Lean <coolsnowwolf@gmail.com>
-- Licensed to the public under the Apache License 2.0.

local sys = require "luci.sys"

m = Map("owntone")
m.title = translate("Music Remote Center")
m.description = translate("Music Remote Center is a DAAP (iTunes Remote), MPD (Music Player Daemon) and RSP (Roku) media server.")

-- 1. 正在播放状态框
m:section(SimpleSection).template = "owntone/owntone_status"

-- ==================== 标签页定义 ====================
s = m:section(TypedSection, "owntone")
s.addremove = false
s.anonymous = true

s:tab("playback", translate("播放控制选项"))
s:tab("schedule", translate("定时控制音量"))
s:tab("basic", translate("基本设置"))
s:tab("advanced", translate("高级设置"))
s:tab("logs",     translate("日志查看"))

-- ==================== 播放控制选项 ====================
local snd_vol = s:taboption("playback", DummyValue, "_snd_vol", translate("物理声卡音量控制"))
snd_vol.rawhtml = true
snd_vol.default = [[
<div style="padding: 10px 0;">
    <div style="display: flex; align-items: center; gap: 12px; max-width: 400px;">
        <input type="range" id="hw_vol_slider" min="0" max="100" value="50" 
               style="flex: 1; cursor: pointer;"
               oninput="document.getElementById('hw_vol_val').innerText = this.value + '%'"
               onchange="window.applyHwVolume(this.value)">
        <span id="hw_vol_val" style="font-weight: bold; width: 45px; text-align: right;">--%</span>
    </div>
    <div id="snd_info" style="color: #666; font-size: 13px; margin-top: 6px;">正在读取声卡信息...</div>
</div>
<script type="text/javascript">
    window.currentCard = "0";
    window.currentControl = "Headphone";
    window.owntoneBaseUrl = '/cgi-bin/luci/admin/nas/owntone';

    window.loadSoundcardInfo = function() {
        var xhr = new XMLHttpRequest();
        xhr.open('GET', window.owntoneBaseUrl + '/get_soundcard_info', true);
        xhr.onreadystatechange = function() {
            if (xhr.readyState === 4 && xhr.status === 200) {
                try {
                    var res = JSON.parse(xhr.responseText);
                    if (res.success) {
                        window.currentCard = res.card;
                        window.currentControl = res.control;
                        var infoEl = document.getElementById('snd_info');
                        if (infoEl) {
                            infoEl.innerHTML = '当前声卡: <b>' + res.name + '</b> (hw:' + res.card + ') | 控制项: <b>' + res.control + '</b>';
                        }
                        var sliderEl = document.getElementById('hw_vol_slider');
                        var valEl = document.getElementById('hw_vol_val');
                        if (typeof res.volume === 'number') {
                            if (sliderEl) sliderEl.value = res.volume;
                            if (valEl) valEl.innerText = res.volume + '%';
                        }
                    }
                } catch(e) {}
            }
        };
        xhr.send();
    };

    window.applyHwVolume = function(val) {
        var xhr = new XMLHttpRequest();
        xhr.open('POST', window.owntoneBaseUrl + '/set_volume', true);
        xhr.setRequestHeader('Content-Type', 'application/x-www-form-urlencoded');
        xhr.setRequestHeader('X-Requested-With', 'XMLHttpRequest');
        xhr.send('volume=' + val + '&card=' + window.currentCard + '&control=' + window.currentControl);
    };

    setTimeout(window.loadSoundcardInfo, 300);
</script>
]]

autoplay = s:taboption("playback", Flag, "autoplay", translate("自动播放音乐库"))
autoplay.default = "0"
autoplay.rmempty = false
autoplay.description = translate("Owntone 启动后自动把整个音乐库加入队列并开始播放。")

autoplay_random = s:taboption("playback", Flag, "autoplay_random", translate("随机选曲"))
autoplay_random.default = "0"
autoplay_random.rmempty = false
autoplay_random:depends("autoplay", "1")

autoplay_repeat = s:taboption("playback", Flag, "autoplay_repeat", translate("列表循环"))
autoplay_repeat.default = "0"
autoplay_repeat.rmempty = false
autoplay_repeat:depends("autoplay", "1")

-- ==================== 定时控制音量 ====================
for i = 1, 4 do
    local time_opts = '<option value="">(未设置)</option>'
    for h = 0, 23 do
        for m = 0, 50, 10 do
            local val = string.format("%02d:%02d", h, m)
            time_opts = time_opts .. string.format('<option value="%s">%s</option>', val, val)
        end
    end

    local vol_opts = '<option value="">(未设置)</option>'
    for v = 0, 100, 1 do
        vol_opts = vol_opts .. string.format('<option value="%d">%d%%</option>', v, v)
    end

    local html = string.format([[
    <div style="display: flex; align-items: center; gap: 20px; margin-bottom: 15px; padding-bottom: 15px; border-bottom: 1px dashed #eee;">
        <div style="display: flex; align-items: center; min-width: 130px;">
            <input type="checkbox" id="enable_time%d" name="enable_time%d" value="1" style="margin-right: 8px;" onchange="toggleScheduleRow(%d)">
            <label for="enable_time%d" style="font-weight: bold; cursor: pointer; margin: 0;">启用定时音量 %d</label>
        </div>
        <div id="schedule_fields_%d" style="display: none; gap: 20px; align-items: flex-end;">
            <div style="display: flex; flex-direction: column;">
                <label style="font-size: 12px; color: #666; margin-bottom: 4px;">时间点 (HH:MM)</label>
                <select name="time%d" id="time%d" style="width: 110px; height: 30px; border: 1px solid #ccc; border-radius: 3px; padding: 2px 5px;">%s</select>
            </div>
            <div style="display: flex; flex-direction: column;">
                <label style="font-size: 12px; color: #666; margin-bottom: 4px;">控制目标</label>
                <select name="target%d" id="target%d" style="width: 220px; height: 30px; border: 1px solid #ccc; border-radius: 3px; padding: 2px 5px;">
                    <option value="softvol">OwnTone 软件音量（只影响本地播放）</option>
                    <option value="hw">物理声卡音量（影响全部）</option>
                </select>
            </div>
            <div style="display: flex; flex-direction: column;">
                <label style="font-size: 12px; color: #666; margin-bottom: 4px;">音量 (%%)</label>
                <select name="volume%d" id="volume%d" style="width: 90px; height: 30px; border: 1px solid #ccc; border-radius: 3px; padding: 2px 5px;">%s</select>
            </div>
        </div>
    </div>
    ]], i, i, i, i, i, i, i, i, time_opts, i, i, i, i, vol_opts)

    local row_opt = s:taboption("schedule", DummyValue, "_schedule_row_" .. i)
    row_opt.rawhtml = true
    row_opt.default = html
end

local apply_btn = s:taboption("schedule", DummyValue, "_apply_schedule", translate("应用定时音量设置"))
apply_btn.rawhtml = true
apply_btn.default = [[

<button type="button" class="cbi-button cbi-button-apply" onclick="applySchedule()">应用定时音量设置</button>
<div id="schedule_status" style="color:#666;font-size:12px;margin-top:6px;"></div>
<script type="text/javascript">
function toggleScheduleRow(index) {
    var cb = document.getElementById('enable_time' + index);
    var fields = document.getElementById('schedule_fields_' + index);
    if (cb && fields) {
        fields.style.display = cb.checked ? 'flex' : 'none';
    }
}
function getFlagValue(suffix) {
    var el = document.getElementById(suffix);
    return (el && el.checked) ? '1' : '0';
}
function getInputValue(suffix) {
    var el = document.getElementById(suffix);
    return el ? el.value : '';
}
function setFlagValue(suffix, val) {
    var el = document.getElementById(suffix);
    if (el) {
        el.checked = (val === '1' || val === 1);
        if (suffix.indexOf('enable_time') !== -1) {
            var idx = suffix.replace('enable_time', '');
            toggleScheduleRow(idx);
        }
    }
}
function setInputValue(suffix, val) {
    var el = document.getElementById(suffix);
    if (el) el.value = val;
}

function applySchedule() {
    var params = {};
    for (var i = 1; i <= 4; i++) {
        params['enable_time' + i] = getFlagValue('enable_time' + i);
        params['time' + i]        = getInputValue('time' + i);
        params['target' + i]      = getInputValue('target' + i) || 'softvol';
        params['volume' + i]      = getInputValue('volume' + i);
    }
    var status = document.getElementById('schedule_status');
    status.innerHTML = '<span style="color:#666;">提交中...</span>';
    var xhr = new XMLHttpRequest();
    xhr.open('POST', '/cgi-bin/luci/admin/nas/owntone/apply_schedule', true);
    xhr.setRequestHeader('Content-Type', 'application/x-www-form-urlencoded');
    xhr.onreadystatechange = function() {
        if (xhr.readyState === 4) {
            if (xhr.status === 200) {
                try {
                    var res = JSON.parse(xhr.responseText);
                    status.innerHTML = '<span style="color:green;">✓ 已更新 ' + (res.count || 0) + ' 条定时任务</span>';
                } catch(e) {
                    status.innerHTML = '<span style="color:green;">✓ 已提交</span>';
                }
            } else {
                status.innerHTML = '<span style="color:red;">✗ 更新失败 (HTTP ' + xhr.status + ')</span>';
            }
        }
    };
    var body = Object.keys(params).map(function(k) {
        return encodeURIComponent(k) + '=' + encodeURIComponent(params[k]);
    }).join('&');
    xhr.send(body);
}

setTimeout(function() {
    try {
        var xhr = new XMLHttpRequest();
        xhr.open('POST', '/cgi-bin/luci/admin/nas/owntone/sync_schedule', true);
        xhr.setRequestHeader('X-Requested-With', 'XMLHttpRequest');
        xhr.onreadystatechange = function() {
            if (xhr.readyState === 4 && xhr.status === 200) {
                try {
                    var res = JSON.parse(xhr.responseText);
                    if (res.success && res.tasks) {
                        for (var i = 1; i <= 4; i++) {
                            var t = res.tasks[i-1] || res.tasks[i] || { enable: '0', time: '', target: 'softvol', volume: '' };
                            setFlagValue('enable_time' + i, t.enable);
                            setInputValue('time' + i, t.time);
                            setInputValue('target' + i, t.target);
                            setInputValue('volume' + i, t.volume);
                        }
                    }
                } catch(e) { console.log('sync parse error:', e); }
            }
        };
        xhr.send();
    } catch(e) { console.log('sync_schedule error:', e); }
}, 800);
</script>

]]

-- ==================== 基本设置 ====================
enable = s:taboption("basic", Flag, "enabled", translate("Enabled"))
enable.default = "0"
enable.rmempty = false

port = s:taboption("basic", Value, "port", translate("Port"))
port.rmempty = false
port.datatype = "port"

db_path = s:taboption("basic", Value, "db_path", translate("Database File Path"))
db_path.default = "/opt/owntone-songs3.db"
db_path.rmempty = false

directories = s:taboption("basic", Value, "directories", translate("Music Directorie Path"))
directories.default = "/opt/music"
directories.rmempty = false

-- ===== 目录选择器 + 数据库文件名辅助输入框 =====
local dir_picker = s:taboption("basic", DummyValue, "_dir_picker", "")
dir_picker.rawhtml = true
dir_picker.default = [[
<style>
.owntone-dp-overlay {
    position: fixed; top: 0; left: 0; right: 0; bottom: 0;
    background: rgba(0,0,0,0.5); z-index: 9999;
    display: flex; align-items: center; justify-content: center;
}
.owntone-dp-modal {
    background: #fff; border-radius: 6px; width: 90%; max-width: 520px;
    max-height: 80vh; display: flex; flex-direction: column;
    box-shadow: 0 8px 32px rgba(0,0,0,0.25);
    font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Arial, sans-serif;
}
.owntone-dp-header {
    background: #5b9bd5; color: #fff; padding: 12px 16px;
    border-radius: 6px 6px 0 0; font-weight: bold;
    display: flex; align-items: center; justify-content: space-between;
    font-size: 15px;
}
.owntone-dp-header .close {
    cursor: pointer; font-size: 18px; line-height: 1; opacity: 0.85;
    padding: 0 4px;
}
.owntone-dp-header .close:hover { opacity: 1; }
.owntone-dp-path {
    padding: 10px 16px; background: #f5f7fa; border-bottom: 1px solid #e0e6ed;
    font-size: 13px; color: #333; word-break: break-all;
}
.owntone-dp-path b { color: #5b9bd5; }
.owntone-dp-list {
    flex: 1; overflow-y: auto; padding: 4px 0;
    min-height: 200px; max-height: 55vh;
}
.owntone-dp-item {
    padding: 10px 16px; cursor: pointer; display: flex; align-items: center; gap: 10px;
    font-size: 14px; color: #333; border-bottom: 1px solid #f0f0f0;
}
.owntone-dp-item:hover { background: #eaf2fb; }
.owntone-dp-item .icon { color: #f5b942; font-size: 16px; width: 20px; text-align: center; }
.owntone-dp-item.parent .icon { color: #888; }
.owntone-dp-empty {
    padding: 30px 16px; text-align: center; color: #999; font-size: 13px;
}
.owntone-dp-footer {
    padding: 12px 16px; border-top: 1px solid #e0e6ed;
    display: flex; justify-content: flex-end; gap: 10px;
}
.owntone-dp-footer button {
    padding: 8px 20px; border-radius: 4px; border: none; cursor: pointer;
    font-size: 14px;
}
.owntone-dp-btn-cancel { background: #e0e0e0; color: #333; }
.owntone-dp-btn-cancel:hover { background: #d0d0d0; }
.owntone-dp-btn-select { background: #5cb85c; color: #fff; }
.owntone-dp-btn-select:hover { background: #4cae4c; }
.owntone-dp-trigger {
    margin-left: 8px; padding: 5px 12px; font-size: 12px;
    background: #5b9bd5; color: #fff; border: none; border-radius: 3px;
    cursor: pointer; vertical-align: middle;
}
.owntone-dp-trigger:hover { background: #4a8ac4; }
.owntone-dp-fnwrap {
    margin-left: 10px; display: inline-flex; align-items: center; gap: 6px;
    vertical-align: middle;
}
.owntone-dp-fnwrap label { font-size: 12px; color: #666; }
.owntone-dp-fnwrap input {
    width: 140px; height: 26px; padding: 2px 6px;
    border: 1px solid #ccc; border-radius: 3px; font-size: 13px;
}
</style>

<div id="owntone-dp-overlay" class="owntone-dp-overlay" style="display:none;">
    <div class="owntone-dp-modal">
        <div class="owntone-dp-header">
            <span>📁 选择目录</span>
            <span class="close" onclick="owntoneDpClose()">✕</span>
        </div>
        <div class="owntone-dp-path">当前位置：<b id="owntone-dp-path">/mnt</b></div>
        <div class="owntone-dp-list" id="owntone-dp-list"></div>
        <div class="owntone-dp-footer">
            <button type="button" class="owntone-dp-btn-cancel" onclick="owntoneDpClose()">取消</button>
            <button type="button" class="owntone-dp-btn-select" onclick="owntoneDpSelect()">✓ 选择此目录</button>
        </div>
    </div>
</div>

<script type="text/javascript">
(function() {
    var currentPath = '/mnt';
    var currentTarget = null;
    // ★ 数据库路径拆分状态：目录 + 文件名
    var dpState = { dir: '/mnt', name: 'songs.db' };

    function normalizeStart(val) {
        var p = (val || '').replace(/\/+$/, '');
        if (!p || p.indexOf('/mnt') !== 0) return '/mnt';
        return p;
    }

    // 从 db_path 值解析出 dir + name
    function parseDbPath(val) {
        if (!val) return;
        var m = val.match(/^(.*)\/([^\/]+)$/);
        if (m) {
            dpState.dir  = m[1] || '/mnt';
            dpState.name = m[2] || 'songs.db';
            if (dpState.dir.indexOf('/mnt') !== 0) dpState.dir = '/mnt';
        }
    }

    function getDbInput() {
        var inputs = document.querySelectorAll('input[type="text"]');
        for (var k = 0; k < inputs.length; k++) {
            if (inputs[k].name && inputs[k].name.indexOf('.db_path') !== -1) return inputs[k];
        }
        return null;
    }

    function syncDbInput() {
        var dbInput = getDbInput();
        if (!dbInput) return;
        dbInput.value = dpState.dir.replace(/\/+$/, '') + '/' + dpState.name;
        var fnInput = document.getElementById('owntone_db_filename');
        if (fnInput && fnInput.value !== dpState.name) fnInput.value = dpState.name;
    }

    window.owntoneDpOpen = function(inputEl) {
        currentTarget = inputEl;
        var isDb = inputEl.name && inputEl.name.indexOf('.db_path') !== -1;
        if (isDb) {
            currentPath = dpState.dir;
        } else {
            currentPath = normalizeStart(inputEl.value);
        }
        document.getElementById('owntone-dp-overlay').style.display = 'flex';
        owntoneDpLoad(currentPath);
    };

    window.owntoneDpClose = function() {
        document.getElementById('owntone-dp-overlay').style.display = 'none';
        currentTarget = null;
    };

    window.owntoneDpSelect = function() {
        if (currentTarget) {
            var isDb = currentTarget.name && currentTarget.name.indexOf('.db_path') !== -1;
            if (isDb) {
                // 数据库路径：目录 + 当前文件名
                dpState.dir = currentPath;
                currentTarget.value = currentPath.replace(/\/+$/, '') + '/' + dpState.name;
            } else {
                // 音乐目录：直接用选中的目录
                currentTarget.value = currentPath;
            }
            var evt = document.createEvent('HTMLEvents');
            evt.initEvent('change', true, true);
            currentTarget.dispatchEvent(evt);
        }
        owntoneDpClose();
    };

    window.owntoneDpLoad = function(path) {
        var listEl = document.getElementById('owntone-dp-list');
        var pathEl = document.getElementById('owntone-dp-path');
        listEl.innerHTML = '<div class="owntone-dp-empty">加载中...</div>';

        var xhr = new XMLHttpRequest();
        xhr.open('POST', '/cgi-bin/luci/admin/nas/owntone/browse_dir', true);
        xhr.setRequestHeader('Content-Type', 'application/x-www-form-urlencoded');
        xhr.setRequestHeader('X-Requested-With', 'XMLHttpRequest');
        xhr.onreadystatechange = function() {
            if (xhr.readyState !== 4) return;
            if (xhr.status !== 200) {
                listEl.innerHTML = '<div class="owntone-dp-empty">加载失败 (HTTP ' + xhr.status + ')</div>';
                return;
            }
            var res;
            try { res = JSON.parse(xhr.responseText); }
            catch(e) { listEl.innerHTML = '<div class="owntone-dp-empty">解析响应失败</div>'; return; }
            if (!res.success) {
                listEl.innerHTML = '<div class="owntone-dp-empty">加载失败</div>';
                return;
            }
            currentPath = res.path;
            pathEl.textContent = res.path;

            var html = '';
            if (res.parent) {
                html += '<div class="owntone-dp-item parent" onclick="owntoneDpLoad(\'' +
                    res.parent.replace(/'/g, "\\'") + '\')">' +
                    '<span class="icon">↩</span><span>.. (上级目录)</span></div>';
            }
            if (res.dirs && res.dirs.length > 0) {
                for (var i = 0; i < res.dirs.length; i++) {
                    var name = res.dirs[i];
                    var full = res.path + '/' + name;
                    html += '<div class="owntone-dp-item" onclick="owntoneDpLoad(\'' +
                        full.replace(/'/g, "\\'") + '\')">' +
                        '<span class="icon">📁</span><span>' + name + '</span></div>';
                }
            } else {
                html += '<div class="owntone-dp-empty">（此目录下没有子目录）</div>';
            }
            listEl.innerHTML = html;
        };
        xhr.send('path=' + encodeURIComponent(path));
    };

    // 给 db_path / directories 注入按钮和文件名框
    function attachPickers() {
        var fields = ['db_path', 'directories'];
        for (var i = 0; i < fields.length; i++) {
            var suffix = '.' + fields[i];
            var inputs = document.querySelectorAll('input[type="text"]');
            for (var k = 0; k < inputs.length; k++) {
                var el = inputs[k];
                if (!el.name || el.name.indexOf(suffix) === -1) continue;
                if (el.getAttribute('data-dp-attached') === '1') continue;
                el.setAttribute('data-dp-attached', '1');

                // 初始化 dpState（只对 db_path 做一次）
                if (fields[i] === 'db_path') {
                    parseDbPath(el.value);
                }

                // 加"选择目录"按钮
                var btn = document.createElement('button');
                btn.type = 'button';
                btn.className = 'owntone-dp-trigger';
                btn.textContent = '选择目录';
                (function(inputEl, buttonEl) {
                    buttonEl.onclick = function() { owntoneDpOpen(inputEl); };
                })(el, btn);
                if (el.parentNode) {
                    el.parentNode.insertBefore(btn, el.nextSibling);
                }

                // 对 db_path 再加"文件名"输入框
                if (fields[i] === 'db_path') {
                    var wrap = document.createElement('span');
                    wrap.className = 'owntone-dp-fnwrap';
                    wrap.innerHTML = '<label>文件名：</label>' +
                                     '<input type="text" id="owntone_db_filename">';
                    if (btn.parentNode) {
                        btn.parentNode.insertBefore(wrap, btn.nextSibling);
                    }

                    var fnInput = document.getElementById('owntone_db_filename');
                    if (fnInput) {
                        fnInput.value = dpState.name;
                        // 用户改文件名 -> 更新 db_path
                        fnInput.addEventListener('input', function() {
                            dpState.name = fnInput.value || 'songs.db';
                            syncDbInput();
                        });
                    }

                    // 用户手动改 db_path -> 失焦时同步 dpState 和文件名输入框
                    el.addEventListener('change', function() {
                        parseDbPath(el.value);
                        if (fnInput) fnInput.value = dpState.name;
                    });
                }
            }
        }
    }

    if (document.readyState === 'loading') {
        document.addEventListener('DOMContentLoaded', attachPickers);
    } else {
        attachPickers();
    }
    setTimeout(attachPickers, 400);
    setTimeout(attachPickers, 1000);
    setTimeout(attachPickers, 2000);
})();
</script>
]]

-- ===== 自定义播放器名称 =====
player_name = s:taboption("basic", Value, "player_name", translate("播放器名称"))
player_name.default = "My Music on OpenWrt"
player_name.rmempty = false
player_name.description = translate("在 iTunes / iOS Remote 等客户端中显示的库名称。<br><b style='color:#c00;'>注意：请使用英文、数字或拼音，不要使用中文，以免部分旧版客户端出现乱码或配对失败。</b>")

-- ===== MPD 端口 =====
mpd_port = s:taboption("basic", Value, "mpd_port", translate("MPD 端口"))
mpd_port.default = "6600"
mpd_port.datatype = "port"
mpd_port.rmempty = true
mpd_port.description = translate("默认 6600。如果你用 MPD 客户端（如 MPDlux）遥控，可以把它暴露出来，方便修改。设为 0 可禁用 MPD。")

readme = s:taboption("basic", DummyValue, "readme", translate("Readme"))
readme.description = translate("About iOS Remote Pairing: <br />1. Open the web interface <br /> 2. Start iPhone Remote APP, go to Settings, Add Library<br />3. Enter the pair code in the web interface")

local restart_btn = s:taboption("basic", DummyValue, "_restart_btn", translate("重启Owntone服务器"))
restart_btn.rawhtml = true
restart_btn.default = [[
<button type="button" class="cbi-button cbi-button-action" onclick="restartOwntone()">重启 Owntone 服务器</button>
<span id="restart_status" style="margin-left:10px;color:#666;font-size:12px;"></span>
<script type="text/javascript">
function restartOwntone() {
    var status = document.getElementById('restart_status');
    status.innerHTML = '正在重启...';
    var xhr = new XMLHttpRequest();
    xhr.open('POST', '/cgi-bin/luci/admin/nas/owntone/restart_service', true);
    xhr.setRequestHeader('X-Requested-With', 'XMLHttpRequest');
    xhr.onreadystatechange = function() {
        if (xhr.readyState === 4) {
            if (xhr.status === 200) {
                status.innerHTML = '<span style="color:green;">✓ 已重启</span>';
            } else {
                status.innerHTML = '<span style="color:red;">✗ 失败</span>';
            }
        }
    };
    xhr.send();
}
</script>
]]

-- ==================== 高级设置 ====================
local snd_refresh = s:taboption("advanced", DummyValue, "_snd_refresh", translate("刷新并自动配置声卡"))
snd_refresh.rawhtml = true
snd_refresh.default = [[
<div style="padding: 10px 0;">
    <button type="button" class="cbi-button cbi-button-action" id="refresh_snd_btn" onclick="refreshSoundcard()">刷新并自动配置声卡</button>
    <div style="color: #888; font-size: 12px; line-height: 1.7; margin-top: 8px;">
        <b>作用：</b>检测当前 USB 声卡的型号和编号，自动将声卡信息和独立音量控制（softvol）写入 <code>/etc/asound.conf</code>，并重启 OwnTone、AirPlay、DLNA 服务。<br>
        <b>使用时机：</b>仅在<b>更换 USB 声卡后手动点击一次</b>。平时调节音量请直接用上方“物理声卡音量控制”滑块。
    </div>
</div>
<script type="text/javascript">
    window.refreshSoundcard = function() {
        var btn = document.getElementById('refresh_snd_btn');
        if(!btn) return;
        btn.disabled = true;
        var oldText = btn.innerText;
        btn.innerText = '检测并写入中...';

        var xhr = new XMLHttpRequest();
        xhr.open('POST', window.owntoneBaseUrl + '/refresh_soundcard', true);
        xhr.setRequestHeader('X-Requested-With', 'XMLHttpRequest');
        xhr.onreadystatechange = function() {
            if (xhr.readyState === 4) {
                btn.disabled = false;
                btn.innerText = oldText;
                if (xhr.status === 200) {
                    try {
                        var res = JSON.parse(xhr.responseText);
                        if (res.success) {
                            window.currentCard = res.card;
                            window.currentControl = res.control;
                            var infoEl = document.getElementById('snd_info');
                            if (infoEl) {
                                infoEl.innerHTML = '当前声卡: <b>' + res.name + '</b> (hw:' + res.card + ') | 控制项: <b>' + res.control + '</b>';
                            }
                            var sliderEl = document.getElementById('hw_vol_slider');
                            var valEl = document.getElementById('hw_vol_val');
                            if (typeof res.volume === 'number') {
                                if (sliderEl) sliderEl.value = res.volume;
                                if (valEl) valEl.innerText = res.volume + '%';
                            }
                            alert('声卡配置已更新，服务已重启。');
                        } else {
                            alert('配置失败，请查看系统日志。');
                        }
                    } catch(e) {
                        alert('解析响应失败。');
                    }
                } else {
                    alert('请求失败 (HTTP ' + xhr.status + ')。');
                }
            }
        };
        xhr.send();
    };
</script>
]]

local reload_usb_btn = s:taboption("advanced", Button, "reload_usb_btn", translate("Reload USB Sound Loadable Kernel Module"))
reload_usb_btn.inputstyle = "reload"
function reload_usb_btn.write(self, section)
    sys.call("rmmod snd_usb_audio >/dev/null 2>&1; modprobe snd_usb_audio >/dev/null 2>&1")
end

local alsa_init_btn = s:taboption("advanced", Button, "alsa_init_btn", translate("Initialize All Sound Cards"))
alsa_init_btn.inputstyle = "reload"
function alsa_init_btn.write(self, section)
    sys.call("alsactl init >/dev/null 2>&1")
end

local diag = s:taboption("advanced", DummyValue, "_alsa_diag", translate("ALSA 诊断"))
diag.rawhtml = true
diag.cfgvalue = function(self, section)
    local cards = sys.exec("cat /proc/asound/cards 2>/dev/null") or ""
    local ctrls = sys.exec("amixer -c 0 scontrols 2>&1") or ""
    local asound = sys.exec("[ -f /etc/asound.conf ] && cat /etc/asound.conf || echo '(无 asound.conf)'") or ""

    local function esc(s)
        return (s:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"))
    end

    return string.format([[
<details>
<summary style="cursor:pointer;color:#06c;">点击展开原始输出</summary>
<b>/proc/asound/cards</b>
<pre style="background:#f7f7f7;padding:6px;border:1px solid #ddd;">%s</pre>
<b>amixer -c 0 scontrols</b>
<pre style="background:#f7f7f7;padding:6px;border:1px solid #ddd;">%s</pre>
<b>/etc/asound.conf</b>
<pre style="background:#f7f7f7;padding:6px;border:1px solid #ddd;">%s</pre>
</details>
]], esc(cards), esc(ctrls), esc(asound))
end

-- ==================== 日志查看 ====================
refresh_btn = s:taboption("logs", DummyValue, "_refresh_btn")
refresh_btn.rawhtml = true
refresh_btn.default = [[
<div style="margin-bottom:8px;">
  <button type="button" class="cbi-button cbi-button-action"
          onclick="location.reload();">刷新日志</button>
  <span style="margin-left:10px;color:#888;">
    共显示最近 200 行，切换子面板或点击按钮即可刷新
  </span>
</div>
]]

log_view = s:taboption("logs", TextValue, "_log_view", translate("Owntone 运行日志"))
log_view.rows     = 30
log_view.wrap     = "off"
log_view.readonly = true

function log_view.write(self, section, value)
end

function log_view.cfgvalue(self, section)
    local data
    data = sys.exec("logread -e owntone -e forked-daapd 2>/dev/null | tail -n 200")
    if not data or data == "" then
        data = sys.exec("[ -f /var/log/owntone.log ] && tail -n 200 /var/log/owntone.log 2>/dev/null")
    end
    if not data or data == "" then
        data = sys.exec("[ -f /tmp/log/owntone.log ] && tail -n 200 /tmp/log/owntone.log 2>/dev/null")
    end
    if not data or data == "" then
        data = translate("(暂无日志输出，请确认 Owntone 已启动)") .. "\n"
    end
    return data
end

return m
