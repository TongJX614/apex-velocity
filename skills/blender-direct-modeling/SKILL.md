# Skill · Blender 直接建模（无头 bpy 流水线）

> 用途：用 Blender 的 Python API 直接建 3D 资产（真实场地/建筑/道具/树木），
> 导出 GLB，导入 Godot 替换程序化场景。无需打开 GUI，全程可脚本化、可复现、可进版本库。

## 0. 环境

```bash
# 安装（一次性）
curl -fL -o /tmp/blender.dmg "https://download.blender.org/release/Blender5.2/blender-5.2.3-macos-arm64.dmg"
hdiutil attach /tmp/blender.dmg -nobrowse -mountpoint /tmp/blender_mnt
cp -R /tmp/blender_mnt/Blender.app "$HOME/Applications/"
hdiutil detach /tmp/blender_mnt

# 验证
"$HOME/Applications/Blender.app/Contents/MacOS/Blender" --version
```

> 备选方案（已调研）：[mcp-for-blender](https://github.com/ahujasid/mcp-for-blender)
> 提供 GUI 内实时控制（socket/MCP）。本项目采用**无头 bpy 脚本**，理由是：
> 产物可复现、可 diff（脚本进仓库）、CI 可跑、不需要开着 GUI；需要人工实时调整时再接 MCP。

## 1. 建模脚本规范

脚本放 `tools/blender/`，用 `bpy` 从零建网格（不依赖 .blend 二进制资产）：

```bash
"$HOME/Applications/Blender.app/Contents/MacOS/Blender" --background --factory-startup \
  --python "tools/blender/build_venue_kit.py"
```

- **单位**：真实米制，Blender Z 轴朝上（glTF 导出自动转 Y-up）。
- **原点**：拾取中心落在地面 (0,0,0)，正前方朝向 +Y（导出后在 Godot 里再校验朝向）。
- **材质命名**（Godot 端按名字换色/加发光）：
  `VenueConcrete` / `VenueMetal` / `VenueDark` / `VenueSeat` / `VenueAccent` /
  `VenueGlass` / `VenueEmissive` / `VenueTyre` / `VenueAsphalt` / `VenueGrass`。
- **预算**：重复道具 ≤ 3k tris；大型建筑 ≤ 25k tris；单文件 ≤ 4 个材质。
- **导出**：`bpy.ops.export_scene.gltf(export_format='GLB', use_selection=True,
  export_apply=True, export_yup=True)` → `assets/venues/<name>.glb`。
- **清单**：同目录写 `manifest`（尺寸/锚点/推荐间距），Godot 端 `VenueKit` 读取摆放。

## 2. Godot 接入规范

- `scripts/tracks/venue_kit.gd`：加载 `assets/venues/*.glb`，按赛道样条摆放：
  主看台沿最长直道、维修区建筑在对面、龙门架跨起跑线、广告牌/灯柱/轮胎墙按间距重复。
- 重复道具用 **MultiMesh**（每个 MeshInstance 子节点一个 MultiMesh = 1 draw call/类），
  大建筑用场景实例。
- 材质换色：`VenueKit._tint(mat)` 按材质名把主色替换成赛道主题色（座位=主题色，发光=accent）。
- 导入后必须跑：`--import`、`--verify`、`--shot` 截图检查，再更新 docs 截图。

## 3. 质量检查清单

- [ ] GLB 导入 Godot 无 warning/error（`--import` 日志）
- [ ] 尺寸/朝向正确（截图对比赛道）
- [ ] 不穿模：看台/维修区离护栏 ≥ 8m，龙门架不压车
- [ ] 性能：`--perf-test` 仍 ≥ 60fps（目标 ≥ 120fps）
- [ ] 三视角截图（追尾/侧视/远景）确认没有悬空、共面 z-fighting

## 4. 已产出资产

见 `assets/venues/`（龙门架、主看台、维修区建筑、灯柱、广告牌、轮胎墙、护栏网、大屏幕、
裁判亭、树木）。生成脚本在 `tools/blender/`。
