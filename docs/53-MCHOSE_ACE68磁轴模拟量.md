# 53 · MCHOSE ACE68 磁轴键盘：按键深度 → 线性油门 / 线性转向

> 2026-11-06 · 用户：「我现在用的键盘是外设的 ACE68，我想让你识别这个磁轴的磁轴深度。
> 按这个磁轴按下去的深浅，可以做一个线性的油门和一个线性的转向，你看能实现吗？」

**结论：能，已实现并验证。** 不需要 M HUB、不需要浏览器，macOS 直接读键盘配置通道，
把 W/S/A/D 的按下深度线性映射成油门/刹车/转向；游戏端已有的模拟输入链路自动接收。

## 一、设备与协议（实测 + 固件分析）

| 项目 | 实测值 |
| --- | --- |
| 设备 | MCHOSE Ace68-II（USB 产品名 `Ace68-II`，零售名 Ace 68，M HUB 内部名 Ace 68 Pro） |
| USB ID | VID `0x41E4` / PID `0x2116`（USB 1.21 固件） |
| 配置接口 | Usage Page 1 / Usage 0，64 字节 IN/OUT，无 report ID（与 M HUB 网页驱动同一通道） |
| 探针读取 | base=`00 03 00 01 02 03`（当前 profile 0）、profile 头 `5002AABB…`、magic OK |
| 模拟量开关 | profile byte 7 **bit 3**；出厂 `0xE6`（关）→ 写 `0xEE`（开），读回校验通过 → 可还原 |
| A0 上报 | `[0]=A0, [1]=0x10, [2]=modifier, [3]=HID code, depth=BE[6,7], maximum=BE[14,15]` |
| 实测深度 | 录到 161 帧 W（HID 0x1A）：depth 11→341 / maximum 341，松开回 0（原始帧见下） |

原始 A0 示例（W 半按）：
```
A0 10 00 1A 00 0D 00 0B DD FF FF 00 06 03 01 55
        └key W   ↑depth=0x000B=11   ↑maximum=0x0155=341
```

配置命令帧（全部经过读回校验才认为成功）：
- `55 04 …` 读 base（6 字节：current,count,table[4]），Ace68-II 按 "BoundedUnchecked" 规则解析；
- `55 05 …` 读 settings（flash 0x20100+offset，每包 ≤56 字节，共 256 字节）；
- `55 06 …` 写 settings：`size=1, offset=profile*64+7, payload=新 byte7`（只改 bit 3）；
- 回复 `AA <op> 00 <ck> <size> <off> …`，checksum = `byte[4]+byte[5..7+size-1]`。

## 二、实现

### 2.1 macOS 原生桥（`tools/analog_input/ace68/ace68_macos.c`）

纯 C + IOHIDManager（`clang -O2 -framework IOKit -framework CoreFoundation`），无第三方依赖：

- 自动找 VID/PID + usage 1:0 的配置接口；
- `--probe` 只读；`--enable/--disable` 开关；`--capture N` 打印原始帧；`--stream` 桥接；
- `--stream` 生命周期：读原状态 → 若关则写 bit3 开（读回校验）→ 读 A0 → 每 8ms（约 125Hz）
  把 `steer = D深度 - A深度`、`throttle = W深度 - S深度` 用 JSON 发到 `127.0.0.1:48255`；
  Ctrl+C/退出时把 byte7 写回进入前的状态（--disable 同样可手动还原）；
- 键盘拔掉：IOHID 移除回调会停桥并把 UDP 归零。

### 2.2 游戏端

游戏在 `--v0.52` 就已经有模拟输入链路（`scripts/core/analog_input.gd` + `read_drive_input()`），
本次只把默认映射改成线性并做一次迁移：

- `Settings.analog_curve_steer/throttle` 默认 **1.0**（旧存档 v2 迁移一次性把 1.35/1.15 改成 1.0）；
- `analog_deadzone` 默认 0.02（键盘静止精确回 0，死区只滤极轻触碰）；
- 设置页「操作 → 模拟输入 ANALOG」可继续调端口/死区/曲线；状态行会显示「已连接（N 包）」。

### 2.3 使用

**现在游戏启动时会自动拉起磁轴桥**（macOS + 检测到 `tools/analog_input/ace68/ace68_macos` 时）：

- 直接双击项目根目录的 **`双击开始游戏.command`** 即可，不用再单独开桥接；
- 游戏退出时自动给桥发 SIGTERM，桥会把键盘模拟量开关还原后再退出；
- 如果游戏被强杀，桥有父进程看门狗，约 1 秒内自检退出并还原（另外会留
  `/tmp/apex_ace68_origin` 记录进入前状态，下次启动会补还原）；
- 关掉「设置→操作→模拟输入」即不会再自动启动桥（普通键盘照常玩）。

手动/排障用法（仍然可用）：

```bash
# 只读检查设备/开关状态
tools/analog_input/ace68/ace68_macos --probe
# 手动桥接（游戏会检测到 pidfile 并复用，退出时统一还原）
tools/analog_input/ace68/ace68_macos --stream
# 开/关模拟量上报（排障）
tools/analog_input/ace68/ace68_macos --enable / --disable
```

注意：
- **桥接运行期间关掉 M HUB 网页/驱动**（同一配置接口会被抢）；
- 先启动桥接再进游戏；退出游戏脚本会还原开关；
- 普通键盘数字输入/打字完全不受影响，桥接只旁路读取 A0 深度。

## 三、验证

| 项目 | 结果 |
| --- | --- |
| 探针 | 配置通道可读，固件 1.21，base/profile/magic 正常，出厂开关=关 |
| 开关写入 | `0xE6 → 0xEE` 写入 + 读回校验通过；`--disable` `0xEE → 0xE6` 还原通过 |
| A0 采集 | 161 帧 W 深度 11..341（max 341），松开回 0；帧头/字段与固件分析一致 |
| 桥接 → 游戏 | `--stream` → UDP：Godot 诊断场景 `analog_probe.tscn` 收到 210 包、`active=true`、退出码 0 |
| 还原 | 桥接退出后 `--probe` 确认开关回到 `0xE6`（关闭） |
| 回归 | `--editor --quit` 0 SCRIPT ERROR；`--verify` PASS（模拟输入断言仍过） |


## 四、限制与后续

- 只适配 Ace68-II PID `0x2116`；同家族（Jet 75 II / Zero75X / Ace 60 Pro 等）协议相同但 A0 key 表不同，
  代码里的 key 表是 Ace68-II 的 68 键表；
- 键盘固件升级若改协议会失败关闭（只读探针先失败，不会乱写设置）；
- macOS 若要求「输入监控」权限，给终端/启动脚本授权即可（本机测试未弹窗）；
- 转向/油门曲线/死区都在游戏设置页可调；如果想让转向更“跟手”，可把转向曲线调到 1.2~1.4；
- 目前 W/S/A/D 线性，E/Q 升降挡、空格手刹、Shift 氮气仍是数字键，不受影响。
