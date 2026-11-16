#!/bin/sh
# /usr/bin/owntone-volguard.sh —— 音量守护（一个脚本三种模式，替代原来的 3 个文件）
#
#   owntone-volguard.sh           单次检查：命中某个守护时段就锁音量（控制器调用）
#   owntone-volguard.sh safe      把 OwnTone + 物理声卡音量压到“安全音量”（重启后 1%）
#   owntone-volguard.sh daemon    常驻：每 5 秒检查，重启/声卡重插先压安全音量，再按时段锁定
#
# UCI（owntone 段）：
#   volguard_enabled   0/1          总开关
#   vg1..4_en          0/1          单段开关
#   vg1..4_start/end   HH:MM        结束早于开始表示跨夜
#   vg1..4_days        1,2,3        勾选的星期（1=周一 … 7=周日）
#   vg1..4_volume      0..100       该段锁定音量
#   vg1..4_target      both|softvol|hw
#   safevol_enabled    0/1（默认开）
#   safevol_volume     0..100（默认 1）

MODE="${1:-once}"

cfg() { uci -q get "owntone.@owntone[0].$1"; }

nz() { v=${1#0}; [ -n "$v" ] || v=0; echo "$v"; }
to_min() { echo $(( $(nz "${1%%:*}") * 60 + $(nz "${1##*:}") )); }

# 设置 OwnTone 和/或物理声卡音量
apply_vol() {
	local vol="$1" target="$2" port
	port=$(cfg port); [ -n "$port" ] || port=3689

	if [ "$target" = "both" ] || [ "$target" = "softvol" ]; then
		curl -s -m 3 -X PUT "http://127.0.0.1:${port}/api/player/volume?volume=${vol}" >/dev/null 2>&1
	fi

	if [ "$target" = "both" ] || [ "$target" = "hw" ]; then
		local card=0 ctl="" name ctrls
		if [ -f /etc/asound.conf ]; then
			name=$(sed -n 's/.*pcm "hw:\([^,]*\),.*/\1/p' /etc/asound.conf | head -n 1)
			if [ -n "$name" ]; then
				case "$name" in
					*[!0-9]*)
						card=$(grep -m1 -F "[${name}" /proc/asound/cards 2>/dev/null | awk '{print $1}')
						[ -n "$card" ] || card=0
						;;
					*) card=$name ;;
				esac
			fi
		fi
		ctrls=$(amixer -c "$card" scontrols 2>/dev/null)
		case "$ctrls" in
			*"'Headphone'"*) ctl=Headphone ;;
			*"'Master'"*)    ctl=Master ;;
			*"'PCM'"*)       ctl=PCM ;;
		esac
		[ -n "$ctl" ] && amixer -c "$card" sset "$ctl" "${vol}%" unmute >/dev/null 2>&1
	fi
}

# 单次：遍历 4 个时段，命中就锁定并退出
guard_once() {
	[ "$(cfg volguard_enabled)" = "1" ] || return 0

	local now dow i s e v t d sm em
	now=$(( $(nz "$(date +%H)") * 60 + $(nz "$(date +%M)") ))
	dow=$(date +%u)

	for i in 1 2 3 4; do
		s=$(cfg "vg${i}_start"); e=$(cfg "vg${i}_end")
		[ -n "$s" ] && [ -n "$e" ] || continue
		[ "$(cfg "vg${i}_en")" = "0" ] && continue

		d=$(cfg "vg${i}_days")
		case "$d" in
			all) ;;
			workday) [ "$dow" -le 5 ] || continue ;;
			weekend) [ "$dow" -ge 6 ] || continue ;;
			"") continue ;;
			*)
				case ",$d," in *",${dow},"*) ;; *) continue ;; esac
				;;
		esac

		v=$(cfg "vg${i}_volume"); case "$v" in ''|*[!0-9]*) v=5 ;; esac
		[ "$v" -le 100 ] || v=5
		t=$(cfg "vg${i}_target"); case "$t" in both|softvol|hw) ;; *) t=both ;; esac

		sm=$(to_min "$s"); em=$(to_min "$e")
		if [ "$sm" -le "$em" ]; then
			[ "$now" -ge "$sm" ] && [ "$now" -lt "$em" ] || continue
		else
			{ [ "$now" -ge "$sm" ] || [ "$now" -lt "$em" ]; } || continue
		fi

		apply_vol "$v" "$t"
		return 0
	done
	return 0
}

# 安全音量：等 API 就绪，连续压 3 次，再等声卡出现后设混音器
safe_volume() {
	[ "$(cfg safevol_enabled)" = "0" ] && return 0

	local vol port i j
	vol=$(cfg safevol_volume); case "$vol" in ''|*[!0-9]*) vol=1 ;; esac
	[ "$vol" -le 100 ] || vol=1
	port=$(cfg port); [ -n "$port" ] || port=3689

	i=0
	while [ $i -lt 20 ]; do
		curl -s -m 2 "http://127.0.0.1:${port}/api/player" >/dev/null 2>&1 && break
		sleep 1
		i=$((i + 1))
	done

	apply_vol "$vol" softvol
	sleep 3
	apply_vol "$vol" softvol
	sleep 4
	apply_vol "$vol" softvol

	j=0
	while [ $j -lt 30 ]; do
		if [ -s /proc/asound/cards ] && ! grep -q "no soundcards" /proc/asound/cards; then
			apply_vol "$vol" hw
			break
		fi
		sleep 1
		j=$((j + 1))
	done
	return 0
}

owntone_pid() {
	if [ -f /var/run/owntone.pid ]; then
		cat /var/run/owntone.pid 2>/dev/null
	else
		pgrep -f '/usr/sbin/owntone' 2>/dev/null | head -n 1
	fi
}

cards_hash() {
	cat /proc/asound/cards 2>/dev/null | md5sum | cut -d' ' -f1
}

# 常驻：重启/声卡变化 → 安全音量；每 5 秒按时段锁定
daemon_loop() {
	# 单实例：PID 文件里已有存活的守护进程就直接退出
	PIDF=/var/run/owntone-volguard.pid
	if [ -f "$PIDF" ]; then
		old=$(cat "$PIDF" 2>/dev/null)
		if [ -n "$old" ] && [ "$old" != "$$" ] && kill -0 "$old" 2>/dev/null; then
			return 0
		fi
	fi
	echo $$ > "$PIDF"
	sleep 1
	[ "$(cat "$PIDF" 2>/dev/null)" = "$$" ] || return 0

	local last="" pid ch
	while true; do
		pid=$(owntone_pid)
		ch=$(cards_hash)
		if [ -n "$pid" ] && [ "$pid:$ch" != "$last" ]; then
			safe_volume &
			last="$pid:$ch"
		fi
		guard_once
		sleep 5
	done
}

case "$MODE" in
	safe)   safe_volume ;;
	daemon) daemon_loop ;;
	*)      guard_once ;;
esac
