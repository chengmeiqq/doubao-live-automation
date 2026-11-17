# 自动化豆包直播

安卓手机**全自动**：开机自己起来，打开豆包、发起通话、共享屏幕，再把 4K 直播 App 拉到前台并设好参数。全程不需要电脑、不需要 usb 线、不需要另一台设备。挂在一边自己跑。

实测冷启动到「投屏 + 4K 直播并存」约 **55 秒**，之后每 20 秒自检一次。

## 它解决的是什么

豆包的「共享屏幕」和直播 App 的 4K 推流是两个独立链路，同时跑会互相抢相机、抢前台、抢 media projection 授权。手工做一遍能用，但：

- 手机重启后要重新点一遍
- 屏幕一黑，投屏还在、API 还报 `streaming=true`，实际全是黑帧
- 投屏被系统拒权后服务还在跑，看着正常其实黑屏
- 参数被 App 记住的上次选择带偏，日志一路「设好了」而镜头是错的

这个项目把这些全部做成了自愈逻辑，日志里能看出每一步做了什么。

## 前置条件

| 项 | 要求 |
|---|---|
| 手机 | 已 root（Magisk）。Termux 能 `su -c id` 拿到 `uid=0` |
| Termux | 装好，`python3`、`curl`、`flock` 可用 |
| 豆包 | 已登录，能正常打「打电话」并「共享屏幕」 |
| 直播 App | 提供 HTTP API（默认 `127.0.0.1:41737`）和 RTSP 输出 |
| 系统 | 需要 `dumpsys` / `am` / `input` / `appops`（Android 8+ 均可） |

Magisk 的 `service.d` 是自启的关键：那里跑的是 **root shell**，不是 app 进程，MIUI 的省电杀进程碰不到它。

## 安装

```sh
# 1) 把脚本放进 Termux 家目录
cp nova.sh nocharge.sh battemp.sh ~/
chmod 755 ~/nova.sh ~/nocharge.sh ~/battemp.sh

# 2) 装开机自启（会自己生成 /data/adb/service.d/nova.sh）
~/nova.sh install

# 3) 立即试跑一次，不用等重启
~/nova.sh once

# 4) 常驻守护
~/nova.sh start
```

`install` 做的事：写 `persist.adb.tcp.port=5555`、往 `/data/adb/service.d/` 放启动器、在 `~/.termux/boot/` 留一份备用。

开机链路：

```
Magisk service.d/nova.sh (root)
  └ 等 sys.boot_completed=1，再等 15s 让 MIUI 初始化完
  └ 每 20s 扫 /proc 严格匹配 "./nova.sh watch"，死了就重拉
      └ nova.sh watch 每 20s 跑一次 mode_lens
```

## 用法

```sh
./nova.sh once      # 投屏 + 直播走一遍就退出，适合调试
./nova.sh lens      # 只保直播（参数 + 出图）
./nova.sh share     # 只做投屏
./nova.sh watch     # 常驻守护（flock 单实例）
./nova.sh status    # 看当前状态
./nova.sh stop      # 停守护（会写 pause 标记，防 service.d 立刻重拉）
./nova.sh start     # 撤 pause 标记并启动
./nova.sh install   # 装开机自启
```

`stop` 不是简单 kill：service.d 每 20 秒会把守护拉回来，所以它同时写 `~/.nova/pause`，让启动器的每次尝试变成空操作。

## 默认参数

写死在 `nova.sh` 的两处 POST 里（`ensure_lens` 里一个，相机重置后的重试一个，**改要两处一起改**）：

```
camera=0 &resolution=3840x2160 &quality=100 &zoom=1.53
```

`camera=0` 在直播 App 界面上显示为「后摄 3」。同一颗物理模组的其它 logical 流：

| 值 | 界面标签 |
|---|---|
| `0:2` | 后摄 1 |
| `0:8` | 后摄 2 |
| `0` | 后摄 3 |
| `1` | 前摄 |

参数校验函数 `lens_probe` / `lens_params_ok` 会比对**全部四个字段**（含相机），任一不对就自动重设。相机被手动切换或 App 重启回落默认，下一轮 20 秒内会被拉回来。

## 附加脚本

### `nocharge.sh` —— 只留 USB 调试，不要充电

适合假电池 + DC 直供电的场景：USB 线只用来跑 adb，不希望 host 端 VBUS 往电池回灌。

```sh
cp nocharge.sh /data/adb/service.d/ && chmod 755 /data/adb/service.d/nocharge.sh
```

核心就一句：

```sh
echo 1 > /sys/class/qcom-battery/input_suspend
```

效果：`status: Charging → Discharging`、`usb_online: 1 → 0`，**而 adb 数据通道完全正常**。

试过但**无效**的路子（别浪费时间）：

| 节点 | 结果 |
|---|---|
| `restrict_chg=1` | 读回 1，但 HAL 不认，仍在 600~700mA 充电 |
| `vbus_disable=1` | 写入直接回弹 0，内核拒绝 |
| `battery/charge_type` | 只读（`r--r--r--`） |

同时它会伪造 framework 的电池上报。原因：假电池的 fuel gauge 早就不准了（有的机器 `charge_full` 只有设计值的 20%，`capacity` 硬卡在 1，而电压其实是满电 4.23V）。关掉充电后 framework 看到「1% + 在放电 + 无外部供电」就会走低电量关机流程。脚本用 `dumpsys battery set level 100 / set ac 1 / set status 2` 覆盖上报值，内核层保持 Discharging。

恢复充电：`echo 0 > /sys/class/qcom-battery/input_suspend`

### `battemp.sh` —— 伪造电池温度

假电池没有温度传感器，驱动读不到时返回 `-406`（-40.6°C 哨兵值），MIUI 会当成低温，反复弹「低温关机提醒」。这个脚本用 `dumpsys battery set temp 300` 覆盖成 30°C，每 60 秒重申。

恢复真实上报：`dumpsys battery reset`

## 排查

日志：`~/.nova/nova.log`（`nova.sh` 的），`/data/local/tmp/nova-boot.log`（启动器的）

```sh
./nova.sh status
```

正常输出长这样：

```
===== 2026-11-17 10:20:47 =====
root:       uid=0(root) gid=0(root) ...
前台:       com.opencode.multilensipcam/.MainActivity
屏幕:       Awake
投屏:       开
直播:       streaming=True 3840x2160 q100 zoom1.53
守护:       跑着 pid=2507
```

心跳每 5 分钟写一行，带投屏/直播/分辨率/电量。

### 几个反直觉的坑（都是实测踩出来的）

**1. `dumpsys media_projection` 返回 `null` 不代表没投屏。**
本 ROM 投屏活着时它照样 `null`。判活要用双条件：`ScreenCaptureService` 存在 **且** `dumpsys display` 里有 `uniqueId="virtual:...` + `state ON` + owner 是本 App。

**2. `ScreenCaptureService` 在跑不代表有画面。**
media projection 授权被拒时服务照样在跑，抓出来全黑。所以 `ensure_share()` 开头先查 `appops get <pkg> PROJECT_MEDIA`，命中 `ignore|deny` 就 `appops set ... allow`。

**3. 屏幕黑了脚本会一路报成功。**
熄屏后 VirtualDisplay 仍 `state ON`、API 仍 `streaming=true`，但抓到的全是黑帧。`ensure_screen_on` 必须放在巡检入口无条件执行——原先只在 `ensure_share` 里调，而「投屏已在」走的是另一条分支，根本进不去。

**4. 别用 `/snapshot.jpg` 判活。**
每请求一次就触发一次抓帧，走 `onMjpegDemandStateChanged → rebuildRepeatingRequest`，和相机重建撞上会抛 `CameraDevice was already closed` 把 App 打崩。判活只读 `/api/state`。

**5. 守护进程扫描不能用子串匹配。**
`*nova.sh*watch*` 会匹配到启动器自己，于是永远认为「守护还在」，真死了也不重拉。要用严格三段式：参数正好 3 个、第 2 个是 `./nova.sh`、第 3 个是 `watch`。

**6. 停守护必须走 root。**
`service.d` 起的是 root 进程，Termux 用户的 `pkill` 杀不掉，于是「停了」只是假象，老的还在跑。会有 root + Termux 两个守护每 20 秒互相抢投屏，实测能把直播 API 打到端口都不监听。

## 实测数据

- 冷启动到投屏 + 4K 直播并存：**55 秒**
- RTSP：3840x2160，30fps，20 秒收 594 包（29.7fps），最大帧间隙 0.256s
- 重启后自动恢复：4K 参数、相机、投屏全部正确
- 抓帧校验：灰度 std > 15 判为真实画面（用 `ffmpeg -map 0:v:0 -an -f image2 -update 1 -frames:v 1`）

## 许可

MIT