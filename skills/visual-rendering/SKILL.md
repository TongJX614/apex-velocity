# Skill · Godot 4 赛车画面调优（APEX VELOCITY）

面向本项目 3D 画面的可复用调优流程：先拍基线、再小步改材质/灯光、每步用同机位截图和
`--perf-test` 回归。目标不是无脑堆效果，而是在「已拍板的夜景亮度 + 稳定帧率」前提下提升质感。

## 何时使用

- 菜单/车库展厅看起来「平」、车漆发塑料、背景抢主体；
- 赛道沥青像一张均匀贴图、路肩/护栏像纯色平板；
- 想加 SSR / SDFGI / SSIL / DOF / 积水 / 车漆清漆，但不确定性能与观感收益；
- 需要对比改动前后，或排查「改了全局曝光导致夜景变暗」类回归。

## 先拍基线（必须窗口模式）

```bash
GODOT=~/Applications/Godot.app/Contents/MacOS/Godot
mkdir -p /tmp/apex_shots

# 菜单（--shot-delay=N 让展车多转 N 秒再拍；计时从装饰完成起算，低帧率下转角/扫光相位也稳定）
"$GODOT" --path "$PWD" --resolution 1600x900 -- \
  --shot=/tmp/apex_shots/menu_city.png --shot-scene=menu --track=city --shot-delay=12

# 比赛（--shot-dist 把车放到赛道中段，避免每张都停在起跑线）
"$GODOT" --path "$PWD" --resolution 1600x900 -- \
  --shot=/tmp/apex_shots/race_city.png --shot-scene=race --track=city \
  --car=bmw_m3_e46_gtr --shot-dist=35
```

- **不要用 `--headless` 做视觉/穿模审计**：headless 下 MultiMesh 变换读回是 identity，
  会得到大量假阳性。视觉审计与 `--verify` 都用窗口模式。
- 截图用绝对 `--path`，避免启动器把相对路径解析到别处。

## 视觉审计清单

### 菜单 / 展厅

1. 车漆是否只是纯色高光：检查 `cars/scripts/car_visual.gd` 的 `apply_paint`
   （clearcoat + rim 是否生效）。
2. 车与地面是否「浮着」：看 `GarageWorld` 的接触阴影 / `CarVisual._build_blob_shadow`。
3. 静态展厅是否关掉了 SSR：`main.gd` `_decorate_menu_scene` 里高/超高可以重开，
   菜单相机固定 + FXAA，不会出现比赛里的时间重投影抖动。
4. 背景是否抢主体：`_apply_menu_camera_attributes` 的轻 DOF（远距 30m 起步、amount ≈ 0.02）。
5. 车漆高光是否过曝：先看主题 `exposure` / 菜单 `expo_mul`，再动车漆 roughness。
   警告：不要为了修菜单车漆去改 `city` 的 emission / 路灯 / facade 拍板值。
6. 展车「贴上去」感：烘焙场景里那盏无名 SpotLight3D（旧车棚主光 energy 7）
   在 `_decorate_menu_scene` 里被压到 ≤1.4 并染成太阳色；比赛复用菜单世界时
   `_bind_world_environment` 直接隐藏全部烘焙 SpotLight3D。运行时辅助光
   （key/rim/fill/kicker/车底 Omni）按平方反比标能量：8~10m 距离个位数能量
   几乎不可见，但几十的能量会把清漆高光打成死白、在地面留下影棚光池。
   现值：key 7（白天）/15.5（暗主题）/13（夜城相机侧暖光），rim 4/9.5/7、
   fill 2.5/6/5、kicker 5.5/12/8.5，车底 Omni 白天 0.13、key 锥角 38° 收光池。
   key 方向对齐场景太阳（`Sun.basis.z`），夜城改为相机侧暖光，保证车与
   环境同一套光影逻辑。
7. 亮色车漆「炫光」与镜壳死白光球：白漆在补光下容易被推过泛光阈值，车头糊成
   一团白；深色车漆上则表现为镜壳/A 柱一颗死白光球，看起来像「换车地图亮度
   不同」（实测地图远场亮度与车无关，差的是车漆+光晕）。三道闸：
   辅助灯能量只到「读懂车形」的量级（上一节）；菜单 `glow_hdr_threshold`
   抬到 2.6；所有补光与烘焙灯 `light_specular = 0`。
   光球根因是烘焙街灯 Omni 的镜面镜像：玻璃粗糙度近 0，镜像点 HDR 几十，
   湿路掠射再铺成整片暖光池，specular 留 10% 都仍过阈值，只能归零；湿地反光
   交给 SSR 与霓虹自发光。烘焙旧车底 Omni 与运行时新灯叠加也要钳（车身 3m
   内 energy ≤ 0.35）。排查顺序：`APEX_Q_MENU_GLOW=0` 确认泛光只是放大器 →
   看 bloom-off 原图找 HDR 源（光池/镜像点）→ 逐类灯关 specular 定位。
   车漆清漆粗糙度 0.09（0.02 纯镜面，太阳/天空反光会烧成移动死白斑）。
   对比截图必须同转角：菜单 shot ready 走墙钟（`_shot_wall`），且 45 帧下限
   在慢机（<3.5fps）会晚于墙钟、拍出不同转角/扫光相位；帧数下限已压到 12
   帧纯预热。两个时钟（自转角度、轮廓扫光 `_menu_sweep_t`）在
   `_instantiate_menu_scene` 末尾同点归零。仍有噪声源：菜单轮廓扫光
   （11.4s 周期，地面光池跟着移动，单次拍完隔 2s 重拍差异可达 4%）与
   雨滴随机种子——判「车与地图亮度」时只比同批连拍的读数，或先看
   地面环形区域是否逐车一致（0.0001 级）。

### 车库影棚

- `scripts/ui/garage_world.gd`：程序化 HDR 软盒天空（4 条 hero 长灯 + 2 条软灯 +
  顶棚 + 地面反弹），hero energy 12、暖白色；曝光 1.06、AGX。
- 地面/展台用深色哑光（albedo ≈ 0.045/0.032）且 `specular_mode = SPECULAR_DISABLED`：
  掠射角菲涅尔会把软盒天空整片镜反射成灰白圆盘，关材质高光才能压住。
- 车库 `env.ssr_enabled = false`：SSR miss 回退会反射天空 radiance，
  `specular_mode` 关不掉这条路径，灰白圆盘的根因是它。车漆长条高光来自
  软盒天空的环境反射，与 SSR 无关，关掉不损失车漆质感。
- 注意常量名是 `BaseMaterial3D.SPECULAR_DISABLED`（不是 SPECULAR_MODE_DISABLED）。

### 赛道

1. 路面平铺感：`maps/scripts/tracks/track_builder.gd`
   - `_build_road` 横向 8 段顶点色（中缝油渍、双轮磨痕、路缘积灰）；
   - `_apply_road_detail` 用 UV2 + 46m 宏观噪声，打散 8m 贴图重复。
2. 湿路/夜赛：`_build_puddles` 用 Decal（低粗糙度 ORM + 细法线）吃引擎 SSR；
   只在 high/ultra 且 `weather=rain` / 夜城主题生成。
3. 路肩：`_build_kerbs` 内缘橡胶暗带 + 混凝土法线/粗糙度 + 侧立面。
4. 护栏：`_build_guardrail` W 形五段截面 + 金属法线/粗糙度（只取贴图，不用暗色 albedo）；
   每 14m 一颗反光片（1 个 MultiMesh draw call），夜景弯道可读性明显提升。
5. 车底接触：`CarVisual._blob_shadow_texture` 车形软阴影 + 四轮接地点。
6. 远景地形：`_build_hill_mesh` 给每个顶点写低频噪声 + 坡度顶点色，
   草坡偏暖、陡坎压暗、雪面轻微明暗；对应材质必须开
   `vertex_color_use_as_albedo`，否则颜色不生效。

### 车漆 / 夜间可读性

- 原厂漆保留贴图/拉花；运行时补 clearcoat（1.0 / roughness 0.02）。
- `rim` 只加很低的菲涅尔边缘光（0.11 左右），避免变成描边。
- 夜间玩家车额外一盏 `NightRim` Omni（`CarVisual.add_night_rim`）：
  range ≈ 4.8m、energy ≈ 1.15、无阴影，只勾车顶/尾翼/后肩，不照亮远处场景。
- 不要在干燥晴天主题强行开 SSR：路面会像刚下过雨，观感错误。
- 尾灯：`shaders/car_tail_glow.gdshader` 作为车灯材质的 `next_pass`，只对贴图中
  「红色主导」的像素叠自发光，白色前灯/转向灯不参与；不要整组灯一起开 emission。
- 车体统一渲染层 2（`CarVisual.set_render_layer`），主相机默认全层可见；
  菜单反射探针用 `cull_mask=1 + interior=false`，只反射环境、不把车自己拍进漆面。
- 比赛跟随反射探针 `CarReflectionProbe` 在高/超高默认开启：box_projection
  跟随玩家车、`cull_mask=1` 只反射环境，每 3s 重绘一次且车速 <3km/h 跳过，
   coast 车漆可见地平线反射带、夜城车漆吃霓虹。`APEX_Q_CAR_PROBE=0` 关闭做 A/B。
- 实时胎印：`scripts/fx/skid_marks.gd`，漂移/手刹/重刹时写入 160 实例 MultiMesh，
  只占一个 draw call；贴图软边、环形覆盖旧印，不做逐帧透明更新。

### 天气 / 雨夜氛围

- `scripts/core/weather_fx.gd`：
  - 雨丝用 16×128 软边贴图 + `shaders/rain_streak.gdshader` 自定义 billboard，
    在离镜头 1.5~4m 内淡出到 0；这是解决「追尾相机贴脸大白条」的关键，
    不要退回 StandardMaterial3D；
  - 雨体积沿车头前移 26m 并跟随车头旋转，雨粒子 `local_coords=true`；
  - `_spawn_rain_splashes` 挂到跟随目标（车/展车）上，铺在车周围；
  - `_spawn_rain_spray` 挂在车尾，>28km/h 才喷水雾；
  - 菜单 `main._add_menu_weather` 复用同一套天气，但雨量降到 900、雨丝缩到 0.5m。
- 雨量参考：赛道 6500 粒子（ULTRA），菜单 900；地面溅水 220 / 90。
- 雨夜会增加约 5% GPU 开销，属于可接受范围；`APEX_Q_WEATHER_OFF=1` 可整体关天气做 A/B。

### 辉光 / 镜头脏污

- `Environment.glow_map` 用程序化低频噪声生成「镜头脏污」，让霓虹/路灯 bloom
  带一点不规则污渍；`glow_map_strength` 保持 0.2~0.35，不要压暗已拍板的城市夜景。
- `APEX_Q_GLOW_MAP=0` 可关闭做 A/B；实测开/关帧率差异在噪声内。

### 色调映射

- 默认 ACES。A/B 实测 AgX（`APEX_Q_AGX=1`）在海岸/峡谷会明显发灰、丢饱和，
  只适合高光滚降有问题的车型特写，不要直接替换比赛色调。

## A/B 开关（排查用）

| 开关 | 作用 |
| --- | --- |
| `APEX_Q_SDFGI=0/1` | 强制关/开 SDFGI（默认只保留代码能力，不开） |
| `APEX_Q_THEME_SSR=0/1` | 强制关/开当前主题的 SSR |
| `APEX_Q_WEATHER_OFF=1` | 关闭全部天气粒子，排查雨丝/溅水问题 |
| `APEX_Q_CAR_PROBE=0/1` | 强制关/开玩家车跟随反射探针（高/超高默认开） |
| `APEX_Q_GLOW_MAP=0` | 关闭镜头脏污 glow map |
| `APEX_Q_RAIN_STREAKS_OFF=1` / `APEX_Q_RAIN_SPLASH_OFF=1` / `APEX_Q_RAIN_SPRAY_OFF=1` | 单独关闭雨丝/地面溅水/车尾水雾 |
| `APEX_Q_GRADE=0` | 关闭逐图电影调色，看原始色 |
| `APEX_Q_MENU_GLOW=0` / `APEX_Q_MENU_SSR=0` / `APEX_Q_SUN_GLARE=0` / `APEX_Q_MENU_PROBE=0` | 菜单环境单项关闭：泛光/SSR/太阳眩光/反射探针 |
| `APEX_Q_PAINT_CC=0` / `=flat` | 车漆清漆关闭 / 镜面（0.03）对比，默认 0.09 |
| `APEX_PERF_OVERRIDE=1` + `APEX_Q_SSIL/Q_SSAO/Q_VOL/Q_TAA` | 性能审计时单独开关后处理 |

## 性能基线（本机 1600×900 / ULTRA / Retina 0.7 渲染比例）

| 场景 | fps | draw calls |
| --- | --- | --- |
| coast | ≈ 171 | 789 |
| city（含雨） | ≈ 111 | 1019 |

> 测帧前先确认没有其它 Godot/GPU 任务在跑；本机曾因一个 100% CPU 的 headless
> 测试进程把 city 从 111fps 压到 76fps。glow map 单独 A/B 为 99.4 vs 97.7fps，
> 差异在噪声内，改动本身没有明显开销。

实测代价（city / ULTRA）：
- SDFGI：104.5 → 78.8 fps（约 -25%），城市还会整体提亮，**默认关闭**；
- SSIL：82.5 → 76.3 fps（约 -7.5%，同 `APEX_PERF_OVERRIDE` 条件下），默认关闭；
- 干地主题强开 SSR：路面变湿，**不默认开**；
- 雨夜 5200 雨丝 + 溅水 + 车尾水雾：106 → 101 fps（约 -5%），保留；
- 本次路面/路肩/护栏/车漆/菜单 SSR+DOF 全套：帧率基本持平（coast 147.9→147.8）。
- 跟随反射探针（high 预设 A/B）：coast 139.0→140.5、city 114.8→114.8 fps，
  差异在噪声内（3s 间隔 + 静止跳过把 6 面重绘摊薄），高/超高默认开。

## 已知约束

- 霓虹都市夜景是用户拍板值：模型 emission、路灯能量、facade emission 不要动；
  如画面整体变暗，先查全局曝光/菜单 `expo_mul`，不要回头改这组数字。
- 不要在运行时逐帧生成路面噪点纹理（高速会闪成马赛克）；宏观细节必须走
  mipmap + 各向异性 + 低频噪声。
- 车模 GLB 的 `KHR_materials_clearcoat` 导入后不会自动生效，运行时补开。
- 加灯前先算「每车灯数」：玩家 1 盏 NightRim 可以，4 台 AI 各加一盏要重新测帧率。

## 参考来源（GitHub / 官方）

- Godot Environment / SDFGI / SSR / SSIL / DOF 官方文档
- gdquest-demos/godot-shaders：https://github.com/gdquest-demos/godot-shaders
- daniel-ilett/shaders-godot：https://github.com/daniel-ilett/shaders-godot
- marcelb/GodotSSRWater（透明物体 SSR 思路）：https://github.com/marcelb/GodotSSRWater
- KorinDev/Godot-Post-Process-Plugin（后处理参考）：https://github.com/KorinDev/Godot-Post-Process-Plugin
- egore/openstreetmap-racer（Godot 4 驾驶游戏，SSR 车漆/湿路 + ACES + DOF）：
  https://github.com/egore/openstreetmap-racer
- Khronos glTF ClearCoatCarPaint 样例（车漆清漆验证）：
  https://github.com/KhronosGroup/glTF-Sample-Assets
- Poly Haven CC0 PBR 贴图（沥青/混凝土/金属，本项目已用）：
  https://polyhaven.com/textures
- TokisanGames/Terrain3D（后续赛道高细节地形备选）：https://github.com/TokisanGames/Terrain3D