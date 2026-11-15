# cars/ · 车辆模块

车辆模型、引擎录音、车辆物理 / 视觉 / 相机脚本的独立归属。地图团队只保证 `TrackPath` 与都会环线碰撞查询接口；车辆团队不需要触碰 `maps/` 的资产或场景构建代码。

## 目录

```
cars/
├── assets/
│   ├── models/             # 45 台车 GLB + 同目录贴图；文件名 = data/cars.json 的 model 字段
│   └── audio/engine/       # 引擎声“燃烧质感层”录音（CC0，授权清单见目录内 README）
├── scripts/
│   ├── car.gd              # class_name Car：玩家 / AI / 幽灵车共用的物理与输入
│   ├── ai_car.gd           # class_name AICar：巡线、超车、圈速
│   ├── car_visual.gd       # class_name CarVisual：GLB 装配、涂装、阴影档位
│   ├── parts_library.gd    # class_name PartsLibrary：轮毂 / 尾翼等零件几何
│   ├── procedural_parts.gd # class_name ProceduralParts：程序化零件
│   ├── chase_camera.gd     # class_name ChaseCamera：追尾 / 车头 / 远景相机
│   ├── duel_camera.gd      # class_name DuelCamera：分屏双车相机
│   └── garage_look.gd      # class_name GarageLook：车库影棚布光与转台
└── README.md
```

## 对外契约

`scripts/core/main.gd` 与车库 / 分屏 UI 只依赖以下入口：

| 类型 | 入口 | 约定 |
| --- | --- | --- |
| `Car` | `setup(spec, track_path, start_dist, lateral, paint, look_config, build_visual)`<br>`update_car(dt, input)` / `reset(...)` | 赛道装配；都会环线由主流程注入 `city` 碰撞场；`input` 由 core 输入层提供；物理固定 120Hz 步进 |
| `AICar` | `setup(track_path, spec, start_dist, lateral, ...)`<br>`set_route(line, id)` / `update_ai(dt, player_car, race_laps, rivals, pace)` | 路线与节奏来自 `data/ai.json` 与 `TrackPath`，不得读地图资产 |
| `CarVisual` | `build(spec, parent)` / `model_aabb(model)` | 只负责视觉，不参与物理；模型缺失时回退到程序化占位 |
| `ChaseCamera` / `DuelCamera` | `follow(car, track_path)` / `follow_duo(a, b, path)` | 相机参数受 `Settings` 画质档控制；车头视角 FOV 已固定，禁止加速度相关动态 |
| `PartsLibrary` / `ProceduralParts` | 静态查询 / 构建 | 零件偏移来自 `data/parts_offsets.json` |
| `GarageLook` | 车库布光入口 | 仅展示，不进入比赛 |

## 资源契约

1. **模型**：`res://cars/assets/models/<file>.glb`，文件名写入 `data/cars.json` 每条 spec 的 `model` 字段。直接平铺在该目录，不建新子目录（`parts/` 为历史遗留，已不再引用）。
2. **贴图**：GLB 的外部贴图必须与 GLB 同目录（相对 URI），移动模型时整目录一起移动；路径大小写敏感。
3. **新增车辆**：
   - 放 GLB（+ 贴图）到 `cars/assets/models/`；
   - 在 `data/cars.json` 增加 spec（`id`、`model`、性能 / 声音字段）；
   - 在 `data/car_manifest.json` 登记（审计工具读取）；
   - 跑 `tools/audit_cars.gd` 与 `tools/car_audit/` 自检；
   - 车库、AI 对手池、展示场景由 `GameData` 自动发现，无需改 UI。
4. **引擎声**：录音在 `res://cars/assets/audio/engine/`；缸体族 → 文件映射在 `scripts/core/engine_audio.gd` 的 `TEXTURE_FILES` / `EV_TEXTURE`，逐车参数在 `data/engine_sounds.json`。

## 数据输入（由 GameData / Garage 解析，本模块只读）

`data/cars.json`、`data/car_manifest.json`、`data/engine_sounds.json`、`data/garage.json`、`data/parts_offsets.json`。

## 允许的依赖方向

- 可以：`GameData` / `Settings` / `Garage`（autoload）、`TrackPath` 几何（只读）、都会环线的 `height_at` / `surface_at` / `push_out`（鸭子类型）。
- 禁止：引用 `maps/` 的场景构建代码、地图资源路径或 UI 脚本。
- 地图模块不得反向引用 `cars/`。

## 验证

```bash
# 车辆资产审计（材质 / 轮心 / AABB）
Godot --headless --path . --script res://tools/audit_cars.gd

# 实机截图（必须窗口模式；headless 会丢失 MultiMesh 变换）
Godot --path . -- --shot=/tmp/cars_garage.png --shot-scene=garage
```
