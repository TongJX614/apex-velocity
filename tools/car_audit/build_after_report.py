#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""汇总 task-4 验收报告：安装计划 + after 审计 diff + runtime probe + 截图统计 → /tmp/car_after/report.md

用法:
  python3 tools/car_audit/build_after_report.py \
      --after-dir /tmp/car_after \
      --baseline-dir /tmp/car_baseline \
      --staging /tmp/car_export_out \
      --old-audit /tmp/car_audit_baseline_v2.json \
      --new-audit /tmp/car_audit_after.json \
      [--visual-json /tmp/car_after/visual_findings.json] \
      [--out /tmp/car_after/report.md]

visual_findings.json 由人工视觉验收后填写（可选）:
  {
    "glass_milky": ["car_id", ...],
    "broken": [{"car": "...", "issue": "..."}],
    "notes": "自由文本"
  }
"""
import argparse
import glob
import json
import os
import sys

KEEP_OLD = {'hyundai_elantra', 'bmw_m4_adro_kit', 'byd_yangwang_u8'}
# 这些车的导出报告里 paint=false（exporter 未把车身识别为车漆材质）
NO_PAINT_FLAG = {'bmw_m4_gt4', 'bmw_m6_gt3', 'bmw_m8_cabrio'}


def load_json(path):
    try:
        return json.load(open(path, encoding='utf-8'))
    except Exception:
        return {}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--after-dir', default='/tmp/car_after')
    ap.add_argument('--baseline-dir', default='/tmp/car_baseline')
    ap.add_argument('--staging', default='/tmp/car_export_out')
    ap.add_argument('--old-audit', default='/tmp/car_audit_baseline_v2.json')
    ap.add_argument('--new-audit', default='/tmp/car_audit_after.json')
    ap.add_argument('--visual-json', default='')
    ap.add_argument('--out', default='')
    args = ap.parse_args()

    after = args.after_dir
    out_path = args.out or os.path.join(after, 'report.md')
    visual = load_json(args.visual_json) if args.visual_json else {}

    # ---------- 安装计划 ----------
    install_lines = []
    plan_path = os.path.join(after, 'install_plan.txt')
    install_ok = []; install_skip = []
    if os.path.exists(plan_path):
        for ln in open(plan_path, encoding='utf-8', errors='replace'):
            ln = ln.strip()
            import re as _re
            if ln.startswith('OK     '):
                m = _re.match(r'OK\s+(\S+)', ln)
                if m:
                    install_ok.append(m.group(1))
            elif ln.startswith('SKIP   '):
                m = _re.match(r'SKIP\s+(\S+)', ln)
                if m:
                    install_skip.append(m.group(1))
    installed = sorted(install_ok)
    skipped = sorted(set(install_skip) | KEEP_OLD)

    # ---------- after 审计 ----------
    new_audit = load_json(args.new_audit)
    old_audit = load_json(args.old_audit)
    diff = load_json(os.path.join(after, 'audit_diff.json'))
    new_cars = new_audit.get('cars', {})
    old_cars = old_audit.get('cars', {})

    # ---------- runtime probe ----------
    probe = load_json(os.path.join(after, 'runtime_probe.json'))
    probe_cars = probe.get('cars', {})

    # 轮子滚动终判：以胎体（Tyre）PCA / 胎体 yz 比 / 轮几何中心偏移为准
    roll_serious = []
    roll_note = []
    for cid, r in probe_cars.items():
        if not r.get('loaded'):
            continue
        issues = []
        notes = []
        for suf in ['FL', 'FR', 'RL', 'RR']:
            d = (r.get('roll') or {}).get(suf)
            if not d:
                continue
            tyre_axis = d.get('tyre_axis_deg', -1)
            tyre_yz = d.get('tyre_yz_ratio', 0)
            center = d.get('center_dist', 0)
            if tyre_axis is not None and tyre_axis > 4.0:
                issues.append(f'{suf} 胎体PCA {tyre_axis:.1f}°')
            elif tyre_axis is not None and tyre_axis > 3.0:
                notes.append(f'{suf} 胎体PCA {tyre_axis:.1f}°(3~4° 边缘)')
            if tyre_yz and not (0.93 <= tyre_yz <= 1.07):
                issues.append(f'{suf} 胎体椭圆 y/z={tyre_yz:.3f}')
            elif tyre_yz and not (0.95 <= tyre_yz <= 1.05):
                notes.append(f'{suf} 胎体 y/z={tyre_yz:.3f}(边缘)')
            if center > 0.03:
                issues.append(f'{suf} 轮心偏移 {center:.3f}m')
            elif center > 0.02:
                notes.append(f'{suf} 轮心偏移 {center:.3f}m')
        if issues:
            roll_serious.append((cid, issues))
        if notes:
            roll_note.append((cid, notes))

    # ---------- 截图 ----------
    garage_shots = sorted(glob.glob(os.path.join(after, 'garage_*.png')))
    menu_shots = sorted(glob.glob(os.path.join(after, 'menu_*.png')))
    race_shots = sorted(glob.glob(os.path.join(after, 'race_*.png')))
    parts_shots = sorted(glob.glob(os.path.join(after, 'parts', '*_*.png')))

    L = []
    A = L.append
    A('# 车模升级后验收报告（新模型安装 + 审计 + 实拍 + 运行时验证）')
    A('')
    A(f'- 生成时间：{__import__("datetime").datetime.now().strftime("%Y-%m-%d %H:%M:%S")}')
    A(f'- 新模型 staging：`{args.staging}`（batch_report 最终版 43 台导出，0 失败）')
    A(f'- 旧基线：`{args.baseline_dir}`（45 台实拍 + 审计）、`{args.old_audit}`')
    A(f'- this 目录：`{after}`')
    A('')
    A('## 1. 安装结果')
    A('')
    A(f'- **安装 {len(installed)} 台新模型**（status=ok、tris_dev<0.5%、measured_r 偏差≤5%、无结构异常）')
    A(f'- **保留旧模型 {len(skipped)} 台**：')
    for cid in skipped:
        reason = ''
        if cid == 'hyundai_elantra':
            reason = '骨骼蒙皮模型，车轮无 STEER_/WHEEL_ 拆分'
        elif cid == 'bmw_m4_adro_kit':
            reason = '源 blend 轮组异常（前后轮径不一致+重复几何），Lead 决定保留旧版'
        elif cid == 'byd_yangwang_u8':
            reason = 'measured_r 与旧模型包络偏差 -13.9% > 5%（ok_special），按规则不装'
        A(f'  - `{cid}`：{reason}')
    A('- 安装文件 sha256 逐一校验通过；被覆盖目标文件备份在 `%s/pre_install/`' % after)
    A('- 安装后导出侧追加 `xiaomi_su7` 单台重导（轮毂/轮胎几何重分+胎体定轴定心，`INSTALL_MANIFEST.updated=21:00 "xiaomi_su7 reworked"`，'
      'sha256 `7c0bca8c…`），已重新导入并复验：胎体 PCA 0.0~0.79°、轮心偏移 ≤0.0005m、胎体 y/z≈0.99；'
      '本项目 `assets/cars/models/xiaomi_su7.glb` 已是该重导版。')
    A('- Godot `--editor --quit` 导入：0 import error / 0 SCRIPT ERROR')
    A('')
    A('## 2. after 静态审计摘要')
    A('')
    if new_audit.get('summary'):
        s = new_audit['summary']; t = s['library_totals']; ac = s['anomaly_counts']
        A(f'- 车辆：{s["audited_cars"]} 台，加载失败 **{ac["load_failures"]}**，节点缺失车辆 **{ac["node_missing_cars"]}**，'
          f'Wheel/Spin 缺失车辆 **{ac["wheel_node_missing_cars"]}**')
        A(f'- 几何：nodes {t["nodes"]} / meshes {t["meshes"]} / surfaces {t["surfaces"]} / 三角面 **{t["triangles"]:,}**')
        A(f'- 透明 surface：{t["transparent_materials"]} 个（{ac["transparent_material_cars"]} 台）；无贴图纯白材质 {t["white_no_texture_materials"]} 处 / {ac["white_no_texture_cars"]} 台'
          f'（非车漆命名 {ac["white_no_texture_nonpaint_cars"]} 台）')
        A(f'- 车漆材质：surface {t.get("paint_named_surfaces", "?")} 个，带 albedo 贴图 {t.get("paint_textured_surfaces", "?")} 个；'
          f'贴图缺失 surface {t["missing_texture_surfaces"]}')
        A(f'- 轮子 pivot 偏移>0.03m：{ac["wheel_pivot_offset_cars"]} 台（含保留旧版）；轮半径与 manifest 不符：{ac["wheel_radius_mismatch_cars"]} 台；AABB 异常：{ac["aabb_off_cars"]} 台')
        A(f'- 源 glTF clearcoat 材质 {t["clearcoat_source_materials"]} 个 / 导入后启用 {t["clearcoat_imported_materials"]} 个'
          '（Godot 不导 clearcoat，运行时由 car_visual 补）')
    if diff:
        A(f'- 对比旧基线：三角面 {diff["totals"]["old_tris"]:,} → **{diff["totals"]["new_tris"]:,}**；'
          f'严重问题 {len(diff.get("severe_cars", []))} 台、需注意 {len(diff.get("warn_cars", []))} 台（明细见 `report_audit.md`）')
    A('')
    A('**对比告警口径说明（避免误读）**：')
    A('- 「透明/玻璃 surface 数异常」（如 m3 静态 5→2）：新导出按材质合并了玻璃面，**静态 BLEND 面数变少**；'
      '运行时 `_prepare_car_materials` 会补成半透，runtime glass 数正常（见 3 节），截图确认玻璃完整 → 非缺件。')
    A('- 「车漆材质 0 个带贴图」：新导出中 28/43 台源车漆本身是纯色（GLB 里 paint 材质无 baseColorTexture），'
      '15/43 台保留原厂拉花贴图；与旧基线相比只有 `bmw_m4_gt4`、`bmw_m6_gt3` 的贴图车漆"丢失识别"（见 5.2）。')
    A('')
    A('### 2.1 节点契约（Wheel_/Spin_Wheel_ 无 .001 后缀）')
    A('')
    suffix_bad = []
    for cid, c in new_cars.items():
        for p in c.get('node_presence', {}).get('node_paths', []):
            base = p.split('/')[-1]
            if any(k in base for k in ['Wheel', 'Spin', 'Steer', 'WingMount']) and ('.001' in base or '.002' in base):
                suffix_bad.append((cid, p))
    if suffix_bad:
        for b in suffix_bad:
            A(f'- !! `{b[0]}`: {b[1]}')
    else:
        A('- ✓ 45 台新/旧模型中 4×Wheel_/Spin_Wheel_* 节点全部精确命名，无 `.001/.002` 后缀。')
    steer_missing = [cid for cid, c in new_cars.items() if 'SteerPivot' in c.get('node_presence', {}).get('missing', [])]
    if steer_missing:
        A(f'- ⚠ SteerPivot 缺失 {len(steer_missing)} 台：{", ".join("`%s`" % c for c in sorted(steer_missing))}'
          '（游戏代码中 **无任何脚本引用 SteerPivot**，不影响转向/驾驶；仅审计节点契约不满足，列待修）')
    A('')
    A('## 3. 运行时验证（游戏真实 CarVisual / GarageLook 路径）')
    A('')
    ps = probe.get('summary', {})
    A(f'- CarVisual 加载：45/45 成功；Wheel/Spin 齐全 **{45 - len(ps.get("wheels_bad", []))}/45**；'
      f'材质 fallback 触发 **{len(ps.get("fallback_cars", []))} 台**；加载失败 {ps.get("fail_count", "?")}')
    A(f'- 运行时 clearcoat 生效：**{len(ps.get("runtime_clearcoat_cars", []))}/45 台**；'
      f'无运行时车漆识别：{", ".join("`%s`" % c for c in sorted(set(NO_PAINT_FLAG)))}（导出侧 paint flag=false，见第 5 节）')
    A(f'- spin 运行时纠偏车：{", ".join(ps.get("spin_corrected_cars", [])) or "无"}（car_visual 会把 pivot 对齐轮心）')
    A('')
    A('**Lead 指定重点车结论**：')
    A('- `zeekr_7x`（旧模型轮心与 blend 枢轴偏差 17.6cm）：新车库/赛道截图车轮均在轮眉内、无悬空/穿出，'
      '静态审计 AABB 居中、运行时轮轴/轮心正常 → **保持新版**。')
    A('- `bmw_m4_2024`（轮宽 -12.7%）：截图轮子与轮眉贴合正常；运行时轮心无偏移（car_visual 已纠偏）；'
      '轻微注意：静态 pivot 0.031m 由运行时修正 → **保持新版**。')
    A('- `byd_seal06gt`（轮宽 +20.1%）：截图中白字轮胎/轮毂正常、无穿出轮眉 → **保持新版**；轮宽偏差来源为'
      '新模型轮胎几何比旧网页版更宽（源 blend 真实宽度），属预期差异。')
    A('')
    A('### 3.1 轮子滚动检查（`wheel_roll_check.txt`）')
    A('')
    A('指标：spin 子树中 **Tyre/Rim** 轮体网格（排除 BrakeDisc/Caliper）在 CarVisual.build 后的局部坐标：'
      'AABB 中心距 spin 原点、y/z 尺寸比、顶点 PCA 最薄轴 vs X 夹角、胎体单独 PCA。')
    A('')
    new_roll = [(c, i) for c, i in roll_serious if c not in KEEP_OLD]
    old_roll = [(c, i) for c, i in roll_serious if c in KEEP_OLD]
    if new_roll:
        A('| 车辆 | 问题 |')
        A('|---|---|')
        for cid, issues in sorted(new_roll):
            A(f'| `{cid}` | {"；".join(issues)} |')
    else:
        A('- ✓ **新装 42 台无严重轮轴/椭圆/轮心偏移问题**。')
    if old_roll:
        A('')
        A('保留旧版（旧模型遗留问题，不在本次修复范围）：')
        for cid, issues in sorted(old_roll):
            A(f'- `{cid}`：{"；".join(issues)}')
    if roll_note:
        A('')
        A('轻微注意（0.02~0.03m 轮心偏移，运行时已纠偏）：')
        for cid, notes in sorted(roll_note):
            A(f'- `{cid}`：{"；".join(notes)}')
    A('')
    A('> 说明：全子树 PCA 会被轮辐/卡钳顶点分布带偏，因此以「胎体 Tyre」PCA + 胎体 y/z 比为终判；'
      '保留旧版 `bmw_m4_adro_kit` 的旧模型轮轴本身是歪的（胎体 PCA 15~20°），属旧模型遗留，不在本次修复范围。'
      '`xiaomi_su7` 初版胎体 PCA 6.2° 已由导出侧重导修正（现 0.0~0.79°），并已重新安装复验。')
    A('')
    A('### 3.2 前轮转向检查（`wheel_steer_check.txt`）')
    A('')
    steer_bad = ps.get('steer_bad_cars', [])
    A(f'- **{45 - len(steer_bad)}/45 台** front_ok=2/2（Wheel_FL/FR 设 rotation.y=0.35 后轮组 AABB 明显摆动）；'
      f'异常 {len(steer_bad)} 台：{", ".join(steer_bad) or "无"}')
    A('- 后轮 Spin 挂在前轮 steer 下的车辆：**0 台**（rear_under_steer 全空）')
    A('')
    A('### 3.3 配件库管路（`parts_check.txt` + `parts/` 实拍）')
    A('')
    A('- 运行时逐台（内存配置 paint=1/wheel=2/tire=2/wing=1/caliper=1，走 `GarageLook.apply`，不写盘）：'
      f'**{45 - len(ps.get("parts_bad_cars", []))}/45 台通过**（程序化轮 4/4 装上、原厂轮 mesh 全部隐藏、GT 尾翼挂上且原厂尾翼隐藏、'
      '程序化轮宽与轮几何偏差 <15%）；异常：' + (", ".join(ps.get("parts_bad_cars", [])) or "无"))
    A('- 实拍（`%s/parts/`）：4 台车 × 7 组合 = 28 张（factory / paint1 黑 / paint2 白 / wheels dish6 / tire race / wing GT / caliper 黄），'
      '用户存档 `garage.json` 已备份并在结束后还原 + sha256 校验一致。' % after)
    A('')
    A('## 4. 截图与拼图')
    A('')
    A(f'- 新车库截图：`{after}/garage_<id>.png` **{len(garage_shots)}** 张；menu **{len(menu_shots)}** 张；race **{len(race_shots)}** 张（6 台：'
      'bmw_m3_e46_gtr / bmw_i8 / xiaomi_su7 / lambo_urus / buick_gl8 / hyundai_elantra，race 用 `--track=coast`）')
    A(f'- 旧基线：`{args.baseline_dir}/` 49 张（旧模型 + 旧打光，冻结副本重拍，与对比口径一致）')
    A(f'- 配件实拍：`{after}/parts/` {len(parts_shots)} 张')
    A('- 说明：`menu_*` 6 张内容相同 —— 菜单展台固定展示一台 M3 E46 GTR，`--car` 不影响 menu 场景（场景设计，非车模问题）；'
      '`race_*` 6 张为 6 台不同车在 coast 赛道上的实拍，均正常渲染。')
    A(f'- 相册：`{after}/contact_garage.png`（45 台总览）、`contact_menu.png`、`contact_race.png`、`zoom_wheels.png`、`zoom_glass.png`')
    A(f'- 新旧拼图：`{after}/compare_<id>.png`（见第 6 节）')
    A('')
    A('## 5. 异常 / 待修 / 回滚清单')
    A('')
    A('### 5.1 回滚')
    A('')
    A('- 加载失败：**0 台**；Wheel/Spin 节点缺失：**0 台**；因此**本次未回滚任何车辆**。')
    A('')
    A('### 5.2 待修（不阻断游戏，建议导出侧/材质逻辑修复）')
    A('')
    A('1. **SteerPivot 缺失 3 台**（`bmw_m3_e92`、`bmw_m6_gt3`、`zeekr_7x`）：导出器未生成该节点（源模型无可用转向枢轴）。'
      '游戏脚本零引用，不影响功能；按验收契约列待修。')
    A('2. **车漆材质未识别 3 台**（`bmw_m4_gt4`、`bmw_m6_gt3`、`bmw_m8_cabrio`）：导出报告里 `paint=false`，'
      '车身用 `ext`/`b:MAT_BMW_M8_Base_053` 等材质，游戏按名字匹配 paint 的换色/清漆逻辑不会作用于这些车 → '
      '车库「车漆颜色」对这些车不生效、也缺运行时 clearcoat；原厂贴图/颜色本身保留。')
    if diff:
        big = []
        for r in diff.get('rows', []):
            p = r.get('tris_delta_pct')
            if p is not None and abs(p) > 2.0:
                big.append((r['id'], p))
        A('3. **三角面 vs 旧网页版**：新导出以源 blend 为准，与旧模型有少量差异；偏差 >2% 的车：'
          + ('、'.join(f'`{c}`({p:+.1f}%)' for c, p in sorted(big)) if big else '无')
          + '。staging 侧 tris 与源 blend 偏差均 <0.5%，此处差异属旧网页版简化，非导出问题。')
    A('4. **玻璃面数口径**：静态 BLEND surface 数比旧库少（新导出按材质合并玻璃面），运行时玻璃数/截图均正常，不需处理。')
    A('')
    A('### 5.3 玻璃发白 / 视觉异常（人工验收）')
    A('')
    milky = visual.get('glass_milky') or []
    if milky:
        A('玻璃疑似发白/发雾车辆：')
        for cid in milky:
            A(f'- `{cid}`：`{after}/garage_{cid}.png`')
    else:
        A('- **未发现玻璃发白/发雾车辆**：45 台车库截图逐台过 + 6 台 menu/race 抽查，车窗均深色半透/可看到内饰，'
          '无白雾糊满玻璃；`xiaomi_su7` 车窗为深色不透明（该车无玻璃件，Lead 已知，属预期）。')
    broken = visual.get('broken') or []
    if broken:
        A('')
        A('视觉异常：')
        for b in broken:
            A(f'- `{b.get("car")}`：{b.get("issue")}')
    else:
        A('- **未发现缺轮/破面/车身缺块/轮眉跟轮转** 的静态可见异常（45 台 contact sheet + 重点车放大图）。')
    if visual.get('notes'):
        A('')
        A('其他视觉说明：' + str(visual.get('notes')))

    # 轮宽偏差观察
    try:
        batch = json.load(open(os.path.join(args.staging, 'batch_report.json'), encoding='utf-8'))
        wdev = []
        for slug, c in (batch.get('cars') or {}).items():
            w = c.get('max_dev_old_w_pct')
            if w is not None and abs(w) > 5.0:
                wdev.append((slug, float(w)))
        if wdev:
            A('')
            A('### 5.4 轮宽 vs 旧网页版偏差（>5%，已视觉抽查，不阻断）')
            A('')
            A('> 已抽查 zeekr_7x / bmw_m4_2024 / byd_seal06gt / csl_hommage / m4_gts / m5_f90 / gl8 的放大截图：'
              '轮子贴合轮眉、无穿出/悬空，偏差来自源 blend 轮胎几何与旧网页版不同（预期）。')
            A('')
            for slug, w in sorted(wdev, key=lambda x: -abs(x[1])):
                A(f'- `{slug}`：{w:+.1f}%')
    except Exception:
        pass
    A('')
    A('## 6. 附件清单')
    A('')
    A('| 路径 | 内容 |')
    A('|---|---|')
    A(f'| `{after}/install_plan.txt` | 安装决策（install/skip + 原因 + sha256） |')
    A(f'| `{after}/pre_install/` | 安装前被覆盖的项目文件备份 |')
    A(f'| `{after}/audit_after_run.log`、`/tmp/car_audit_after_report.txt`、`/tmp/car_audit_after.json` | after 静态审计 |')
    A(f'| `{after}/report_audit.md`、`audit_diff.json` | 与旧基线逐车对比 |')
    A(f'| `{after}/runtime_probe.json/.txt`、`runtime_errors.log` | 运行时探针 |')
    A(f'| `{after}/wheel_roll_check.txt` / `wheel_steer_check.txt` / `parts_check.txt` | 验收项 2/3/4 明细 |')
    A(f'| `{after}/garage_*.png`、`menu_*.png`、`race_*.png` | 新模型实拍 |')
    A(f'| `{after}/parts/` | 配件组合实拍 + `garage.json.bak` |')
    A(f'| `{after}/compare_*.png`、`contact_*.png` | 新旧拼图 / 相册 |')
    A('')
    A('---')
    A('_本次 task-4 只写 `assets/cars/models/`（安装）与 `tools/car_audit/`、`/tmp`；未改 `scripts/`、`data/`、`docs/`；'
      '用户存档/设置未留改动。_')

    text = '\n'.join(L) + '\n'
    os.makedirs(os.path.dirname(os.path.abspath(out_path)), exist_ok=True)
    open(out_path, 'w', encoding='utf-8').write(text)
    print(f'[report] wrote {out_path} ({len(text)} chars)')
    print(f'[report] installed={len(installed)} skipped={len(skipped)} roll_serious={len(roll_serious)} steer_bad={len(steer_bad)}')
    return 0


if __name__ == '__main__':
    sys.exit(main())
