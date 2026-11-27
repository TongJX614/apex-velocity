#!/usr/bin/env python3
"""11 条赛道的"第二主题曲"规格表——纯数据，改风格只改这一份。

编排原则
--------
· 一条赛道一首，genre 与该赛道**已有**那首拉开差距（海岸已有 100 BPM 电影
  电子 → 新曲给 150 BPM 欧陆节拍；都会已有 Future Garage → 给 Electro House）。
· 全部按"节奏感强、有激情"来配：BPM 128-176，鼓组全程 4/4 或碎拍，段落
  一定含 build → drop 的推力，副歌有可哼的主奏动机。
· 循环长度对齐现有曲库（22-35 s），段落数 6 段、16 小节，母带口径 -21 LUFS
  （与曲库实测一致，不是清单里的标称值）。
· 每个 spec 字段都喂给 genres.py：bpm/root/scale/prog/motif/sections/genre，
  post_eq 是该曲风的母带惯用手感（DNB/Phonk 补次低频，其它不补）。
"""

GENRE_DISPLAY = {
    "eurobeat": "EUROBEAT",
    "electro_house": "ELECTRO HOUSE",
    "dnb": "DRUM & BASS",
    "breakbeat": "BREAKBEAT",
    "techno_industrial": "INDUSTRIAL TECHNO",
    "trance": "UPLIFT TRANCE",
    "orchestral_hybrid": "ORCHESTRAL HYBRID",
    "phonk_drift": "DRIFT PHONK",
}

M16 = [(0, "m", 2), (5, "", 2), (8, "", 2), (7, "", 2)]          # i-VI-VII-vii（小调推进）
M8 = [(0, "m", 1), (0, "m", 1), (6, "", 1), (5, "", 1),
      (0, "m", 1), (3, "", 1), (6, "", 1), (5, "", 1)]          # 和声小调 8 小节循环
PHR = [(0, "", 2), (6, "", 2), (3, "", 2), (5, "", 2)]          # 弗里吉亚黑暗色彩
BRK = [(0, "m", 2), (2, "", 2), (5, "", 2), (4, "", 2),
       (0, "m", 2), (2, "", 2), (5, "", 2), (5, "", 2)]         # 碎拍 8 小节
PHK = [(0, "m", 2), (0, "m", 2), (6, "", 2), (5, "", 2)]        # Phonk 两和弦拉扯

# (相对和弦音下标, 16 分步偏移, 时长步数)
MOTIF_LONG = [(0, 0, 4), (2, 4, 2), (4, 6, 4), (7, 10, 2), (5, 12, 4), (2, 14, 2)]
MOTIF_SHORT = [(0, 0, 6), (4, 6, 4), (2, 10, 2), (5, 12, 4)]
MOTIF_PENTA = [(0, 0, 4), (2, 4, 4), (3, 8, 2), (4, 10, 4), (2, 14, 2)]
MOTIF_DRONE = [(4, 0, 8), (2, 8, 4), (0, 12, 4)]


def _layout(intro=2, build=2, drop=4, verse=4, build2=0, refrain=4):
    out = [("intro", intro, 0.32), ("build", build, 0.58), ("drop", drop, 1.0),
           ("verse", verse, 0.62)]
    if build2:
        out.append(("build2", build2, 0.78))
    out.append(("refrain", refrain, 0.95))
    return out


# 16 小节循环：2+2+4+4+4
L16 = _layout()
# 带二次加建的 18 小节
L18 = _layout(drop=4, verse=2, build2=2, refrain=4)
# 管弦：段落更长才呼吸得开
L16_LONG = _layout(intro=2, build=2, drop=6, verse=2, refrain=4)

SUB_SHELF = [(46.0, 3.0, 0.8)]                                   # DNB/Phonk 次低频补偿
AIR_TOP = [(12000.0, 1.5, 0.7)]

TRACKS = [
    {
        "map": "coast", "id": "turbo", "file": "bgm/turbo.ogg",
        "name": "TURBO TIDE", "cn": "涡轮潮汐",
        "genre": "eurobeat", "bpm": 150, "color": "#4fe9c8",
        "root": "F", "scale": "minor", "prog": M16, "motif": MOTIF_LONG,
        "sections": L16, "lead_oct": 1, "seed": 101,
        "note": "海岸已有 100 BPM 电影电子，这首补高速欧陆节拍：150 BPM 四踩 + 超锯齿齐奏。",
    },
    {
        "map": "city", "id": "chrome", "file": "bgm/chrome.ogg",
        "name": "CHROME ENGINE", "cn": "镀铬引擎",
        "genre": "techno_industrial", "bpm": 138, "color": "#5ff3ff",
        "root": "A", "scale": "minor", "prog": PHR, "motif": MOTIF_DRONE,
        "sections": L16, "seed": 202, "bass_cut": 900.0, "supersaw_cut": 2400.0,
        "note": "夜里下雨的都市：303 酸线 + 金属打击，节奏压迫但不抢霓虹氛围。",
    },
    {
        "map": "alpine", "id": "summit", "file": "bgm/summit.ogg",
        "name": "SUMMIT CHASE", "cn": "峰顶追击",
        "genre": "dnb", "bpm": 172, "color": "#9fd8ff",
        "root": "E", "scale": "harmonic_minor", "prog": M8, "motif": MOTIF_SHORT,
        "sections": L16, "lead_oct": 1, "seed": 303, "bass_cut": 1600.0,
        "post_eq": SUB_SHELF,
        "note": "隘口连续弯配 172 BPM 鼓打贝斯，和声小调给雪山一点危险感。",
    },
    {
        "map": "canyon", "id": "sundown", "file": "bgm/sundown.ogg",
        "name": "SUNDOWN GT", "cn": "落日 GT",
        "genre": "electro_house", "bpm": 130, "color": "#ff7a3d",
        "root": "D", "scale": "minor", "prog": M16, "motif": MOTIF_SHORT,
        "sections": L16, "lead_oct": 1, "seed": 404,
        "note": "峡谷尘土 + 落日，四踩 house 的推进感比现有 tribal techno 更直给。",
    },
    {
        "map": "harbor", "id": "harborlight", "file": "bgm/harborlight.ogg",
        "name": "HARBORLIGHT RUN", "cn": "港灯夜奔",
        "genre": "trance", "bpm": 128, "color": "#ffb45e",
        "root": "A", "scale": "minor", "prog": M16, "motif": MOTIF_LONG,
        "sections": L18, "lead_oct": 1, "seed": 505,
        "note": "港湾黄昏：16 分琶音瀑布 + 反拍贝斯，比现有 synthwave 更有推力。",
    },
    {
        "map": "skyline", "id": "overture", "file": "bgm/overture.ogg",
        "name": "SKYLINE OVERTURE", "cn": "天际裂响",
        "genre": "orchestral_hybrid", "bpm": 118, "color": "#ffb547",
        "root": "D", "scale": "harmonic_minor", "prog": M8, "motif": MOTIF_LONG,
        "sections": L16_LONG, "lead_oct": 0, "seed": 606,
        "note": "环城高架要史诗感：太鼓 + 弦乐 16 分连弓 + 铜管重音，不用电子鼓。",
    },
    {
        "map": "glacier", "id": "whiteflash", "file": "bgm/whiteflash.ogg",
        "name": "WHITE FLASH", "cn": "白闪",
        "genre": "dnb", "bpm": 176, "color": "#7fd8ff",
        "root": "F#", "scale": "harmonic_minor", "prog": M8, "motif": MOTIF_SHORT,
        "sections": L16, "lead_oct": 1, "seed": 707, "bass_cut": 1500.0,
        "post_eq": SUB_SHELF,
        "note": "冰面低抓地 + 极速：现有两首都在 116 以下，这首给 176 BPM 的密度。",
    },
    {
        "map": "pass", "id": "touge", "file": "bgm/touge.ogg",
        "name": "TOUGE RUN", "cn": "峠疾走",
        "genre": "breakbeat", "bpm": 140, "color": "#9fd8b0",
        "root": "G", "scale": "minor", "prog": BRK, "motif": MOTIF_SHORT,
        "sections": L16, "lead_oct": 1, "seed": 808,
        "note": "雾岭山道即峠：碎拍 + Reese 贝斯，比现有管弦更贴『车在动』这件事。",
    },
    {
        "map": "magma", "id": "forgefire", "file": "bgm/forgefire.ogg",
        "name": "FORGE FIRE", "cn": "炉火",
        "genre": "techno_industrial", "bpm": 144, "color": "#ff4a1a",
        "root": "F", "scale": "minor", "prog": PHR, "motif": MOTIF_DRONE,
        "sections": L16, "seed": 909, "bass_cut": 1000.0, "supersaw_cut": 2800.0,
        "note": "熔岩盆地已有两首工业系，这首更吵更高 BPM，靠梯式滤波扫频拉开距离。",
    },
    {
        "map": "metro", "id": "ringroad", "file": "bgm/ringroad.ogg",
        "name": "RING ROAD", "cn": "环线暴走",
        "genre": "electro_house", "bpm": 134, "color": "#ff9d3c",
        "root": "B", "scale": "phrygian", "prog": PHR, "motif": MOTIF_SHORT,
        "sections": L16, "lead_oct": 1, "seed": 1010,
        "note": "白天都会环线：主和弦大跳 + 开口锯齿贝斯，比 Future Garage 更外放。",
    },
    {
        "map": "drift", "id": "hairpin", "file": "bgm/hairpin.ogg",
        "name": "HAIRPIN", "cn": "发卡反打",
        "genre": "phonk_drift", "bpm": 152, "color": "#ffd23c",
        "root": "C", "scale": "minor", "prog": PHK, "motif": MOTIF_PENTA,
        "sections": L16, "lead_oct": 1, "seed": 1111,
        "post_eq": SUB_SHELF,
        "note": "漂移练习：现有 phonk 是 132 BPM，这首 152 + 808 滑音 + 牛铃，反打更狠。",
    },
]

BY_MAP = {t["map"]: t for t in TRACKS}
