# maps/ · 地图模块

11 张地图（9 条封闭赛道 + 都会环线 + 漂移练习开放场地）、天空/远景与 BGM 的独立归属。车辆团队只消费 `TrackPath` 与都会环线碰撞查询接口；地图团队不需要触碰 `cars/`。

## 目录

```
maps/
├── assets/
│   ├── venues/             # 场地套件、真实树、路面/场地贴图（venue_manifest.json）
│   ├── buildings/          # 城市英雄建筑（PBR 高模）
│   ├── backdrops/          # 赛道天际线背景（菜单 / 开场也读取）
│   ├── polyhaven/          # CC0 PBR 贴图 / HDRI / 岩石原始库
│   └── city_ring/          # 都会环线 GLB + 楼体贴图 + 碰撞数据（bin/res）
├── audio/bgm/              # 赛道 BGM；索引在 data/bgm_manifest.json（file = bgm/*.ogg）
├── scripts/
│   ├── tracks/             # TrackBuilder / TrackPath / SceneryKit / ThemeScenery /
│   │                       # VenueKit / RealAssetKit / PbrAssets / Terrain /
│   │                       # GrassScatter / BakedMultiMesh
│   └── openworld/          # 都会环线：CityWorld / CityFacades /
│                           # CityCollisionData
└── README.md
```

## 对外契约

| 类型 | 入口 | 约定 |
| --- | --- | --- |
| `TrackBuilder` | `build(def) -> TrackPath`<br>`configure_terrain(path)` | 按 `data/tracks.json` 的定义生成赛道几何 |
| `TrackPath` | `build_from_def` / `frame_at` / `nearest`<br>`half_width_at_dist` / `max_curvature_ahead`<br>`main_straight` / `venue_span` | **车辆只读契约**；`samples/tangents/sides/curvatures` 为只读数据 |
| `SceneryKit` | `build(parent, path, def) -> Dictionary`<br>`is_night_theme(theme)` | 赛道场景主入口（地形 / 植被 / 建筑 / 远山） |
| `ThemeScenery` | `build(container, path, def, theme, ...)` | 主题化远景与地标；夜晚主题已锁定亮度 |
| `CityWorld` | `load_collision(path)` / `height_at` / `surface_at`<br>`distance_at` / `push_out` | 都会环线；碰撞优先加载 `.res`，回退 `.bin` |
| `CityFacades` | `apply(root)` | 给 `city_ring.glb` 材质换真实楼体贴图 |

### 开放漂移场地（`openField`）

`data/tracks.json` 里带 `openField: true` 的图（当前为 `drift` 漂移练习）走独立分支：
`TrackBuilder.build` 只铺一块 `fieldSize` 见方的整片柏油（8m 平铺 + 46m 细节层，无标线/路肩/护栏/起跑格）加一圈草地外延；`SceneryKit` / `VenueKit` 直接返回零布景，`configure_terrain` 保持地形平坦。`TrackPath.open_field` / `field_half` 供车辆与相机判断：场内没有墙，越出方形边界按草地阻力处理；样条只作小地图与出生参考。主流程强制单人自由练习（计时赛通道），GO 即计时，无圈数/分段/逆行/完赛，漂移连击照常记分。

摆桩练习的锥桶不属于地图几何：`scripts/core/cone_field.gd`（MultiMesh 锥桶 + 车体 OBB 撞倒判定，只倒不挡车）、`scripts/core/cone_store.gd`（布局存 `user://cone_layout_drift.json` + 三套预设）、`scripts/ui/cone_editor.gd`（俯视图光标摆桩，打开期间整棵树暂停）。地图模块不感知锥桶。

## 资源契约

1. **场地资产**：`res://maps/assets/venues/`（`RealAssetKit.ROOT`）。装饰编辑器会扫描该目录全部 `.glb`；新增模型直接放入即可。
2. **建筑 / 远景**：`res://maps/assets/buildings/`（`RealAssetKit.EXTRA_ROOTS`）、`res://maps/assets/backdrops/`（`<track_id>.png`，菜单 / 开场按同名读取）。
3. **Poly Haven 库**：`res://maps/assets/polyhaven/`（`PbrAssets.ROOT`；菜单 HDRI 由 `scripts/core/main.gd` 直接引用）。
4. **都会环线**：`res://maps/assets/city_ring/`：
   - `city_ring.glb`（场景）、`facades/`（楼体贴图）、`city_collision.bin`（源数据）；
   - `city_collision.res` 由 `tools/bake_city_collision.tscn` 生成，是运行时首选。
5. **BGM**：`res://maps/audio/bgm/`，`data/bgm_manifest.json` 的 `file` 字段为 `bgm/<id>.ogg`；`AudioManager.AUDIO_ROOT = res://maps/audio`。

## 数据输入（由 GameData 解析）

`data/tracks.json`、`data/ai.json`、`data/bgm_manifest.json`、`data/decor/<track>.json`（装饰烘焙数据，编辑器使用）。

## 碰撞数据管线

```bash
# GLB 里有落地墙、但 SDF 漏掉的城市楼体：把轮廓补进 bin（幂等，可先 --dry-run）
python3 tools/patch_city_collision.py --dry-run
python3 tools/patch_city_collision.py

# 手动烘焙（export.sh 会在 bin 更新时自动执行）
Godot --headless --path . res://tools/bake_city_collision.tscn
```

`tools/patch_city_collision.py` 只补「有落地墙三角形、离都会环线中心线超过 12m」的轮廓，paved 位图不动；补完必须重烘 `.res` 才生效。

`tools/export.sh` 在每次 macOS / Windows 导出后，会用临时工程挂载 PCK 并校验 `city_collision.res` 存在且可读；缺失直接失败，避免发布“城市无碰撞”的包。`.res` 内嵌 `maps/scripts/openworld/city_collision_data.gd` 的脚本路径，改脚本路径后必须重烘（export.sh 已把脚本 mtime 纳入过期判断）。

## 菜单场景预烘焙

`assets/menu_scenes/*.scn` 由地图烘焙而成（`main.gd` 的 `--bake-menu`）。改动场景后必须**窗口模式**重烘：

```bash
Godot --path . --rendering-driver metal -- --bake-menu
# 只烘一张图（避免重烘其余场景）：
Godot --path . --rendering-driver metal -- --bake-menu=drift
```

headless 会丢失 MultiMesh 变换，禁止用 headless 烘焙。

## 允许的依赖方向

- 可以：`GameData` / `Settings`（autoload）、core 音频（BGM 播放）。
- 禁止：引用 `cars/` 的任何脚本；车辆接入统一在 `scripts/core/main.gd` 完成，车辆只通过 `TrackPath` 与世界查询接口读取地图。
- 本模块不拥有 UI；菜单缩略图 / 背景由 `scripts/ui` 读取 `maps/assets/backdrops/`。

## 验证

```bash
# 实机截图（必须窗口模式、绝对 --path）
Godot --path /Users/tong/Desktop/极速巅峰 -- --shot=/tmp/maps_race.png --shot-scene=race --track=metro

# 性能回归（输出 [QUALITY]/[PERF]）
Godot --path /Users/tong/Desktop/极速巅峰 -- --perf-test --track=metro --quality=high
```
