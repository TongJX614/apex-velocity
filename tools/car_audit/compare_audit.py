#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
APEX VELOCITY 车模升级：新旧审计对比

用法:
  python3 tools/car_audit/compare_audit.py \
      --old /tmp/car_audit.json \
      --new /tmp/car_audit_after.json \
      --out /tmp/car_after/report.md \
      [--json-out /tmp/car_after/audit_diff.json] \
      [--keep-old hyundai_elantra] \
      [--glass-tol 2]

对比维度（Lead 要求）:
  - 每台 旧tris→新tris、旧材质数→新材质数、透明 surface 数（玻璃面数，±glass-tol 内视为正常）
  - 车漆材质是否带贴图（runtime 前的静态统计：paint_named_surfaces / paint_textured_surfaces）
  - Wheel/Spin 节点是否齐全、轮子 pivot 偏移、轮半径、AABB
  - 无贴图纯白材质数变化
  - 加载失败 / 节点缺失 / 玻璃面数异常 / tris 偏差过大 → 异常清单
输出: markdown 报告 + 可选 machine-readable JSON
退出码: 0 正常；1 存在需要回滚/待修的严重问题（加载失败、节点缺失）
"""
import argparse, json, os, sys

SEVERE = 'severe'
WARN = 'warn'


def load(path):
    with open(path, 'r', encoding='utf-8') as f:
        return json.load(f)


def car_counts(doc, cid):
    c = doc.get('cars', {}).get(cid, {})
    if 'counts' not in c:
        return None
    return c


def fmt_delta(a, b):
    if a is None or b is None:
        return '-'
    d = b - a
    pct = (100.0 * d / a) if a else 0.0
    sign = '+' if d > 0 else ''
    return f'{a:,}→{b:,} ({sign}{pct:+.1f}%)'


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--old', required=True)
    ap.add_argument('--new', required=True)
    ap.add_argument('--out', required=True)
    ap.add_argument('--json-out', default='')
    ap.add_argument('--keep-old', nargs='*', default=[])
    ap.add_argument('--glass-tol', type=int, default=2)
    ap.add_argument('--tris-tol-pct', type=float, default=2.0,
                    help='新 tris 相对 staging/report 之外的软阈值；默认 2%%')
    ap.add_argument('--manifest', default='data/car_manifest.json',
                    help='用于轮距/轮心对称核对的车辆索引（相对项目根，默认 data/car_manifest.json）')
    ap.add_argument('--sym-tol', type=float, default=0.01, help='左右轮心 |x| 差容差（m，默认 0.01）')
    ap.add_argument('--wheelbase-tol-pct', type=float, default=5.0, help='轴距 vs manifest 容差（%%，默认 5）')
    args = ap.parse_args()

    old = load(args.old)
    new = load(args.new)
    try:
        manifest = json.load(open(args.manifest, 'r', encoding='utf-8')).get('cars', {})
    except Exception:
        manifest = {}
    old_cars = old.get('cars', {})
    new_cars = new.get('cars', {})
    ids = sorted(set(old_cars) | set(new_cars))
    keep_old = set(args.keep_old)

    rows = []
    issues = []          # (severity, car_id, message)
    severe_ids = set()
    warn_ids = set()

    for cid in ids:
        oc = old_cars.get(cid)
        nc = new_cars.get(cid)
        row = {'id': cid, 'keep_old': cid in keep_old, 'notes': [], 'issues': []}

        if not nc or not nc.get('instantiate_ok'):
            msg = '新车模加载/实例化失败: ' + str((nc or {}).get('error', 'not in new audit'))
            issues.append((SEVERE, cid, msg))
            severe_ids.add(cid)
            row['notes'].append('加载失败')
            row['status'] = 'FAIL'
            rows.append(row)
            if oc:
                row['old_tris'] = oc['counts']['triangles'] if 'counts' in oc else None
            continue
        if not oc or not oc.get('instantiate_ok'):
            issues.append((WARN, cid, '旧审计里没有该车（新增车？）'))
            warn_ids.add(cid)
            row['notes'].append('旧审计无记录')

        of = oc.get('flags', {}) if oc else {}
        nf = nc.get('flags', {})
        occ = oc.get('counts', {}) if oc else {}
        ncc = nc.get('counts', {})
        row['status'] = 'OK'

        # ---- 基本计数 ----
        row['old_tris'] = occ.get('triangles')
        row['new_tris'] = ncc.get('triangles')
        row['old_surfaces'] = occ.get('surfaces')
        row['new_surfaces'] = ncc.get('surfaces')
        row['old_mats'] = occ.get('material_names')
        row['new_mats'] = ncc.get('material_names')
        if occ.get('triangles') and ncc.get('triangles'):
            d = 100.0 * (ncc['triangles'] - occ['triangles']) / occ['triangles']
            row['tris_delta_pct'] = round(d, 2)
            if abs(d) > args.tris_tol_pct:
                # 结构升级通常 tris 不变；偏差大标 WARN（staging report 才是硬标准）
                issues.append((WARN, cid, f'三角面变化 {d:+.1f}%（旧 {occ["triangles"]:,} → 新 {ncc["triangles"]:,}）'))
                warn_ids.add(cid)
                row['notes'].append(f'tris {d:+.1f}%')

        # ---- 透明度 / 玻璃面数 ----
        ot = occ.get('transparent_surfaces', occ.get('transparent_materials'))
        nt = ncc.get('transparent_surfaces', ncc.get('transparent_materials'))
        row['old_transparent'] = ot
        row['new_transparent'] = nt
        if ot is not None and nt is not None and abs(nt - ot) > args.glass_tol:
            issues.append((WARN, cid, f'透明/玻璃 surface 数异常：旧 {ot} → 新 {nt}（容差 ±{args.glass_tol}）'))
            warn_ids.add(cid)
            row['notes'].append('玻璃面数异常')
        row['old_depth_prepass'] = occ.get('depth_prepass_materials')
        row['new_depth_prepass'] = ncc.get('depth_prepass_materials')

        # ---- 车漆贴图 ----
        row['old_paint'] = occ.get('paint_named_surfaces')
        row['old_paint_tex'] = occ.get('paint_textured_surfaces')
        row['new_paint'] = ncc.get('paint_named_surfaces')
        row['new_paint_tex'] = ncc.get('paint_textured_surfaces')
        if ncc.get('paint_named_surfaces'):
            if ncc.get('paint_textured_surfaces', 0) == 0:
                issues.append((WARN, cid, '新车漆材质 0 个带贴图（原厂漆/拉花丢失，将走调色板兜底色）'))
                warn_ids.add(cid)
                row['notes'].append('车漆无贴图')

        # ---- 节点 / 轮子 ----
        row['wheels_ok'] = bool(nf.get('all_wheel_nodes_present')) and bool(nf.get('all_spin_nodes_present'))
        row['steer'] = bool(nf.get('steer_pivot_present'))
        row['wing'] = bool(nf.get('wing_mount_present'))
        if not row['wheels_ok']:
            missing = nc.get('node_presence', {}).get('missing', [])
            issues.append((SEVERE, cid, f'Wheel/Spin 节点缺失: {missing}'))
            severe_ids.add(cid)
            row['notes'].append('轮节点缺失')
            row['status'] = 'FAIL'
        if not row['steer']:
            issues.append((WARN, cid, 'SteerPivot 缺失'))
            warn_ids.add(cid)
            row['notes'].append('SteerPivot 缺失')
        if not row['wing']:
            issues.append((WARN, cid, 'WingMount 缺失'))
            warn_ids.add(cid)
            row['notes'].append('WingMount 缺失')

        row['old_pivot'] = oc.get('wheels_worst_offset') if oc else None
        row['new_pivot'] = nc.get('wheels_worst_offset')
        if nf.get('wheel_pivot_offset_bad'):
            issues.append((WARN, cid, f'轮子 pivot 偏移 {nc.get("wheels_worst_offset"):.3f} m'))
            warn_ids.add(cid)
            row['notes'].append('pivot 偏移')
        row['radius_bad'] = bool(nf.get('wheel_radius_mismatch'))
        if row['radius_bad']:
            issues.append((WARN, cid, '轮半径与 manifest 不符'))
            warn_ids.add(cid)
            row['notes'].append('轮半径偏差')

        # ---- AABB ----
        naabb = nc.get('aabb', {})
        row['aabb_ok'] = bool(naabb.get('x_centered')) and bool(naabb.get('z_centered')) and bool(naabb.get('y_min_ok'))
        if not row['aabb_ok']:
            issues.append((WARN, cid, f'AABB 未归一: {naabb}'))
            warn_ids.add(cid)
            row['notes'].append('AABB 异常')

        # ---- 轮心对称 / 轴距 ----
        wheels = nc.get('wheels', {}) or {}
        def sp(suffix):
            w = wheels.get(suffix, {}) or {}
            p = w.get('spin_pivot')
            return p if isinstance(p, list) and len(p) == 3 else None
        fl, fr, rl, rr = sp('FL'), sp('FR'), sp('RL'), sp('RR')
        sym = None
        wheelbase = None
        if fl and fr and rl and rr:
            dx_f = abs(abs(fl[0]) - abs(fr[0]))
            dx_r = abs(abs(rl[0]) - abs(rr[0]))
            sym = round(max(dx_f, dx_r), 4)
            wheelbase = round(abs(fl[2] - rl[2]), 4)
            row['new_wheel_sym'] = sym
            row['new_wheelbase'] = wheelbase
            if sym > args.sym_tol:
                issues.append((WARN, cid, f'左右轮心 |x| 不对称：差 {sym:.4f} m（容差 {args.sym_tol}）'))
                warn_ids.add(cid)
                row['notes'].append('轮心不对称')
            entry = manifest.get(cid, {})
            wb_expected = entry.get('wheelbase')
            if wb_expected and wheelbase:
                errp = 100.0 * abs(wheelbase - float(wb_expected)) / float(wb_expected)
                row['wheelbase_err_pct'] = round(errp, 2)
                if errp > args.wheelbase_tol_pct:
                    issues.append((WARN, cid, f'轴距 {wheelbase:.3f} m vs manifest {wb_expected} m（偏差 {errp:.1f}%）'))
                    warn_ids.add(cid)
                    row['notes'].append('轴距偏差')

        # ---- 白无贴图 / 贴图 ----
        row['old_white'] = occ.get('white_no_texture_materials')
        row['new_white'] = ncc.get('white_no_texture_materials')
        row['new_white_nonpaint'] = ncc.get('white_nonpaint_materials')
        row['new_textured'] = ncc.get('textured_surfaces')
        row['new_textured_embedded'] = ncc.get('embedded_texture_surfaces')
        row['new_texture_files_missing'] = ncc.get('missing_texture_surfaces')

        # clearcoat: Lead 已在运行时补，静态=0 属正常，仅记录
        row['new_clearcoat_src'] = ncc.get('clearcoat_source_materials')
        row['new_clearcoat_imported'] = ncc.get('clearcoat_imported_materials')

        rows.append(row)

    # ---- 汇总 ----
    total_old = sum(r.get('old_tris') or 0 for r in rows)
    total_new = sum(r.get('new_tris') or 0 for r in rows)
    n_ok = sum(1 for r in rows if r['status'] == 'OK')
    lines = []
    A = lines.append
    A('# 车模升级后审计对比（旧基线 vs 新模型）')
    A('')
    A(f'- 旧审计: `{args.old}`')
    A(f'- 新审计: `{args.new}`')
    A(f'- 车辆: {len(rows)} 台　OK {n_ok}　需注意 {len(warn_ids)}　严重 {len(severe_ids)}')
    A(f'- 三角面合计: {total_old:,} → {total_new:,}（{100.0*(total_new-total_old)/max(total_old,1):+.2f}%）')
    if keep_old:
        A(f'- 按约定保持旧版: {", ".join(sorted(keep_old))}')
    A('')
    A('## 异常清单')
    A('')
    if not issues:
        A('无。')
    else:
        A('| 级别 | 车辆 | 问题 |')
        A('|---|---|---|')
        order = {SEVERE: 0, WARN: 1}
        for sev, cid, msg in sorted(issues, key=lambda x: (order[x[0]], x[1])):
            A(f'| {"**严重**" if sev == SEVERE else "注意"} | `{cid}` | {msg} |')
    A('')
    A('## 逐车对比')
    A('')
    A('| 车辆 | 三角面 | surface | 材质名 | 透明/玻璃 surface | 车漆带贴图 | 轮节点 | pivot(m) | 轮心对称/轴距 | AABB | 备注 |')
    A('|---|---|---|---|---|---|---|---|---|---|---|')
    for r in rows:
        cid = r['id']
        mark = '（保持旧版）' if r['keep_old'] else ''
        if r['status'] == 'FAIL':
            A(f'| `{cid}` | {r.get("old_tris", "-")}→FAIL | - | - | - | - | 缺失 | - | - | {mark}{"、".join(r["notes"])} |')
            continue
        paint = f'{r["old_paint"]}/{r["old_paint_tex"]} → {r["new_paint"]}/{r["new_paint_tex"]}'
        A('| `{}` | {} | {} | {} | {} | {} | {} | {} | {} | {}{} |'.format(
            cid,
            fmt_delta(r['old_tris'], r['new_tris']),
            fmt_delta(r['old_surfaces'], r['new_surfaces']),
            fmt_delta(r['old_mats'], r['new_mats']),
            f'{r["old_transparent"]} → {r["new_transparent"]}',
            paint,
            '4/4' if r['wheels_ok'] else 'MISSING',
            f'{r["old_pivot"]:.3f}→{r["new_pivot"]:.3f}' if (r['old_pivot'] is not None and r['new_pivot'] is not None) else '-',
            (f'Δx={r["new_wheel_sym"]:.4f}/轴距={r["new_wheelbase"]:.2f}' if r.get('new_wheel_sym') is not None else '-'),
            'OK' if r['aabb_ok'] else '异常',
            mark,
            (' ; '.join(r['notes'])) if r['notes'] else '',
        ))
    A('')
    A('说明：“透明/玻璃 surface”=导入后 transparency != 0 的 surface 数（新模型应只剩玻璃）；'
      '车漆带贴图=“paint/carpaint/车漆/coloured 命名 surface 数 / 其中 albedo 贴图非空的数量”，'
      '新模型应大部分有贴图，0 个带贴图说明原厂漆/拉花丢失（运行时走调色板兜底色）。'
      'clearcoat 静态统计仅供参考——Lead 已在 car_visual.gd 运行时对车漆材质补 clearcoat_enabled。')

    os.makedirs(os.path.dirname(os.path.abspath(args.out)), exist_ok=True)
    with open(args.out, 'w', encoding='utf-8') as f:
        f.write('\n'.join(lines) + '\n')
    print(f'[compare] wrote {args.out}  cars={len(rows)} severe={len(severe_ids)} warn={len(warn_ids)}')

    if args.json_out:
        payload = {
            'old': args.old, 'new': args.new,
            'keep_old': sorted(keep_old),
            'rows': rows,
            'issues': [{'severity': s, 'car': c, 'message': m} for s, c, m in issues],
            'severe_cars': sorted(severe_ids),
            'warn_cars': sorted(warn_ids),
            'totals': {'old_tris': total_old, 'new_tris': total_new},
        }
        os.makedirs(os.path.dirname(os.path.abspath(args.json_out)), exist_ok=True)
        with open(args.json_out, 'w', encoding='utf-8') as f:
            json.dump(payload, f, ensure_ascii=False, indent=1)
        print(f'[compare] wrote {args.json_out}')

    return 1 if severe_ids else 0


if __name__ == '__main__':
    sys.exit(main())
