#!/bin/sh
# /usr/bin/usb-audio-refresh.sh
# 不重启路由器，把被 VirtualHere 释放后没挂回内核的 USB 声卡重新挂出来。
#   ./usb-audio-refresh.sh       只恢复声卡
#   ./usb-audio-refresh.sh -r    恢复后重启 owntone / shairport-sync / gmediarender
DRV=/sys/bus/usb/drivers/snd-usb-audio
SERVICES="owntone shairport-sync gmediarender"
RESTART=0
[ "$1" = "-r" ] && RESTART=1

log() { echo "$*"; }

stop_services() {
	for s in $SERVICES; do
		[ -x "/etc/init.d/$s" ] && /etc/init.d/$s stop >/dev/null 2>&1
	done
}

find_audio_ifaces() {
	# 输出该 USB 设备下所有 audio class(01) 的接口名
	for d in /sys/bus/usb/devices/*:*; do
		[ -f "$d/bInterfaceClass" ] || continue
		[ "$(cat "$d/bInterfaceClass" 2>/dev/null)" = "01" ] || continue
		basename "$d"
	done
}

log "--- 当前声卡 ---"
cat /proc/asound/cards

if [ -s /proc/asound/pcm ]; then
	log "声卡和 PCM 已存在，无需恢复"
	exit 0
fi

IFACES=$(find_audio_ifaces)
[ -n "$IFACES" ] || { log "没找到 USB 音频设备（是否已插好？）"; exit 1; }
log "音频接口: $(echo $IFACES)"

stop_services

# 1) 解绑所有接口
for i in $IFACES; do
	[ -d "$DRV" ] && echo "$i" > "$DRV/unbind" 2>/dev/null
done

# 2) 重载驱动
rmmod snd_usb_audio 2>/dev/null && log "snd_usb_audio 已卸载"
modprobe snd-usb-audio 2>/dev/null && log "snd_usb_audio 已加载"
sleep 2

# 3) 绑回控制接口（class 01 subclass 01），PCM 会随之注册
for i in $IFACES; do
	sub=$(cat "/sys/bus/usb/devices/$i/bInterfaceSubClass" 2>/dev/null)
	[ "$sub" = "01" ] || continue
	echo "$i" > "$DRV/bind" 2>/dev/null && log "已绑定控制接口 $i"
done

sleep 2
log "--- 恢复结果 ---"
cat /proc/asound/cards
if [ -s /proc/asound/pcm ]; then
	log "PCM: $(cat /proc/asound/pcm)"
	aplay -l 2>/dev/null | head -4
else
	# 兜底：把剩余音频接口也绑一遍
	for i in $IFACES; do
		echo "$i" > "$DRV/bind" 2>/dev/null
	done
	sleep 2
	cat /proc/asound/cards
	cat /proc/asound/pcm
fi

if [ "$RESTART" = 1 ]; then
	for s in $SERVICES; do
		[ -x "/etc/init.d/$s" ] && /etc/init.d/$s restart >/dev/null 2>&1 && log "已重启 $s"
	done
fi
