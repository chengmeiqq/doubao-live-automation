#!/system/bin/sh
# nocharge.sh - 只保留 USB 数据/调试，不要充电
#
# 背景：这台手机用假电池 + DC12V 直供电，USB 线只是用来跑 adb 和投屏调试的，
# 不需要从 USB 取电，也不希望 host 端 VBUS 往电池回灌（假电池没有保护电路，
# 而且 fuel gauge 早就不准了）。
#
# 试过但无效的路子（都实测过，别再走一遍）：
#   /sys/class/qcom-battery/restrict_chg  写入 1，读回 1，但 status 仍是
#       Charging、current_now 仍有 600~700mA —— MiCharge HAL 不认这个开关。
#   /sys/class/qcom-battery/vbus_disable  写入 1 直接回弹成 0，内核拒绝。
#   /sys/class/power_supply/battery/charge_type   只读（r--r--r--）。
#
# 有效的是 input_suspend：
#   echo 1 > /sys/class/qcom-battery/input_suspend
#   实测之后 status: Charging -> Discharging，usb_online: 1 -> 0，
#   而 adb 的 USB 数据通道完全正常（同一时刻 USB 和 WiFi 两条 transport 都在线）。
#   也就是「充电输入挂了，数据没挂」，正是要的效果。
#
# 为什么必须开机重设：init.target.rc / micharge rc 里只有 chown/chmod，
# 没有写值，节点重启后回到 0。所以由本脚本在 boot 之后重申。
#
# 恢复充电：echo 0 > /sys/class/qcom-battery/input_suspend

TAG=nocharge
LOG=/data/local/tmp/nocharge.log
NODE=/sys/class/qcom-battery/input_suspend
FAKE_LEVEL=${NOVA_FAKE_LEVEL:-100}

log() { echo "$(date '+%m-%d %H:%M:%S') $*" >> "$LOG"; }

# 等系统就绪：qcom-battery 节点由 micharge HAL 建出来，
# boot_completed 之前可能还不存在，太早写会失败。
i=0
while [ $i -lt 120 ]; do
  [ "$(getprop sys.boot_completed 2>/dev/null | tr -d '\r')" = "1" ] && break
  sleep 2
  i=$((i + 1))
done
# boot_completed=1 之后 micharge 还要一会儿才把节点 chown/chmod 出来
sleep 8

log "启动 pid=$$ node=$NODE"

if [ ! -e "$NODE" ]; then
  log "节点不存在，放弃"
  exit 0
fi

# 每 30s 重申。正常情况下设一次就一直保持，但这几种情况会把它冲掉：
#   - 拔插 USB（Type-C 重新协商，micharge 可能重置输入通路）
#   - 系统重启 micharge HAL
#   - 别的东西（省电模式、温控）改了充电策略
# 重申成本可忽略，所以定期兜底。只在「本来是 1、现在不是 1」时才写，
# 避免无谓地刷节点。
#
# 另一半同样关键：关掉充电后内核会如实报 Discharging + usb_online=0，
# 而假电池的 fuel gauge 早就坏了（实测 charge_full 956000 只有设计值
# 4860000 的 20%，cycle_count 1049），capacity 硬卡在 1，而电压 4.23V
# 明明是满电。framework 看到「1% + 在放电 + 无外部供电」就会走低电量
# 流程，迟早弹关机 —— 这台机器是要长期无人值守跑直播的，不能这样。
# 所以用 dumpsys 把上报值改成真实情况：level 100 / ac 1 / status 2。
# 覆盖是内存态，重启就丢，也必须由本脚本重申。
# 恢复真实上报：dumpsys battery reset
while true; do
  cur=$(cat "$NODE" 2>/dev/null | tr -d '\r\n')
  if [ "$cur" != "1" ]; then
    echo 1 > "$NODE" 2>/dev/null
    new=$(cat "$NODE" 2>/dev/null | tr -d '\r\n')
    st=$(cat /sys/class/power_supply/battery/status 2>/dev/null | tr -d '\r\n')
    usb=$(cat /sys/class/power_supply/usb/online 2>/dev/null | tr -d '\r\n')
    log "input_suspend $cur -> $new (status=$st usb_online=$usb)"
  fi

  # framework 上报兜底：只看 level 和 AC powered 两项，status 跟着走。
  bl=$(dumpsys battery 2>/dev/null | sed -n 's/^ *level: *//p' | tr -d '\r\n')
  bac=$(dumpsys battery 2>/dev/null | sed -n 's/^ *AC powered: *//p' | tr -d '\r\n')
  if [ "$bl" != "$FAKE_LEVEL" ] || [ "$bac" != "true" ]; then
    dumpsys battery set level "$FAKE_LEVEL" >/dev/null 2>&1
    dumpsys battery set ac 1 >/dev/null 2>&1
    dumpsys battery set status 2 >/dev/null 2>&1
    nbl=$(dumpsys battery 2>/dev/null | sed -n 's/^ *level: *//p' | tr -d '\r\n')
    log "framework 上报 $bl/$bac -> $nbl/true"
  fi
  sleep 30
done
