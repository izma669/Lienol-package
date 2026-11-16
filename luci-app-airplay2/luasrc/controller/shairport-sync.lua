-- Copyright 2014 Álvaro Fernández Rojas <noltari@gmail.com>
-- Licensed to the public under the Apache License 2.0.

module("luci.controller.shairport-sync", package.seeall)

function index()
	if not nixio.fs.access("/etc/config/shairport-sync") then
		return
	end

	local page = entry({"admin", "services", "shairport-sync"}, cbi("shairport-sync"), _("AirPlay 2 Receiver"))
	page.dependent = true
	page.acl_depends = { "luci-app-airplay2" }

	-- 状态 / 正在播放展示已移到 888 端口的“音乐中心”，
	-- 原 nowplaying / cover / status 接口随旧展示页一起删除。
end
