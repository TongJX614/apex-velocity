# -*- coding: utf-8 -*-
"""run_batch.py —— 全量把拆分版 .blend 重导出为游戏用 GLB，并做逐台校验。

用法：
  python3 tools/car_export/run_batch.py [--out /tmp/car_export_out] [--jobs 3]
                                       [--only slug1,slug2] [--skip slug1,slug2]

流程：
  1) 读 mapping.json，为每台车推 review json（审查包 json/<src>.json）；
  2) 起 Blender 子进程（并发默认 3）跑 export_godot_car.py，参数：
     <blend> <out.glb> <report.json> <review.json> <old_wheel_ref.json> <slug>
  3) 纯 Python 校验 GLB：总 tris vs 审查 json、玻璃 alphaMode、4 轮节点/对称性、
     0 三角网格、贴图数、轮径/轮宽 vs 旧游戏模型包络（/tmp/old_wheel_ref.json）；
  4) 汇总 /tmp/car_export_out/batch_report.json + special_cases.md
"""
import argparse
import json
import math
import os
import re
import struct
import subprocess
import sys
import threading
import time

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
TOOLS = os.path.join(ROOT, "tools", "car_export")
MAPPING = os.path.join(TOOLS, "mapping.json")
EXPORTER = os.path.join(TOOLS, "export_godot_car.py")
BLENDER = "/Users/tong/Applications/Blender.app/Contents/MacOS/Blender"
OLD_REF = "/tmp/old_wheel_ref.json"
DEFAULT_OUT = "/tmp/car_export_out"

# 已知特例
SKIP_ALWAYS = {
    "hyundai_elantra": "骨骼蒙皮模型，车轮无 STEER_/WHEEL_ 拆分；保留旧模型",
    "bmw_m4_adro_kit": "源 blend 轮组异常(前后轮径不一致+重复几何)，经 Lead 决定保留旧模型",
}
GLASS_RE = re.compile(r"glass|glaz|window|windscreen|windshield|vitr|crystal|玻璃|挡风|车窗", re.I)
TIRE_RE = re.compile(r"tire|tyre|rubber|pneu|sidewall", re.I)


# ---------------------------------------------------------------------------
# GLB 解析
# ---------------------------------------------------------------------------
def read_glb(path):
    data = open(path, "rb").read()
    magic, ver, total = struct.unpack("<III", data[:12])
    off = 12
    js = None
    while off < total:
        clen, ctype = struct.unpack("<II", data[off:off + 8])
        chunk = data[off + 8:off + 8 + clen]
        if ctype == 0x4E4F534A:
            js = json.loads(chunk.decode("utf-8"))
        off += 8 + clen
    return js, len(data)


def glb_tris(g):
    tris = 0
    for m in g.get("meshes", []):
        for p in m.get("primitives", []):
            if "indices" in p:
                tris += g["accessors"][p["indices"]]["count"] // 3
            else:
                tris += g["accessors"][p["attributes"]["POSITION"]]["count"] // 3
    return tris


def node_world_translation(g, idx):
    nodes = g.get("nodes", [])
    n = nodes[idx]
    t = n.get("translation") or [0.0, 0.0, 0.0]
    if "matrix" in n:
        m = n["matrix"]
        return [m[12], m[13], m[14]]
    return list(t)


def build_tree(g):
    nodes = g.get("nodes", [])
    parent = {}
    for i, n in enumerate(nodes):
        for c in n.get("children", []):
            parent[c] = i

    def world_t(i):
        t = [0.0, 0.0, 0.0]
        cur = i
        while cur is not None:
            lt = node_world_translation(g, cur)
            t = [t[0] + lt[0], t[1] + lt[1], t[2] + lt[2]]
            cur = parent.get(cur)
        return t

    roots = [i for i in range(len(nodes)) if i not in parent]
    return nodes, parent, roots, world_t


def node_by_name(g):
    return {n.get("name", ""): i for i, n in enumerate(g.get("nodes", []))}


def mesh_tris_of_node(g, idx):
    n = g["nodes"][idx]
    if "mesh" not in n:
        return 0
    t = 0
    for p in g["meshes"][n["mesh"]].get("primitives", []):
        if "indices" in p:
            t += g["accessors"][p["indices"]]["count"] // 3
        else:
            t += g["accessors"][p["attributes"]["POSITION"]]["count"] // 3
    return t


def descendants(g, idx):
    out = []
    stack = list(g["nodes"][idx].get("children", []))
    while stack:
        c = stack.pop()
        out.append(c)
        stack.extend(g["nodes"][c].get("children", []))
    return out


# ---------------------------------------------------------------------------
# 单台校验
# ---------------------------------------------------------------------------
def validate_car(slug, glb_path, report, review_json_path, review_glb_path, old_ref, manifest_car):
    g, size = read_glb(glb_path)
    res = {"status": "ok", "warnings": [], "errors": []}
    res["glb_mb"] = round(size / 1048576.0, 2)
    res["tris"] = glb_tris(g)
    res["meshes"] = len(g.get("meshes", []))
    res["nodes"] = len(g.get("nodes", []))
    res["materials"] = len(g.get("materials", []))
    res["images"] = len(g.get("images", []))
    res["exported_seconds"] = report.get("export_seconds")

    # --- 玻璃 / alphaMode ---
    mats = g.get("materials", [])
    blend_mats, opaque_mats = [], []
    for m in mats:
        (blend_mats if m.get("alphaMode") == "BLEND" else opaque_mats).append(m.get("name", ""))
    res["glass_blend_materials"] = len(blend_mats)
    res["blend_material_names"] = blend_mats
    # 报告里标记为 glass 的材质应全部 BLEND；非 glass 的 BLEND = 非预期
    rep_glass = {m["name"] for m in report.get("materials", []) if m.get("glass")}
    unexpected = [n for n in blend_mats if n not in rep_glass and not GLASS_RE.search(n or "")]
    res["unexpected_blend"] = unexpected
    if unexpected:
        res["warnings"].append("非预期 alphaMode=BLEND 材质: %s" % unexpected[:6])
    n_report_glass = report.get("n_glass_materials", 0)
    if n_report_glass and len(blend_mats) < n_report_glass:
        res["warnings"].append("报告玻璃材质 %d 个，GLB 里 BLEND 只有 %d 个" % (n_report_glass, len(blend_mats)))

    # --- 层级/轮子 ---
    nodes = g.get("nodes", [])
    names = node_by_name(g)
    required = ["CarRoot", "Wheel_FL", "Wheel_FR", "Wheel_RL", "Wheel_RR",
                "Spin_Wheel_FL", "Spin_Wheel_FR", "Spin_Wheel_RL", "Spin_Wheel_RR",
                "Tyre_Wheel_FL", "Rim_Wheel_FL", "WingMount"]
    def has_node(nm):
        return nm in names or any(k.startswith(nm) for k in names)
    missing = [n for n in required if not has_node(n)]
    res["missing_nodes"] = missing
    if missing:
        res["errors"].append("缺节点: %s" % missing)
    # 游戏按名查找的关键节点必须精确（不允许 .001 后缀）
    exact_critical = ["CarRoot", "SteerPivot", "WingMount"] + \
        ["Wheel_" + k for k in ("FL", "FR", "RL", "RR")] + \
        ["Spin_Wheel_" + k for k in ("FL", "FR", "RL", "RR")] + \
        ["Tyre_Wheel_FL", "Rim_Wheel_FL"]
    suffixed = [n for n in exact_critical if n not in names and has_node(n)]
    res["suffixed_nodes"] = suffixed
    if suffixed:
        res["warnings"].append("关键节点名带后缀（应为精确名）: %s" % suffixed)
        res["status"] = "ok_special"
    if "CarRoot" in names:
        root_children = {nodes[c].get("name", "") for c in nodes[names["CarRoot"]].get("children", [])}
        for w in ("Wheel_FL", "Wheel_FR", "Wheel_RL", "Wheel_RR", "WingMount"):
            if w not in root_children:
                res["errors"].append("%s 未挂在 CarRoot 下" % w)

    # --- 轮心对称 ---
    _nodes, _parent, roots, world_t = build_tree(g)
    wheel_C = {}
    for k in ("FL", "FR", "RL", "RR"):
        nm = "Wheel_" + k
        if nm in names:
            wheel_C[k] = [round(float(v), 4) for v in world_t(names[nm])]
    res["wheel_C_gltf"] = wheel_C
    sym = {}
    if len(wheel_C) == 4:
        sym["x_lr_fl"] = round(abs(wheel_C["FL"][0] + wheel_C["FR"][0]), 4)
        sym["x_lr_rl"] = round(abs(wheel_C["RL"][0] + wheel_C["RR"][0]), 4)
        sym["z_fr_fl"] = round(abs(wheel_C["FL"][2] - wheel_C["FR"][2]), 4)
        sym["z_rr_rl"] = round(abs(wheel_C["RL"][2] - wheel_C["RR"][2]), 4)
        sym["y_fr_fl"] = round(abs(wheel_C["FL"][1] - wheel_C["FR"][1]), 4)
        sym["y_rr_rl"] = round(abs(wheel_C["RL"][1] - wheel_C["RR"][1]), 4)
    res["wheel_symmetry_m"] = sym
    for key in ("x_lr_fl", "x_lr_rl", "z_fr_fl", "z_rr_rl"):
        if key in sym and sym[key] > 0.01:
            res["warnings"].append("轮心对称超差 %s=%.3fm (>1cm)" % (key, sym[key]))

    # --- 0 三角网格 ---
    zero = []
    for i, n in enumerate(nodes):
        if "mesh" in n and mesh_tris_of_node(g, i) == 0:
            zero.append(n.get("name", ""))
    res["zero_tri_meshes"] = zero
    if zero:
        res["warnings"].append("0 三角网格: %s" % zero[:6])

    # --- 轮子网格是否都挂在 Spin 下 ---
    wheels_ok = True
    name_lookup = {}
    for _i, _n in enumerate(nodes):
        name_lookup.setdefault(_n.get("name", ""), _i)
    for k in ("FL", "FR", "RL", "RR"):
        spin_key = "Spin_Wheel_" + k
        spin_idx = names.get(spin_key) or name_lookup.get(spin_key)
        if spin_idx is None:
            continue
        sub = [nodes[x].get("name", "") for x in descendants(g, spin_idx)]
        if not any(n.startswith("Tyre_Wheel_") for n in sub) or not any(n.startswith("Rim_Wheel_") for n in sub):
            wheels_ok = False
            res["warnings"].append("Wheel_%s 的 Spin 下缺 Tyre/Rim" % k)
    res["wheel_hierarchy_ok"] = wheels_ok

    # --- tris vs 审查 json ---
    ref_tris = None
    if review_json_path and os.path.exists(review_json_path):
        try:
            rj = json.load(open(review_json_path, encoding="utf-8"))
            ref_tris = rj.get("tris")
            res["src_family"] = rj.get("family")
        except Exception as e:  # noqa: BLE001
            res["warnings"].append("读取 review json 失败: %s" % e)
    res["ref_tris_json"] = ref_tris
    res["ref_tris"] = ref_tris
    # 主参考：审查包 glb/ 里上一轮同 blend 的导出总 tris（同口径），json 的 tris 有时含
    # studio/灯光辅助网格，口径不同（如 m6_gt3 json 72971 vs 实际车体 66858）。
    ref_glb_tris = None
    if review_glb_path and os.path.exists(review_glb_path):
        try:
            _g, _ = read_glb(review_glb_path)
            ref_glb_tris = glb_tris(_g)
        except Exception as e:  # noqa: BLE001
            res["warnings"].append("读取 review glb 失败: %s" % e)
    res["ref_glb_tris"] = ref_glb_tris
    ref_main = ref_glb_tris if ref_glb_tris else ref_tris
    res["ref_tris"] = ref_main
    if ref_main:
        dev = (res["tris"] - ref_main) / ref_main * 100.0
        res["tris_dev_pct"] = round(dev, 3)
        if abs(dev) > 0.5:
            res["warnings"].append("tris 与上一轮同 blend 导出差 %+.2f%% (>0.5%%)" % dev)
            res["status"] = "ok_special"
    else:
        res["tris_dev_pct"] = None

    # --- 轮径/轮宽 vs 旧模型包络 + 报告自检 ---
    old = (old_ref.get(slug) or {}).get("wheels") or {}
    rep_wheels = report.get("wheels", {})
    car_wheels = {}
    max_dev_r = 0.0
    for k in ("FL", "FR", "RL", "RR"):
        rw = rep_wheels.get(k, {})
        entry = {
            "C_gltf": rw.get("C_gltf"),
            "measured_r": rw.get("radius"),
            "measured_w": rw.get("width"),
            "trimmed_tris": rw.get("trimmed_tris"),
            "fragment_mode": rw.get("fragment_mode"),
            "classes": rw.get("classes"),
        }
        if k in old:
            o = old[k]
            entry["old_r"] = round(float(o.get("radius") or 0), 4)
            entry["old_w"] = round(float(o.get("width") or 0), 4)
            if rw.get("radius") and entry["old_r"]:
                dr = (rw["radius"] - entry["old_r"]) / entry["old_r"] * 100.0
                entry["dev_old_r_pct"] = round(dr, 2)
                max_dev_r = max(max_dev_r, abs(dr))
                if abs(dr) > 5.0:
                    res["warnings"].append("%s 轮径 vs 旧模型 %+.1f%% (>5%%)" % (k, dr))
                    res["status"] = "ok_special"
            if rw.get("width") and entry["old_w"]:
                dw = (rw["width"] - entry["old_w"]) / entry["old_w"] * 100.0
                entry["dev_old_w_pct"] = round(dw, 2)
        if manifest_car.get("wheelRadius") and rw.get("radius"):
            entry["manifest_wheelRadius"] = manifest_car["wheelRadius"]
            entry["dev_manifest_r_pct"] = round(
                (rw["radius"] - manifest_car["wheelRadius"]) / manifest_car["wheelRadius"] * 100.0, 2)
        car_wheels[k] = entry
    res["wheels"] = car_wheels
    res["max_dev_old_r_pct"] = round(max_dev_r, 2)
    max_dev_w = 0.0
    for w in res["wheels"].values():
        if w.get("dev_old_w_pct") is not None:
            max_dev_w = max(max_dev_w, abs(w["dev_old_w_pct"]))
    res["max_dev_old_w_pct"] = round(max_dev_w, 2)

    # --- 材质/玻璃统计与贴图 ---
    res["glass_report_n"] = report.get("n_glass_materials")
    res["opaque_report_n"] = report.get("n_opaque_materials")
    res["warnings"] += ["export: " + w for w in (report.get("warnings") or [])]
    if report.get("errors"):
        res["status"] = "fail"
        res["errors"] += report["errors"]
    return res


# ---------------------------------------------------------------------------
# 批量调度
# ---------------------------------------------------------------------------
def run_car(car, outdir, old_ref_path, results, lock):
    slug = car["slug"]
    out_glb = os.path.join(outdir, slug + ".glb")
    out_rep = os.path.join(outdir, slug + ".report.json")
    log_path = os.path.join(outdir, "logs", slug + ".log")
    review_json = car["review_json"]
    cmd = [BLENDER, "-b", "--factory-startup", "--python", EXPORTER, "--",
           car["blend"], out_glb, out_rep, review_json, old_ref_path, slug]
    t0 = time.time()
    ok = False
    err = ""
    try:
        with open(log_path, "w", encoding="utf-8") as logf:
            proc = subprocess.run(cmd, stdout=logf, stderr=subprocess.STDOUT, timeout=900)
        ok = proc.returncode == 0
    except subprocess.TimeoutExpired:
        err = "timeout 900s"
    except Exception as e:  # noqa: BLE001
        err = str(e)
    secs = round(time.time() - t0, 1)
    report = {}
    if os.path.exists(out_rep):
        try:
            report = json.load(open(out_rep, encoding="utf-8"))
        except Exception:  # noqa: BLE001
            pass
    status = "ok"
    if not ok or report.get("errors") or not os.path.exists(out_glb):
        status = "fail"
        if not err:
            err = "; ".join(report.get("errors") or []) or "blender rc != 0 / 无 GLB"
    with lock:
        results[slug] = {
            "slug": slug,
            "status": status,
            "seconds": secs,
            "error": err,
            "report": report,
            "glb": out_glb,
            "review_json": review_json,
            "review_glb": car.get("review_glb"),
        }
    print("[%s] %s %.1fs%s" % ("OK" if status == "ok" else "FAIL", slug, secs,
                               ("  " + err) if err else ""), flush=True)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default=DEFAULT_OUT)
    ap.add_argument("--jobs", type=int, default=3)
    ap.add_argument("--only", default="")
    ap.add_argument("--skip", default="")
    ap.add_argument("--old-ref", default=OLD_REF)
    args = ap.parse_args()

    outdir = args.out
    os.makedirs(os.path.join(outdir, "logs"), exist_ok=True)
    mapping = json.load(open(MAPPING, encoding="utf-8"))
    review_root = os.path.dirname(mapping["blend_dir"])
    manifest = json.load(open(os.path.join(ROOT, "data", "car_manifest.json"), encoding="utf-8"))["cars"]
    old_ref = {}
    if os.path.exists(args.old_ref):
        old_ref = json.load(open(args.old_ref, encoding="utf-8"))

    only = set(s.strip() for s in args.only.split(",") if s.strip())
    extra_skip = set(s.strip() for s in args.skip.split(",") if s.strip())

    run_list, skip_list = [], []
    for c in mapping["cars"]:
        slug = c["slug"]
        review_json = os.path.join(review_root, "json", os.path.splitext(c["src"])[0] + ".json")
        if slug in SKIP_ALWAYS:
            skip_list.append({"slug": slug, "status": "skip_keep_old", "reason": SKIP_ALWAYS[slug]})
            continue
        if only and slug not in only:
            continue
        if slug in extra_skip:
            skip_list.append({"slug": slug, "status": "skip", "reason": "命令行 --skip"})
            continue
        review_glb = os.path.join(review_root, "glb", os.path.splitext(c["src"])[0] + ".glb")
        run_list.append({"slug": slug, "blend": c["blend"], "review_json": review_json,
                         "review_glb": review_glb})

    print("[BATCH] 计划导出 %d 台，跳过 %d 台，并发 %d" % (len(run_list), len(skip_list), args.jobs))
    # 清掉旧产物
    for f in os.listdir(outdir):
        if f.endswith(".glb") or f.endswith(".report.json"):
            try:
                os.remove(os.path.join(outdir, f))
            except OSError:
                pass
    results = {}
    lock = threading.Lock()
    threads = []
    pending = list(run_list)
    running = []
    while pending or running:
        while pending and len(running) < args.jobs:
            car = pending.pop(0)
            th = threading.Thread(target=run_car, args=(car, outdir, args.old_ref, results, lock))
            th.start()
            running.append(th)
        running = [t for t in running if t.is_alive()]
        time.sleep(0.3)

    # 校验 + 汇总
    batch = {
        "generated_at": time.strftime("%Y-%m-%d %H:%M:%S"),
        "exported": len(run_list),
        "skipped": len(skip_list),
        "total_cars": len(mapping["cars"]),
        "cars": {},
        "skip": skip_list,
        "failures": [],
        "special": [],
    }
    for slug, r in sorted(results.items()):
        entry = {
            "slug": slug,
            "status": r["status"],
            "seconds": r["seconds"],
        }
        rep = r["report"]
        if r["status"] == "ok":
            try:
                car_manifest = manifest.get(slug, {})
                v = validate_car(slug, r["glb"], rep, r["review_json"], r.get("review_glb"), old_ref, car_manifest)
                entry.update(v)
            except Exception as e:  # noqa: BLE001
                entry["status"] = "fail"
                entry["errors"] = ["校验异常: %s" % e]
        else:
            entry["error"] = r["error"]
            batch["failures"].append({"slug": slug, "reason": r["error"]})
        entry["glb"] = r["glb"]
        batch["cars"][slug] = entry
        if entry["status"] in ("ok_special",):
            batch["special"].append({
                "slug": slug,
                "reasons": (entry.get("warnings") or [])[:6],
                "max_dev_old_r_pct": entry.get("max_dev_old_r_pct"),
            })

    ok_n = sum(1 for e in batch["cars"].values() if e["status"] == "ok")
    special_n = sum(1 for e in batch["cars"].values() if e["status"] == "ok_special")
    batch["summary"] = {
        "ok": ok_n,
        "ok_special": special_n,
        "fail": len(batch["failures"]),
        "skip": len(skip_list),
        "total": len(mapping["cars"]),
    }
    # 偏差 >5% 的车
    bad_dev = []
    for slug, e in batch["cars"].items():
        if e.get("max_dev_old_r_pct") is not None and e["max_dev_old_r_pct"] > 5.0:
            bad_dev.append({"slug": slug, "max_dev_pct": e["max_dev_old_r_pct"]})
    batch["measured_r_dev_gt5pct"] = bad_dev
    bad_w = []
    for slug, e in batch["cars"].items():
        if e.get("max_dev_old_w_pct") is not None and e["max_dev_old_w_pct"] > 5.0:
            bad_w.append({"slug": slug, "max_dev_w_pct": e["max_dev_old_w_pct"]})
    batch["measured_w_dev_gt5pct"] = bad_w

    bp = os.path.join(outdir, "batch_report.json")
    json.dump(batch, open(bp, "w", encoding="utf-8"), ensure_ascii=False, indent=1)
    print("[BATCH] done: ok=%d ok_special=%d fail=%d skip=%d -> %s"
          % (ok_n, special_n, len(batch["failures"]), len(skip_list), bp))

    # 特例清单 markdown
    md = ["# 车模重导出：失败与特例清单", "", "生成时间：%s" % batch["generated_at"], ""]
    md.append("## 汇总")
    s = batch["summary"]
    md.append("- 成功：%d 台（其中 ok_special：%d）" % (s["ok"] + s["ok_special"], s["ok_special"]))
    md.append("- 失败：%d 台" % s["fail"])
    md.append("- 跳过保留旧模型：%d 台" % s["skip"])
    md.append("")
    md.append("## 跳过（保留旧模型）")
    for x in skip_list:
        md.append("- `%s`：%s" % (x["slug"], x["reason"]))
    md.append("")
    md.append("## 特例/告警（ok_special）")
    for x in batch["special"]:
        md.append("- `%s`：%s" % (x["slug"], "；".join(x["reasons"])))
    if not batch["special"]:
        md.append("- 无")
    md.append("")
    md.append("## 失败")
    if batch["failures"]:
        for x in batch["failures"]:
            md.append("- `%s`：%s" % (x["slug"], x["reason"]))
    else:
        md.append("- 无")
    md.append("")
    md.append("## measured_w 与旧游戏模型包络偏差 >5% 的车辆（仅 warning，按 Lead 要求不硬裁）")
    if bad_w:
        for x in bad_w:
            md.append("- `%s`：%+.1f%%" % (x["slug"], x["max_dev_w_pct"]))
    else:
        md.append("- 无")
    md.append("")
    md.append("## 说明：tris 参考口径")
    md.append("主参考为 `车辆模型_拆分版_待审查/glb/<车型>.glb`（上一轮同 blend 的导出总 tris，同口径）；"
              "审查包 json 的 `tris` 在部分车型里包含 studio/灯光辅助网格（如 bmw_m6_gt3 json 72971 vs 车体 66858），"
              "仅作副参考记录在 `ref_tris_json`。")
    md.append("")
    md.append("## measured_r 与旧游戏模型包络偏差 >5% 的车辆")
    if bad_dev:
        for x in bad_dev:
            md.append("- `%s`：%+.1f%%" % (x["slug"], x["max_dev_pct"]))
    else:
        md.append("- 无")
    open(os.path.join(outdir, "special_cases.md"), "w", encoding="utf-8").write("\n".join(md))

    # 逐台 txt 摘要
    lines = []
    for slug, e in sorted(batch["cars"].items()):
        w = e["wheels"] if "wheels" in e else {}
        wr = " ".join("%s R=%.3f(dev%+.1f%%) W=%.3f" % (
            k, w[k].get("measured_r") or 0,
            (w[k].get("dev_old_r_pct") if w[k].get("dev_old_r_pct") is not None else 0.0),
            w[k].get("measured_w") or 0) for k in ("FL", "FR", "RL", "RR") if k in w)
        lines.append("%-24s %-10s tris=%-8s dev_tris=%-8s glass=%-3s mb=%-6s %5.1fs %s" % (
            slug, e["status"], e.get("tris"), e.get("tris_dev_pct"),
            e.get("glass_blend_materials"), e.get("glb_mb"), e.get("seconds") or 0, wr))
        for wn in (e.get("warnings") or []):
            lines.append("    ! " + wn)
    open(os.path.join(outdir, "batch_report.txt"), "w", encoding="utf-8").write("\n".join(lines))
    print("[BATCH] wrote batch_report.json / batch_report.txt / special_cases.md")


if __name__ == "__main__":
    main()
