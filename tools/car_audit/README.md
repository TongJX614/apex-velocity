# tools/car_audit — 车模基线审计 / 截图工具

APEX VELOCITY（极速巅峰）车模升级项目的**可复现审计与实拍基线**工具集。
升级前基线快照：`/tmp/car_baseline/`（45 台 garage + menu/race 实拍、审计 JSON/TXT、逐车 CSV、sha256 清单）。

## 文件

| 文件 | 用途 |
|---|---|
| `audit_car_models.gd` | 主审计：`--headless --script`，不依赖 autoload，逐台审计 45 个 GLB |
| `probe_material_props.gd` | 单材质深度探针；`--direct` 可绕过 `.godot` 导入缓存，对比「源 GLB vs 导入结果」 |
| `capture_baseline_shots.sh` | 批量截图驱动：顺序跑游戏自带 `--shot` 模式，含看门狗与日志（支持 `GARAGE=0`/`TRACK=coast`） |
| `compare_audit.py` | 新旧审计 JSON 对比：tris/材质/透明面/车漆贴图/轮子/AABB 逐台 diff，输出 markdown |
| `runtime_probe.gd` + `runtime_probe.tscn` | **场景模式**运行时探针：走真实 `CarVisual.build` 车库路径，验证轮节点/fallback/运行时车漆贴图+clearcoat |
| `runtime_probe.sh` | 运行时探针驱动：场景探针 + 游戏 headless garage 探针 + 告警汇总 `runtime_errors.log` |
| `make_compare_montage.py` | 新旧车库截图左右拼图（需要带 PIL 的 python3） |
| `parts_check.sh` | 配件库实拍验证：改用户存档（车漆/轮毂/轮胎/尾翼/卡钳）→ 车库截图 → **trap 还原存档并校验 sha256** |
| `install_new_models.sh` | 按 batch_report 装新 GLB：只装 ok 且无结构/r 偏差超标；跳过项保留旧版；装前备份 + sha256 校验 |
| `build_after_report.py` | 汇总 task-4 验收报告（安装/审计 diff/runtime probe/截图/异常清单 → /tmp/car_after/report.md） |
| `make_contact_sheet.py` | 截图相册（缩略图网格，快速扫 45 台车的玻璃/破面/材质） |

## 审计用法

```bash
# 项目根执行；建议先确保资源导入完成
/Users/tong/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --editor --quit

/Users/tong/Applications/Godot.app/Contents/MacOS/Godot --headless --path . \
  --script res://tools/car_audit/audit_car_models.gd
```

可选参数（放在 `--` 之后）：

```
--out-report=/tmp/car_audit_report.txt   人读报告
--out-json=/tmp/car_audit.json           机读 JSON
--manifest=res://data/car_manifest.json  车辆索引（默认，直接 FileAccess 读取）
--cars-dir=res://assets/cars/models      GLB 目录
```

审计内容：

- 加载/实例化、`rootName` 匹配（导入场景根 + 子树 `CarRoot` 双层判断）
- 期望节点：`Wheel_FL/FR/RL/RR`、`Spin_Wheel_*`、`SteerPivot`、`WingMount`（含模糊命名记录）
- 车轮：Spin 轴心 vs 轮几何中心偏移、轮半径（与 manifest `wheelRadius` 对比）、轮几何尺寸
- 模型 AABB：X/Z 居中、Y min≈0
- 计数：nodes / meshes / surfaces / triangles / 材质名种类
- 材质：名字、albedo_color、albedo_texture（存在性/内嵌判定）、metallic、roughness、
  transparency 枚举、cull_mode、clearcoat、emission、cast_shadow
- **源 GLB 交叉核对**：直接解析 GLB 的 JSON chunk（绕过 Godot 导入缓存）→ `alphaMode`、`KHR_materials_clearcoat`、
  `doubleSided`、extras（真实车长/三角面数/车头方向）、生成器；并标出「源 vs 导入」不一致项
- 异常汇总：透明材质 / depth-prepass、纯白无贴图（区分车漆命名 / 非车漆命名）、玻璃、
  clearcoat 丢失、贴图缺失、pivot 偏移、轮半径偏差、AABB 偏轴、cast_shadow、节点缺失等

输出：`/tmp/car_audit_report.txt`（人读）+ `/tmp/car_audit.json`（机读，含每台车全部材质与源 GLB 明细）。

单材质探针：

```bash
/Users/tong/Applications/Godot.app/Contents/MacOS/Godot --headless --path . \
  --script res://tools/car_audit/probe_material_props.gd -- --car=bmw_i8 --match=CarPaint
# --direct 绕过导入缓存；--all 打印全部材质
```

## 截图用法

```bash
# 默认：45 台 garage + menu/race 各 2 张 → /tmp/car_baseline
bash tools/car_audit/capture_baseline_shots.sh
# 升级后：输出到 /tmp/car_after
bash tools/car_audit/capture_baseline_shots.sh /tmp/car_after
```

可用环境变量：`GODOT`（Godot 路径）、`PROJECT`（项目根）、`OUT_DIR`（输出目录）、
`TIMEOUT`（单张看门狗秒数，默认 120）、`EXTRAS`（额外场景，默认 `menu:…,race:…`，格式 `scene:car`）。

截图走 `main.gd` 的 `--shot` 模式（参数需放在 Godot 的 `--` 之后）：

```bash
/Users/tong/Applications/Godot.app/Contents/MacOS/Godot --path . --rendering-driver metal -- \
  --shot=/tmp/car_after/garage_bmw_i8.png --shot-scene=garage --car=bmw_i8
```

输出：`OUT_DIR/garage_<id>.png`、`OUT_DIR/{menu,race}_<id>.png`，日志 `OUT_DIR/screenshots.log` 与
`OUT_DIR/_logs/<scene>_<id>.log`。

## 升级后对比 / 运行时验证

```bash
# 1) 审计 after（不要覆盖 /tmp/car_audit.json 基线）
Godot --headless --path . --script res://tools/car_audit/audit_car_models.gd \
  -- --out-report=/tmp/car_audit_after_report.txt --out-json=/tmp/car_audit_after.json

# 2) 新旧审计对比（旧侧建议用 /tmp/car_audit_baseline_v2.json，含车漆贴图统计）
python3 tools/car_audit/compare_audit.py \
  --old /tmp/car_audit_baseline_v2.json --new /tmp/car_audit_after.json \
  --out /tmp/car_after/report.md \
  --json-out /tmp/car_after/audit_diff.json \
  --keep-old hyundai_elantra

# 3) 运行时探针（必须用场景运行；--script 模式没有 autoload，CarVisual 编译不过）
bash tools/car_audit/runtime_probe.sh /tmp/car_after

# 3b) 配件库实拍（只改存档副本，跑完 trap 还原用户存档）
bash tools/car_audit/parts_check.sh /tmp/car_after/parts

# 3c) 安装（先 dry-run 看决策，再正式装）
bash tools/car_audit/install_new_models.sh --dry-run
bash tools/car_audit/install_new_models.sh

# 4) 截图 + 拼图
bash tools/car_audit/capture_baseline_shots.sh /tmp/car_after
/Users/tong/.dsh/dsh-runtimes/dsh-primary-runtime/dependencies/python/bin/python3 \
  tools/car_audit/make_compare_montage.py --old-dir /tmp/car_baseline --new-dir /tmp/car_after \
  --ids bmw_m3_e46_gtr bmw_i8 xiaomi_su7 lambo_urus buick_gl8 hyundai_elantra --out-dir /tmp/car_after
```

runtime_probe 额外产物（对应验收项 2/3/4）：

- `wheel_roll_check.txt`：每台每个 Spin_Wheel 的 AABB 中心距 spin 原点、y/z 尺寸比、顶点 PCA 最薄轴 vs X 夹角；
- `wheel_steer_check.txt`：Wheel_FL/FR rotation.y=0.35 前后轮组 AABB 变化、后轮 Spin 是否误挂前轮 steer 下；
- `parts_check.txt`：内存配置 paint=1/wheel=2/tire=2/wing=1/caliper=1 走 GarageLook.apply，测程序化轮是否 4/4 装上、
  原厂轮是否全部隐藏、GT 尾翼是否挂上且原厂尾翼隐藏、`_factory_wheel_width` 与轮几何宽度偏差。

对比口径要点：

- **透明/玻璃 surface**：静态审计数=导入后 `transparency != 0` 的 surface；运行时 `CarVisual._prepare_car_materials`
  还会按名字把玻璃材质也转半透，所以 runtime 数可能比静态多（正常）。
- **车漆贴图**：静态 `paint_textured_surfaces / paint_named_surfaces`；0 个带贴图 = 原厂漆/拉花丢失，
  运行时 `apply_paint(原厂漆路径)` 会走调色板兜底色（`runtime_probe` 会列出无贴图材质名）。
- **clearcoat**：Godot 4.7.2 不导入 glTF clearcoat 扩展（静态 `clearcoat_imported=0` 是预期），
  Lead 已在 `car_visual.gd` 运行时对车漆材质补 `clearcoat_enabled`（`runtime_probe` 的 `paint_runtime_clearcoat` 应为正数）。
- **内嵌贴图**：新 GLB 用内嵌贴图，审计里唯一贴图文件数/`textured_surfaces` 与旧库外部 png 的差异属正常。

## 注意事项

- **不要在项目根直接删除/移动任何现有文件**；本工具只读项目和写 `/tmp`。
- 升级前基线是在**冻结副本**上采集的（项目外备份 + `/tmp/proj_oldlight`）：因为 Lead 从 20:14 起开始替换
  `assets/cars/models/*.glb`，而车库打光同时被另一位 teammate 修改。复现旧基线时请在冻结副本/旧备份上跑。
- 车库截图受 `scripts/ui/garage_world.gd` 打光影响；跨轮对比请保持同一打光版本，或只比较模型几何/材质。
- `transparency=4 (ALPHA_DEPTH_PRE_PASS)` 是 Godot glTF 导入 `alphaMode=BLEND` 的默认结果，
  审计会单独列出，便于确认「透明材质是否只剩玻璃」。
