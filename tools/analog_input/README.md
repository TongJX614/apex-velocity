# 模拟输入桥（磁轴键盘 / 模拟手柄 / 自定义设备）

游戏本身对**普通键盘是数字输入**（按下=1、松开=0），对**手柄是模拟输入**（左摇杆转向、扳机油门）。
磁轴键盘能报告每个键按下的深度（0~255），但 **macOS 没有系统级「按键深度」API**，Godot 也拿不到键程，
所以用「本机 UDP 桥接」把深度送进游戏：

```
磁轴键盘/任何模拟设备 → (厂商软件/HID 读取/自写程序) → UDP 127.0.0.1:48255 → 游戏
                                                          ├─ steer   -1..1  → 转向角
                                                          └─ throttle 0..1  → 油门开度
```

游戏端在 `scripts/core/analog_input.gd`：默认开启，收到包并按
`Settings.analog_deadzone / analog_curve_steer / analog_curve_throttle` 映射；
**380ms 收不到包就自动回退普通键盘数字输入**，不影响正常玩法。端口在设置里可改（默认 48255）。

## 三种接法（按省事程度排序）

### 1) 厂商软件把键盘映射成「虚拟手柄」（最省事，推荐）
很多磁轴键盘的 macOS 驱动支持「模拟手柄 / Analog 模式」。开启后游戏会把它识别成手柄：
左摇杆/扳机天然是 0~1 连续量，**不需要本脚本**。游戏已支持手柄模拟量（`input_setup.gd`）。

### 2) 自写程序 / 厂商 SDK → UDP 桥接（通用）
任何程序只要能算出「转向/油门 0~1」，按下面协议发 UDP 即可：

```bash
# 一行一个包，JSON 或文本都行；建议 120Hz 以上
python3 tools/analog_input/analog_bridge.py --stdin
# 然后往它的 stdin 写：  0.35,0.80        （steer, throttle）
#                        s=0.35;t=0.80
#                        {"steer":0.35,"throttle":0.8,"brake":0.1}
```

协议细节（游戏端解析）：
- `steer`：-1（左满）~ +1（右满），0 回正
- `throttle`：0~1（油门开度）；`brake`：0~1（刹车深度），最终油门 = throttle - brake
- 包长 <512 字节，超过 380ms 没新包自动回退键盘

### 3) 磁轴键盘 HID 直读（进阶，需要改配置）
macOS 可以用 `hidapi` 读键盘原始 HID 报告，但**每个品牌报告格式不同**（有的每键一字节、有的位域），
需要用到厂商工具/抓包确认后填配置：

```bash
pip3 install hid
python3 tools/analog_input/analog_bridge.py --hid tools/analog_input/hid_config.example.json
```

`hid_config.example.json` 里 `vid/pid` 用 `system_profiler SPUSBDataType` 查，`fields` 指定
左/右/油门/刹车各占哪几个字节、位宽和满量程。

### 调试：不需要硬件先验证游戏链路
```bash
python3 tools/analog_input/analog_bridge.py --test
```
发送正弦转向 + 呼吸油门，进游戏开一段就能看到方向盘/油门连续变化（或看设置里的「模拟输入：已连接」）。

## 游戏端设置（Settings 持久化）
| 字段 | 含义 | 默认 |
| --- | --- | --- |
| `analog_input_enabled` | 启用模拟输入（关闭后只用键盘/手柄） | true |
| `analog_udp_port` | UDP 端口 | 48255 |
| `analog_deadzone` | 转向死区（0~0.6） | 0.03 |
| `analog_curve_steer` | 转向曲线（1=线性，>1 中间更细腻） | 1.35 |
| `analog_curve_throttle` | 油门曲线（1=线性） | 1.15 |

## 已知限制
- macOS 系统不暴露键程，必须走「厂商软件/自写桥接」这条路；本脚本自带 `--test` 与 `--stdin` 保证链路可用。
- `--hid` 需要 `hid` 包且知道设备协议；不确定就先问键盘厂商或抓 USB 报告。
- 游戏内设置面板目前由 UI 分支统一重做；未做 UI 前可以直接编辑
  `~/Library/Application Support/Godot/app_userdata/APEX VELOCITY · 极速巅峰/settings.json` 调整上面 5 个字段。

---

## MCHOSE Ace68-II 原生支持（2026-11-06）

本目录 `ace68/` 是给 **MCHOSE Ace68-II（USB 名 Ace68-II，VID 41E4 / PID 2116，固件 1.21）**
做的 macOS 原生桥接。不需要 M HUB，不需要浏览器，直接读写键盘配置通道：

```
W 键按下深度  → 线性油门 0..1（按多深给多少油）
S 键按下深度  → 线性刹车 0..1
A / D 键深度  → 线性转向 -1..+1（D-A）
```

### 原理（M HUB 协议，来自固件静态分析）

- 配置接口：Usage Page 1 / Usage 0，64 字节 IN/OUT，无 report ID；
- 命令帧 `55 <op> <ck> <size> <off> …`，回复 `AA <op> 00 <ck> <size> <off> …`，
  checksum = `byte[4] + byte[5..7+size-1]`；op `04` 读 base、`05` 读 settings（0x20100+offset，≤56B/包）、
  `06` 写 settings（profile byte 7 bit 3 = **模拟量上报开关**）；
- **重要（2026-11-07 排障结论）**：A0 深度流必须收到一次「写入」动作才会真正激活——
  键盘重新上电后，即使持久化配置里开关已经是开的，运行时流也不会自动恢复。
  因此桥接每次启动都强制写入一次开关（同值也写），否则会静默收不到任何深度帧；
- 打开开关后键盘推送 `A0` 上报：`[0]=A0, [1]=0x10, [2]=modifier, [3]=HID code,
  depth=BE(6,7), maximum=BE(14,15)`，深度 0..maximum（本键盘 maximum=341）。

### 使用

```bash
cd tools/analog_input/ace68
clang -O2 -framework IOKit -framework CoreFoundation ace68_macos.c -o ace68_macos
# 只读检查
./ace68_macos --probe
# 开/关模拟量上报（排障用）
./ace68_macos --enable / --disable
# 桥接（会自己开开关、退出自动还原；Ctrl+C 结束）
./ace68_macos --stream
# 游戏现在会自动拉起桥接（双击项目根的 双击开始游戏.command 即可），退出自动还原；
# 也可以双击：启动游戏_磁轴键盘.command（手动桥接 + 游戏，等价）
```

- 游戏端设置：「操作 → 模拟输入 ANALOG」保持启用，UDP 端口默认 48255；
  默认映射已改为**线性**（转向/油门曲线 1.0，死区 0.02），旧存档会自动迁移一次；
- 桥接运行期间**关掉 M HUB 网页/驱动**（它和桥接抢同一个配置接口）；
- 桥接启动后先等 A0 深度帧：**没收到 A0 数据前不会向游戏发任何 UDP**（超过 1.5s 无数据自动
  停发并清零），游戏侧 380ms 无包会自动回退普通键盘数字输入——桥接空转不再导致键盘失灵；
  日志里出现「A0 无数据/过期，暂停发送」即处于该状态；
- 桥接每秒打印 `W/A/S/D` 深度与包数；`--capture 30` 可导出原始 A0 帧做调试；
- 退出（Ctrl+C / 关闭启动脚本）会自动把开关还原为进入前状态；若进程被强杀，可重新插拔键盘后
  运行 `./ace68_macos --disable` 还原；
- 普通键盘打字/其他按键不受影响（只读 A0 深度，不拦截键盘事件）。

### 已知限制

- 只测过 Ace68-II 1.21（PID 2116）；同家族其他固件/型号的 A0 描述符表可能不同；
- 键盘固件升级后协议若变化，`--probe`/`--stream` 会失败关闭（不会乱写设置）；
- macOS 若弹出「输入监控」权限，需允许终端/启动脚本所在 app；本机测试无需授权即可读配置接口。
