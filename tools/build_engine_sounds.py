#!/usr/bin/env python3
"""生成 data/engine_sounds.json —— 45 台车的逐车引擎声音档案。

背景
----
旧版引擎声是纯正弦谐波堆栈，基频与真实点火频率脱钩：V6/V8/I4 的基频差
不足一倍，听感几乎一致；EV 的高阶谐波叠到 15 kHz，啸叫刺耳。

本脚本为每台车建立**物理正确**的引擎档案：
  · 真实缸数 / 点火间隔（firingDiv = 四冲程每转点火次数 = 缸数/2）
  · 真实怠速 / 红线转速（供分档位曲线与 HUD 使用）
  · 缸体特征（V8 十字平面 / I6 / I4 / I3 奇数缸的 lope）
  · 进气形式（na / turbo / twin_turbo）对应的涡轮哨声与泄压阀
  · 排气性格（street / sport / race / open）与排气脉冲锐度
  · EV 电机音色分档（city / mainstream / performance / hyper）

档案由「家族模板 + 逐车覆写」两层构成：模板承载缸体共性，覆写承载真车
个性（转速、性格、进气形式、素材）。这样既可维护又可逐台审计。

用法：python3 tools/build_engine_sounds.py
"""

import json
import os
from collections import OrderedDict

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT_PATH = os.path.join(ROOT, "data", "engine_sounds.json")
CARS_JSON = os.path.join(ROOT, "data", "cars.json")


def load_game_redlines():
    """读取 cars.json 里每台车的归一化红线（0.92~1.0）。

    为什么要它：引擎声原先用固定阈值 0.985 判断"进入断油"，但游戏里每台车
    的红线各不相同（0.92~1.0），结果 33/45 台车永远触发不了断油声。
    真实红线必须跟着车走，断油判定才能和车辆实际状态对齐。
    """
    out = {}
    try:
        with open(CARS_JSON, "r", encoding="utf-8") as f:
            data = json.load(f)
        for spec in data.get("specs", []):
            cid = spec.get("id")
            if cid:
                out[cid] = float(spec.get("redline", 0.97))
    except Exception as exc:  # 读不到就退回默认值，不阻塞构建
        print("[BUILD] 警告: 无法读取 cars.json (%s)" % exc)
    return out


GAME_REDLINES = load_game_redlines()

# ---------------------------------------------------------------------------
# 家族模板
# ---------------------------------------------------------------------------
# base[0..15] 对应 1..16 阶点火谐波权重（相对 1 阶）。
# base[0] 是 1 阶，base[1] 是 2 阶，依此类推 —— 阶次越高越"尖"，是听感上
# 区分 V8 / V6 / I4 / I3 的主因。
FAMILIES = {
    # BMW S65/P60/S63 十字平面 V8：1 阶饱满、2 阶弱、4 阶明显（十字平面的
    # 特征阶次），低转有经典的 lope。
    "v8_cross": {
        "base": [1.00, 0.42, 0.30, 0.46, 0.14, 0.22, 0.09, 0.15,
                 0.06, 0.10, 0.04, 0.08, 0.03, 0.06, 0.02, 0.05],
        "lope": 0.34,        # 怠速 lope 深度（半频 AM 幅度）
        "subWeight": 0.30,   # 半频次低频体量
        "orders": 16,
    },
    # P58 平面 V8（赛车）：点火更均匀、高阶更少、脉冲更硬。
    "v8_flat": {
        "base": [1.00, 0.55, 0.34, 0.40, 0.20, 0.26, 0.12, 0.18,
                 0.08, 0.12, 0.05, 0.09, 0.04, 0.06, 0.03, 0.05],
        "lope": 0.18,
        "subWeight": 0.20,
        "orders": 16,
    },
    # 直列六：点火均匀，2 阶与 3 阶突出，中高频比 V8 亮。
    "i6": {
        "base": [1.00, 0.58, 0.44, 0.30, 0.30, 0.18, 0.24, 0.12,
                 0.16, 0.09, 0.12, 0.07, 0.08, 0.05, 0.05, 0.03],
        "lope": 0.12,
        "subWeight": 0.16,
        "orders": 16,
    },
    # 直列四：2 阶最强，高阶增长快 —— 高转"尖"。
    "i4": {
        "base": [1.00, 0.68, 0.40, 0.40, 0.24, 0.28, 0.16, 0.22,
                 0.12, 0.16, 0.09, 0.12, 0.07, 0.09, 0.05, 0.06],
        "lope": 0.14,
        "subWeight": 0.12,
        "orders": 16,
    },
    # 三缸：点火不均匀（1.5 次/转），lope 深、音调特殊。
    "i3": {
        "base": [1.00, 0.52, 0.46, 0.34, 0.28, 0.22, 0.26, 0.14,
                 0.18, 0.10, 0.13, 0.07, 0.09, 0.05, 0.06, 0.03],
        "lope": 0.40,
        "subWeight": 0.10,
        "orders": 16,
    },
}

# 排气性格 -> 脉冲锐度 / 音量 / 高频比例 / 回火倾向
EXHAUST_CHARACTERS = {
    "street":  {"pulseSharp": 0.55, "gain": 0.92, "bright": 0.62, "pop": 0.35, "growl": 0.55},
    "sport":   {"pulseSharp": 0.70, "gain": 1.00, "bright": 0.78, "pop": 0.60, "growl": 0.70},
    "race":    {"pulseSharp": 0.86, "gain": 1.10, "bright": 0.95, "pop": 0.85, "growl": 0.90},
    "open":    {"pulseSharp": 0.94, "gain": 1.16, "bright": 1.00, "pop": 1.00, "growl": 0.80},
    "quiet":   {"pulseSharp": 0.42, "gain": 0.78, "bright": 0.48, "pop": 0.15, "growl": 0.40},
}

# 进气形式 -> 涡轮参数
ASPIRATIONS = {
    "na": {
        "turbo": False, "spoolRpm": 0.0, "whistle": 0.0, "whistleHz": 0.0,
        "bov": 0.0, "induction": 0.10,
    },
    "turbo": {
        "turbo": True, "spoolRpm": 2600.0, "whistle": 0.16, "whistleHz": 3400.0,
        "bov": 0.55, "induction": 0.20,
    },
    "twin_turbo": {
        "turbo": True, "spoolRpm": 2200.0, "whistle": 0.13, "whistleHz": 2900.0,
        "bov": 0.70, "induction": 0.22,
    },
}

# EV 音色分档
EV_TIERS = {
    # 电机基频上限（Hz）与谐波洁净度：越"大功率"的高频啸叫越明显但也越粗。
    "city": {
        "maxWhineHz": 900.0, "harmonic": 0.055, "third": 0.022, "gearWhine": 0.030,
        "nvh": 0.10, "body": 0.14, "gain": 0.82,
    },
    "mainstream": {
        "maxWhineHz": 1450.0, "harmonic": 0.075, "third": 0.030, "gearWhine": 0.038,
        "nvh": 0.13, "body": 0.18, "gain": 0.90,
    },
    "performance": {
        "maxWhineHz": 1950.0, "harmonic": 0.095, "third": 0.038, "gearWhine": 0.046,
        "nvh": 0.16, "body": 0.22, "gain": 0.98,
    },
    "hyper": {
        "maxWhineHz": 2250.0, "harmonic": 0.115, "third": 0.044, "gearWhine": 0.052,
        "nvh": 0.18, "body": 0.25, "gain": 1.04,
    },
}

# ---------------------------------------------------------------------------
# 逐车覆写表
# ---------------------------------------------------------------------------
# 字段：
#   family    家族模板
#   cylinders 真实缸数（V10=10 / V12=12 未在 roster 中出现，保留支持）
#   fuel      ice / ev / hybrid
#   idle      真实怠速 rpm
#   redline   真实红线 rpm
#   asp       进气形式
#   exh       排气性格
#   evTier    EV 音色分档（仅 ev / hybrid）
#   evAssist  混动电机参与度（0~1）
#   tag       HUD / 审计用的中文备注
CARS = OrderedDict([
    # ---- 宝马 M3 E46 GTR（P60 4.0 V8，赛用）----
    ("bmw_m3_e46_gtr", dict(family="v8_cross", cylinders=8, fuel="ice", idle=900,
                            redline=8300, asp="na", exh="race", tag="P60 赛用 V8")),
    # ---- 宝马 M3 E92（S65 4.0 V8 NA）----
    ("bmw_m3_e92", dict(family="v8_cross", cylinders=8, fuel="ice", idle=950,
                        redline=8400, asp="na", exh="sport", tag="S65 高转 V8")),
    ("pandem_m3_e92", dict(family="v8_cross", cylinders=8, fuel="ice", idle=950,
                           redline=8400, asp="na", exh="open", tag="S65 排气改装")),
    # ---- 宝马 5 系 GT（N55 3.0 直六涡轮）----
    ("bmw_5_turismo", dict(family="i6", cylinders=6, fuel="ice", idle=750,
                           redline=6500, asp="turbo", exh="quiet", tag="N55 直六涡轮")),
    ("varis_m4_gts", dict(family="i6", cylinders=6, fuel="ice", idle=800,
                           redline=7200, asp="twin_turbo", exh="race", tag="S55 宽体赛用")),
    # ---- 宝马 3.0 CSL Hommage（直六涡轮 + eBoost 混动）----
    ("bmw_csl_hommage", dict(family="i6", cylinders=6, fuel="hybrid", idle=800,
                              redline=7000, asp="turbo", exh="sport", evTier="mainstream",
                              evAssist=0.55, tag="3.0 CSL 混动概念")),
    # ---- 宝马 i8（1.5 三缸涡轮 + 电机）----
    ("bmw_i8", dict(family="i3", cylinders=3, fuel="hybrid", idle=850, redline=7200,
                    asp="turbo", exh="sport", evTier="performance", evAssist=0.85,
                    tag="i8 三缸涡轮混动")),
    ("bmw_i8_acs", dict(family="i3", cylinders=3, fuel="hybrid", idle=850, redline=7200,
                        asp="turbo", exh="sport", evTier="performance", evAssist=0.85,
                        tag="i8 空力套件")),
    ("bmw_i8_lb", dict(family="i3", cylinders=3, fuel="hybrid", idle=850, redline=7200,
                       asp="turbo", exh="sport", evTier="performance", evAssist=0.85,
                       tag="i8 宽体二代")),
    # ---- 宝马 M4 系 ----
    ("bmw_m4_gts", dict(family="i6", cylinders=6, fuel="ice", idle=800, redline=7200,
                        asp="twin_turbo", exh="race", tag="S55 水喷射赛用")),
    ("bmw_m4_cabrio", dict(family="i6", cylinders=6, fuel="ice", idle=800, redline=7200,
                           asp="twin_turbo", exh="sport", tag="S55 敞篷")),
    ("bmw_m4_coupe", dict(family="i6", cylinders=6, fuel="ice", idle=800, redline=7200,
                           asp="twin_turbo", exh="sport", tag="S55 双门")),
    ("bmw_m4_gt4", dict(family="i6", cylinders=6, fuel="ice", idle=850, redline=7200,
                        asp="twin_turbo", exh="race", tag="GT4 客户赛车")),
    ("bmw_m4_g82", dict(family="i6", cylinders=6, fuel="ice", idle=800, redline=7200,
                        asp="twin_turbo", exh="sport", tag="S58 G82")),
    ("bmw_m4_adro_g82", dict(family="i6", cylinders=6, fuel="ice", idle=800, redline=7200,
                             asp="twin_turbo", exh="sport", tag="S58 ADRO 宽体")),
    ("bmw_m4_adro_kit", dict(family="i6", cylinders=6, fuel="ice", idle=800, redline=7200,
                             asp="twin_turbo", exh="sport", tag="S58 ADRO 套件")),
    ("bmw_m4_2024", dict(family="i6", cylinders=6, fuel="ice", idle=800, redline=7200,
                         asp="twin_turbo", exh="sport", tag="S58 年度改款")),
    ("bmw_m4_gt3", dict(family="i6", cylinders=6, fuel="ice", idle=900, redline=7000,
                        asp="twin_turbo", exh="race", tag="S58 GT3 赛车")),
    ("bmw_m2_g87", dict(family="i6", cylinders=6, fuel="ice", idle=800, redline=7200,
                        asp="twin_turbo", exh="sport", tag="S58 M2")),
    ("bmw_m3_touring", dict(family="i6", cylinders=6, fuel="ice", idle=800, redline=7200,
                            asp="twin_turbo", exh="sport", tag="S58 M3 旅行版")),
    # ---- 宝马 V8 系 ----
    ("bmw_x5m", dict(family="v8_cross", cylinders=8, fuel="ice", idle=750,
                     redline=6000, asp="twin_turbo", exh="sport", tag="S63 高性能 SUV")),
    ("bmw_x6m", dict(family="v8_cross", cylinders=8, fuel="ice", idle=750,
                     redline=6000, asp="twin_turbo", exh="sport", tag="S63 轿跑 SUV")),
    ("bmw_m5_f90", dict(family="v8_cross", cylinders=8, fuel="ice", idle=750,
                        redline=6000, asp="twin_turbo", exh="sport", tag="S63 四驱猛兽")),
    ("bmw_m8_cabrio", dict(family="v8_cross", cylinders=8, fuel="ice", idle=750,
                           redline=6000, asp="twin_turbo", exh="sport", tag="S63 敞篷")),
    ("bmw_m850i", dict(family="v8_cross", cylinders=8, fuel="ice", idle=750,
                       redline=6000, asp="twin_turbo", exh="sport", tag="S63 四门 GT")),
    # ---- 宝马 M6 GT3（P58 平面 V8 赛车）----
    ("bmw_m6_gt3", dict(family="v8_flat", cylinders=8, fuel="ice", idle=900,
                       redline=7000, asp="twin_turbo", exh="open", tag="P58 GT3 赛车")),
    # ---- 宝马 M5 G99（S68 V8 插混）----
    ("bmw_m5_touring", dict(family="v8_cross", cylinders=8, fuel="hybrid", idle=750,
                            redline=6000, asp="twin_turbo", exh="sport",
                            evTier="performance", evAssist=0.75, tag="S68 插混旅行")),
    ("bmw_m5_sedan", dict(family="v8_cross", cylinders=8, fuel="hybrid", idle=750,
                          redline=6000, asp="twin_turbo", exh="sport",
                          evTier="performance", evAssist=0.75, tag="S68 插混四门")),
    # ---- 其他燃油车 ----
    ("bmw_z4_m40i", dict(family="i6", cylinders=6, fuel="ice", idle=800, redline=7200,
                          asp="twin_turbo", exh="sport", tag="S58 敞篷后驱")),
    ("bmw_218i", dict(family="i3", cylinders=3, fuel="ice", idle=850, redline=6000,
                      asp="turbo", exh="quiet", tag="B38 前驱三缸")),
    ("hyundai_elantra", dict(family="i4", cylinders=4, fuel="ice", idle=700,
                              redline=6300, asp="na", exh="quiet", tag="1.6 直四")),
    ("buick_gl8", dict(family="i4", cylinders=4, fuel="ice", idle=700, redline=5500,
                       asp="turbo", exh="quiet", tag="2.0T 商务舱")),
    ("lambo_urus", dict(family="v8_cross", cylinders=8, fuel="ice", idle=750,
                        redline=6000, asp="twin_turbo", exh="sport", tag="4.0 V8 超级 SUV")),
    ("lamborghini_aventador", dict(family="v8_flat", cylinders=12, fuel="ice", idle=850,
                        redline=8250, asp="na", exh="race", tag="6.5 V12 旗舰")),
    # ---- 纯电 ----
    ("nissan_sylphy_ev", dict(family="ev", cylinders=0, fuel="ev", idle=0, redline=0,
                              asp="none", exh="quiet", evTier="city", tag="家用电车")),
    ("byd_dolphin", dict(family="ev", cylinders=0, fuel="ev", idle=0, redline=0,
                         asp="none", exh="quiet", evTier="city", tag="城市代步")),
    ("byd_songplus_ev", dict(family="ev", cylinders=0, fuel="ev", idle=0, redline=0,
                              asp="none", exh="quiet", evTier="mainstream", tag="家用 SUV")),
    ("byd_seal", dict(family="ev", cylinders=0, fuel="ev", idle=0, redline=0,
                      asp="none", exh="quiet", evTier="performance", tag="运动纯电轿车")),
    ("byd_seal06gt", dict(family="ev", cylinders=0, fuel="ev", idle=0, redline=0,
                          asp="none", exh="quiet", evTier="performance", tag="纯电钢炮")),
    ("byd_sealion", dict(family="ev", cylinders=0, fuel="ev", idle=0, redline=0,
                         asp="none", exh="quiet", evTier="performance", tag="中型纯电 SUV")),
    ("byd_yangwang_u8", dict(family="ev", cylinders=0, fuel="ev", idle=0, redline=0,
                             asp="none", exh="quiet", evTier="hyper", tag="四电机硬派越野")),
    ("nio_es7", dict(family="ev", cylinders=0, fuel="ev", idle=0, redline=0,
                     asp="none", exh="quiet", evTier="mainstream", tag="双电机中大型 SUV")),
    ("byd_yangwang_u7", dict(family="ev", cylinders=0, fuel="ev", idle=0, redline=0,
                             asp="none", exh="quiet", evTier="hyper", tag="四电机旗舰轿车")),
    ("byd_yangwang_u9", dict(family="ev", cylinders=0, fuel="ev", idle=0, redline=0,
                             asp="none", exh="quiet", evTier="hyper", tag="四电机纯电超跑")),
    ("zeekr_7x", dict(family="ev", cylinders=0, fuel="ev", idle=0, redline=0,
                      asp="none", exh="quiet", evTier="mainstream", tag="800V 纯电 SUV")),
    ("xiaomi_su7", dict(family="ev", cylinders=0, fuel="ev", idle=0, redline=0,
                        asp="none", exh="quiet", evTier="hyper", tag="高性能纯电")),
])


def build_profile(car_id, cfg):
    fuel = cfg["fuel"]
    fam_name = cfg["family"]

    if fuel == "ev":
        tier = EV_TIERS[cfg["evTier"]]
        return OrderedDict([
            ("fuel", "ev"),
            ("family", "ev"),
            ("evTier", cfg["evTier"]),
            ("maxWhineHz", tier["maxWhineHz"]),
            ("harmonic", tier["harmonic"]),
            ("third", tier["third"]),
            ("gearWhine", tier["gearWhine"]),
            ("nvh", tier["nvh"]),
            ("body", tier["body"]),
            ("gain", tier["gain"]),
            ("idleRpm", 0.0),
            ("redlineRpm", 0.0),
            # EV 也有归一化红线（电机限扭断电点），供音频侧对齐限速提示
            ("redlineNorm", GAME_REDLINES.get(car_id, 0.97)),
            ("tag", cfg["tag"]),
        ])

    fam = FAMILIES[fam_name]
    cyl = cfg["cylinders"]
    asp = ASPIRATIONS[cfg["asp"]]
    exh = EXHAUST_CHARACTERS[cfg["exh"]]

    prof = OrderedDict([
        ("fuel", fuel),
        ("family", fam_name),
        ("cylinders", cyl),
        # 四冲程：每转点火次数 = 缸数 / 2。V8=4, I6=3, I4=2, I3=1.5
        ("firingDiv", cyl / 2.0),
        ("idleRpm", float(cfg["idle"])),
        ("redlineRpm", float(cfg["redline"])),
        # 游戏内归一化红线（0.92~1.0）：断油阈值必须按这台车自己的红线算
        ("redlineNorm", GAME_REDLINES.get(car_id, 0.97)),
        ("orders", fam["orders"]),
        ("base", fam["base"]),
        ("lope", fam["lope"]),
        ("subWeight", fam["subWeight"]),
        ("pulseSharp", exh["pulseSharp"]),
        ("gain", exh["gain"]),
        ("bright", exh["bright"]),
        ("pop", exh["pop"]),
        ("growl", exh["growl"]),
        ("turbo", asp["turbo"]),
        ("spoolRpm", asp["spoolRpm"]),
        ("whistle", asp["whistle"]),
        ("whistleHz", asp["whistleHz"]),
        ("bov", asp["bov"]),
        ("induction", asp["induction"]),
        ("tag", cfg["tag"]),
    ])

    if fuel == "hybrid":
        tier = EV_TIERS[cfg["evTier"]]
        prof["evTier"] = cfg["evTier"]
        prof["evAssist"] = cfg["evAssist"]
        prof["maxWhineHz"] = tier["maxWhineHz"]
        prof["harmonic"] = tier["harmonic"]
        prof["third"] = tier["third"]
        prof["gearWhine"] = tier["gearWhine"]
        prof["nvh"] = tier["nvh"]
        prof["body"] = tier["body"]
    return prof


def main():
    cars_specs_path = os.path.join(ROOT, "data", "cars.json")
    with open(cars_specs_path, "r", encoding="utf-8") as f:
        cars_doc = json.load(f)
    roster_ids = [s["id"] for s in cars_doc["specs"]]

    missing = [cid for cid in roster_ids if cid not in CARS]
    extra = [cid for cid in CARS if cid not in roster_ids]
    if missing:
        raise SystemExit("以下 roster 车缺少引擎档案: %s" % ", ".join(missing))
    if extra:
        raise SystemExit("以下引擎档案在 roster 中不存在: %s" % ", ".join(extra))

    profiles = OrderedDict()
    for car_id in roster_ids:
        profiles[car_id] = build_profile(car_id, CARS[car_id])

    doc = OrderedDict([
        ("version", 1),
        ("_readme",
         "APEX VELOCITY 逐车引擎声音档案。由 tools/build_engine_sounds.py 生成，"
         "请勿手工编辑。firingDiv = 四冲程每转点火次数（缸数/2），"
         "真实点火频率 = rpm/60 * firingDiv，这是 V6/V8/I4 听感差异的物理来源。"),
        ("profiles", profiles),
    ])

    with open(OUT_PATH, "w", encoding="utf-8") as f:
        json.dump(doc, f, ensure_ascii=False, indent=1)
        f.write("\n")

    # ---- 自检 ----
    ice = sum(1 for p in profiles.values() if p["fuel"] == "ice")
    hyb = sum(1 for p in profiles.values() if p["fuel"] == "hybrid")
    ev = sum(1 for p in profiles.values() if p["fuel"] == "ev")
    print("[BUILD] engine_sounds.json -> %d 台 (ice %d / hybrid %d / ev %d)"
          % (len(profiles), ice, hyb, ev))

    # 点火频率抽查：确认不同缸数在同一转速下的基频关系正确
    for probe_rpm in (3000, 6000):
        line = []
        for fam, cyl in (("v8", 8), ("i6", 6), ("i4", 4), ("i3", 3)):
            f = probe_rpm / 60.0 * (cyl / 2.0)
            line.append("%s=%.0fHz" % (fam, f))
        print("[BUILD] %d rpm 点火频率: %s" % (probe_rpm, "  ".join(line)))

    for cid, p in profiles.items():
        if p["fuel"] != "ev":
            assert p["firingDiv"] == p["cylinders"] / 2.0, cid
            assert p["redlineRpm"] > p["idleRpm"], cid
    print("[BUILD] 自检通过")


if __name__ == "__main__":
    main()
