#!/usr/bin/env python3
"""曲风构建器：每个函数把一首完整的赛车 BGM 写到 Song 的轨道上。

约定
----
· 鼓组用 16 字符模式串描述一小节：X 重击 / x 轻击 / . 休止。
  段落能量（Arrangement.energy）低于阈值时自动抽稀，避免每段手写一遍。
· 和声进行在 spec['prog'] 里给 (级数, 性质, 小节数)，旋律动机在
  spec['motif'] 里给 (相对和弦音下标, 16 分步偏移, 时长步数)。
  这样换调/换 BPM 只改 spec，不用动代码。
· 每条轨道显式给 gain / send / duck —— 赛车的"贴地感"来自侧链泵和
  次低频层，这两个必须看得见参数，不能藏在默认值里。
"""

import numpy as np

import song as G
import synth as S
import voices as V


def _pat_count(pattern, step16):
    c = pattern[step16 % len(pattern)]
    return c


def _hits(pattern, steps, energy=0.0, min_energy=0.0):
    """遍历步序号，命中模式串里的 X/x 时给出 (step, 力度)。"""
    if energy < min_energy:
        return
    for s in steps:
        c = pattern[s % len(pattern)]
        if c == "X":
            yield s, 1.0
        elif c == "x":
            yield s, 0.55
        elif c == "o":
            yield s, 0.32


def _bars_range(arr, names):
    out = []
    for nm in names:
        if arr.has_section(nm):
            out.extend(arr.bars_of_section(nm))
    return sorted(set(out))


def _steps(arr, names, bars=None):
    bars = bars if bars is not None else _bars_range(arr, names)
    for bar in bars:
        for k in range(arr.STEPS_PER_BAR):
            yield bar * arr.STEPS_PER_BAR + k


def _prog_chords(spec, bars):
    """把 (级数, 性质, 小节数) 表展开成逐小节的和弦序号表。"""
    prog = spec["prog"]
    out = []
    for entry in prog:
        for _ in range(int(entry[2])):
            out.append((entry[0], entry[1] if len(entry) > 1 else ""))
    while len(out) < bars:
        out.extend(out[:max(len(out), 1)])
    return out[:bars]


def _root_midi(spec):
    return G.note_midi(spec["root"])


def _chord_at(spec, arr, step, octv=0):
    prog = _prog_chords(spec, arr.total_bars)
    bar = arr.bar_of_step(step)
    deg, qual = prog[bar % len(prog)]
    return G.chord_span(_root_midi(spec), spec["scale"], deg, qual, octv)


def _note_at(spec, arr, step, degree_idx, octv=0):
    notes = _chord_at(spec, arr, step, octv)
    return notes[degree_idx % len(notes)]


def _drums(sg, arr, spec, kick_pat, snare_pat, hat_pat, perc=None,
           kick_voice=None, snare_voice=None, hat_voice=None, snare_lane="snare"):
    """通用鼓组落轨：按段落能量抽稀，并记录底鼓位置供侧链使用。"""
    for s in range(arr.total_steps):
        e = arr.energy(s)
        bar_pos = s % 16
        c = kick_pat[bar_pos]
        if c in "Xx" and e >= (0.30 if c == "x" else 0.18):
            sg.put("kick", (kick_voice or V.kick)(), s, gain=1.0 if c == "X" else 0.72)
            sg.mark_kick(s)
        c = snare_pat[bar_pos]
        if c in "Xx" and e >= 0.42:
            sg.put(snare_lane, (snare_voice or V.snare)(decay=spec.get("snare_decay", 0.2)),
                   s, gain=1.0 if c == "X" else 0.66, pan=0.06)
        c = hat_pat[bar_pos]
        if c in "Xxo" and e >= 0.34:
            open_hat = c == "o"
            gain = {"X": 0.95, "x": 0.6, "o": 1.05}[c]
            sg.put("hat", (hat_voice or V.hat)(open=open_hat, decay=spec.get("hat_decay", 0.05)),
                   s, gain=gain * (0.7 + 0.3 * e), pan=-0.24 if bar_pos % 4 == 2 else 0.22)
        if perc:
            for lane_name, pattern, voice in perc:
                c = pattern[bar_pos]
                if c in "Xx" and e >= 0.5:
                    sg.put(lane_name, voice(), s, gain=1.0 if c == "X" else 0.6,
                           pan=0.4 if bar_pos % 8 < 4 else -0.4)


def _fill(sg, arr, spec, at_bars, tom_steps=(0, 4, 8, 10, 12, 13, 14, 15)):
    """过鼓：段落最后一小节末尾的嗵鼓滚奏 + 反向镲。"""
    for bar in at_bars:
        base = bar * 16
        for k, pos in enumerate(tom_steps):
            s = base + pos
            if s >= arr.total_steps:
                continue
            freq = 150.0 + 70.0 * (len(tom_steps) - k) / len(tom_steps)
            sg.put("perc", V.tom(freq=freq, decay=0.22), s,
                   gain=0.7 + 0.03 * k, pan=(-0.35 if k % 2 else 0.35))


def _crash(sg, arr, names):
    for nm in names:
        if not arr.has_section(nm):
            continue
        s = arr.bars_of_section(nm)[0] * 16
        if s < arr.total_steps:
            sg.put("cym", V.crash(decay=1.6), s, gain=0.5, pan=0.15)


def _riser(sg, arr, before_names, seconds=2.0):
    for nm in before_names:
        if not arr.has_section(nm):
            continue
        first = arr.bars_of_section(nm)[0] * 16
        dur_steps = int(seconds / arr.step)
        start = max(0, first - dur_steps)
        sg.put("fx", V.riser(seconds=max(0.4, (first - start) * arr.step),
                             lo=380.0, hi=9800.0), start, gain=0.5)


def _sub_drop(sg, arr, names):
    for nm in names:
        if not arr.has_section(nm):
            continue
        s = arr.bars_of_section(nm)[0] * 16
        sg.put("fx", V.impact(freq=64.0, decay=1.8), s, gain=0.65)


def _bass_line(sg, arr, spec, steps_pattern, voice, octv=-1, gate=2, glide=False):
    """按步模式铺贝斯：根音为主，命中 'x' 时用五音，尾部自动留出衰减。"""
    pattern = spec.get("bass_pat", steps_pattern)
    for s in range(arr.total_steps):
        if arr.energy(s) < 0.30:
            continue
        c = pattern[s % len(pattern)]
        if c not in "Xxo-":
            continue
        if c == "-":
            continue
        notes = _chord_at(spec, arr, s, octv)
        idx = 0 if c in "Xx" else 0
        freq = S.midi_hz(notes[idx])
        if c == "o":
            freq = S.midi_hz(notes[2])       # 五音点缀
        dur = arr.duration_samples(gate) * 0.94
        sig = voice(freq, dur / S.SR)
        sg.put("bass", sig, s, gain=1.0 if c == "X" else 0.8)


def _arp(sg, arr, spec, lane, voice, steps=(0, 2, 4, 6, 8, 10, 12, 14),
         octv=1, order=(0, 1, 2, 1), min_energy=0.45, gate=2, level=1.0):
    for s in range(arr.total_steps):
        if arr.energy(s) < min_energy or (s % 16) not in steps:
            continue
        notes = _chord_at(spec, arr, s, octv)
        k = (s // 16) % len(order)
        idx = (order[k] + (s % 16) // 2) % len(notes)
        sig = voice(S.midi_hz(notes[idx]), arr.step * gate * 0.92)
        sg.put(lane, sig, s, gain=level * (0.85 + 0.15 * np.sin(s)),
               pan=-0.3 if (s % 4) < 2 else 0.3)


def _chord_stabs(sg, arr, spec, lane, voice, beats=(0, 8), octv=1,
                 min_energy=0.4, gate=2, level=1.0):
    for s in range(arr.total_steps):
        if arr.energy(s) < min_energy or (s % 16) not in beats:
            continue
        notes = G.hz(_chord_at(spec, arr, s, octv))
        dur = arr.step * gate * 0.9
        sg.put(lane, voice(np.full(arr.duration_samples(gate), notes[0]), dur, level=0.6),
               s, gain=level, pan=-0.18 if (s % 16) == 0 else 0.18)


def _pad(sg, arr, spec, lane, octv=0, min_energy=0.35, level=0.3, bars_each=2):
    for bar in range(0, arr.total_bars, bars_each):
        s = bar * 16
        if arr.energy(s) < min_energy:
            continue
        notes = G.hz(_chord_at(spec, arr, s, octv))
        dur = arr.step * 16 * bars_each
        sg.put(lane, V.pad(notes, dur, level=level, cut=spec.get("pad_cut", 1700.0)),
               s, gain=1.0)


def _lead(sg, arr, spec, lane, octv=2, min_energy=0.62, level=0.45, voice=None):
    """主旋律：按 motif 的 (和弦音下标, 步, 时长) 逐小节移位到当前和弦上。"""
    motif = spec.get("motif")
    if not motif:
        return
    voice = voice or (lambda f, d, lvl=0.5: V.supersaw(np.full(int(d * S.SR), f), d, level=lvl))
    for bar in range(arr.total_bars):
        base = bar * 16
        if arr.energy(base) < min_energy:
            continue
        notes = _chord_at(spec, arr, base, octv)
        # 每两小节换个八度落点，避免 32 小节一条线听疲
        if (bar // 2) % 2 == 1:
            notes = [n - 12 for n in notes]
        for entry in motif:
            idx, pos, dur_steps = entry[0], entry[1], entry[2]
            accent = entry[3] if len(entry) > 3 else 1.0
            s = base + pos
            if s >= arr.total_steps:
                continue
            f = S.midi_hz(notes[idx % len(notes)])
            d = arr.step * dur_steps * 0.96
            sg.put(lane, voice(f, d, level), s, gain=accent, pan=0.0)


# ---------------------------------------------------------------------------
# 曲风
# ---------------------------------------------------------------------------
def build_eurobeat(sg, arr, spec):
    """欧驱（150+ BPM）：四踩底鼓 + 反拍镲 + 8 分门切超锯齿 +  octave 滚奏贝斯。

    这是赛车曲库里"最燃"的一档：和声大调小调混合、副歌必须能跟唱，
    贝斯全程 8 分音符八度跳动提供推进力。
    """
    sg.lane("kick", gain=0.92, hp=30.0)
    sg.lane("snare", gain=0.6, send_rev=0.16, hp=180.0)
    sg.lane("hat", gain=0.26, hp=6200.0)
    sg.lane("bass", gain=0.8, duck=True, duck_depth=0.40, lp=1100.0)
    sg.lane("stab", gain=0.30, duck=True, duck_depth=0.5, send_rev=0.2, hp=220.0)
    sg.lane("arp", gain=0.22, duck=True, send_rev=0.26, send_dly=0.18, hp=400.0)
    sg.lane("lead", gain=0.40, duck=True, send_rev=0.3, send_dly=0.14, hp=260.0)
    sg.lane("pad", gain=0.20, send_rev=0.4, duck=True, duck_depth=0.62, hp=140.0)
    sg.lane("perc", gain=0.3, send_rev=0.24, hp=300.0)
    sg.lane("cym", gain=0.3, send_rev=0.4, hp=2200.0)
    sg.lane("fx", gain=0.34, send_rev=0.3, hp=90.0)

    _drums(sg, arr, spec, "X...X...X...X...", "....X.......X...", "..x...xo..x...xo")
    # 贝斯：根音八度 8 分跳动，反拍抬高八度
    for s in range(arr.total_steps):
        if arr.energy(s) < 0.32 or (s % 2):
            continue
        notes = _chord_at(spec, arr, s, -1)
        oct_up = 12 if (s % 4) == 2 else 0
        f = S.midi_hz(notes[0] + oct_up)
        sg.put("bass", V.bass_saw(f, arr.step * 2 * 0.9, cut=spec.get("bass_cut", 900.0),
                                 voices=2, drive=1.8), s)
    # 门切和声（pumping chords）：每个反拍一次
    for s in range(arr.total_steps):
        if arr.energy(s) < 0.42 or (s % 4) != 2:
            continue
        notes = G.hz(_chord_at(spec, arr, s, 1))
        sg.put("stab", V.supersaw(np.full(arr.duration_samples(2), notes[0]),
                                 arr.step * 2 * 0.85, level=0.5, cut=3000.0, voices=5),
               s, gain=1.0 if arr.energy(s) > 0.8 else 0.72)
    _arp(sg, arr, spec, "arp", lambda f, d: V.pluck(f, d, level=0.5, bright=1.15),
         steps=tuple(range(0, 16, 2)), octv=2, min_energy=0.6, gate=2,
         order=(0, 1, 2, 3, 2, 1), level=0.85)
    _pad(sg, arr, spec, "pad", octv=0, min_energy=0.34, level=0.34, bars_each=2)
    _lead(sg, arr, spec, "lead", octv=2, min_energy=0.62, level=0.5)
    _riser(sg, arr, ["drop"], seconds=2.4)
    _riser(sg, arr, ["break"], seconds=1.2)
    _sub_drop(sg, arr, ["drop"])
    _crash(sg, arr, ["drop", "refrain", "break"])
    _fill(sg, arr, spec, [b for b in range(arr.total_bars)
                          if arr.bar_in_section(b * 16) >= 0
                          and arr.energy(min(b * 16 + 12, arr.total_steps - 1)) > 0.55
                          and (b + 1) < arr.total_bars
                          and arr.energy((b + 1) * 16) <= arr.energy(b * 16) + 0.02][:8])


def build_electro_house(sg, arr, spec):
    """大空间电子/未来弹跳：侧链抽吸极重，主音短促，drop 用齐奏锯齿墙。"""
    sg.lane("kick", gain=0.95, hp=32.0)
    sg.lane("snare", gain=0.5, send_rev=0.2, hp=200.0)
    sg.lane("clap", gain=0.55, send_rev=0.22, hp=240.0)
    sg.lane("hat", gain=0.24, hp=6400.0)
    sg.lane("bass", gain=0.78, duck=True, duck_depth=0.34, lp=950.0)
    sg.lane("sub", gain=0.7, duck=True, duck_depth=0.4)
    sg.lane("pluck", gain=0.3, duck=True, send_rev=0.24, send_dly=0.2, hp=320.0)
    sg.lane("lead", gain=0.42, duck=True, send_rev=0.28, hp=240.0)
    sg.lane("pad", gain=0.24, duck=True, duck_depth=0.66, send_rev=0.45, hp=160.0)
    sg.lane("perc", gain=0.26, send_rev=0.3, hp=420.0)
    sg.lane("cym", gain=0.28, send_rev=0.45, hp=2400.0)
    sg.lane("fx", gain=0.36, send_rev=0.3, hp=60.0)

    _drums(sg, arr, spec, "X...X...X...X...", "................", "..x...x...x...x.",
           snare_voice=lambda **kw: V.clap(**kw))
    # 16 分贝斯：根音-八度交替，只在段落中段发力
    for s in range(arr.total_steps):
        e = arr.energy(s)
        if e < 0.45 or (s % 2) or (s % 16) in (0, 4, 8, 12):
            continue
        notes = _chord_at(spec, arr, s, -1)
        f = S.midi_hz(notes[0] + (12 if (s % 8) == 6 else 0))
        sg.put("bass", V.bass_saw(f, arr.step * 2 * 0.82, cut=780.0, voices=1, drive=1.6),
               s, gain=0.9)
    for s in range(arr.total_steps):
        if arr.energy(s) < 0.4 or (s % 16) not in (0, 6, 8, 14):
            continue
        notes = _chord_at(spec, arr, s, -2)
        sg.put("sub", V.bass_sub(S.midi_hz(notes[0]), arr.step * 6 * 0.9), s, gain=0.85)
    _arp(sg, arr, spec, "pluck", lambda f, d: V.pluck(f, d, level=0.55, cut=6200.0),
         steps=(0, 3, 6, 8, 11, 14), octv=2, min_energy=0.5, gate=3, level=0.9,
         order=(0, 2, 1, 3))
    _pad(sg, arr, spec, "pad", octv=0, min_energy=0.32, level=0.42, bars_each=2)
    _lead(sg, arr, spec, "lead", octv=2, min_energy=0.66, level=0.46,
          voice=lambda f, d, lvl=0.5: V.supersaw(np.full(int(d * S.SR), f), d, level=lvl,
                                                 voices=7, detune=0.014, cut=3600.0, drive=1.6))
    _riser(sg, arr, ["drop"], seconds=2.2)
    _sub_drop(sg, arr, ["drop"])
    _crash(sg, arr, ["drop", "refrain"])


def build_dnb(sg, arr, spec):
    """鼓打贝斯（172-176）：两段式踩镲 + 2-step 军鼓 + Reese 贝斯 + 液态铺底。"""
    sg.lane("kick", gain=0.9, hp=34.0)
    sg.lane("snare", gain=0.62, send_rev=0.24, hp=190.0)
    sg.lane("hat", gain=0.2, hp=7000.0)
    sg.lane("ride", gain=0.16, hp=5200.0)
    sg.lane("bass", gain=0.82, duck=True, duck_depth=0.44, lp=1400.0)
    sg.lane("sub", gain=0.78, duck=True, duck_depth=0.5)
    sg.lane("pad", gain=0.3, send_rev=0.5, hp=180.0, duck=True, duck_depth=0.7)
    sg.lane("pluck", gain=0.24, send_rev=0.3, send_dly=0.26, hp=380.0)
    sg.lane("lead", gain=0.36, send_rev=0.34, hp=260.0, duck=True, duck_depth=0.6)
    sg.lane("perc", gain=0.24, send_rev=0.3, hp=500.0)
    sg.lane("cym", gain=0.26, send_rev=0.5, hp=2200.0)
    sg.lane("fx", gain=0.32, send_rev=0.4, hp=70.0)

    _drums(sg, arr, spec, "X.......X..X....", "....X.......X...", "xxXxxxXxxxXxxxXx",
           kick_voice=lambda: V.kick(tune=52.0, drop_to=34.0, decay=0.2, click=0.34),
           snare_voice=lambda **kw: V.snare(tone=205.0, decay=0.16, snap=1.0))
    # 踩镲 32 分加花 + ride 常开：DnB 的速度感全在这一层
    for s in range(arr.total_steps):
        if arr.energy(s) < 0.7:
            continue
        sg.put("hat", V.hat(decay=0.03), s + 0.5, gain=0.35, pan=0.3)
    for s in range(arr.total_steps):
        if arr.energy(s) > 0.4 and (s % 8) == 4:
            sg.put("ride", V.ride(decay=0.35), s, gain=0.4, pan=-0.3)
    # Reese 长音贝斯 + 次低音八度
    for s in range(arr.total_steps):
        if (s % 16) not in (0, 6, 10):
            continue
        if arr.energy(s) < 0.4:
            continue
        notes = _chord_at(spec, arr, s, -2)
        gate = 6 if (s % 16) == 0 else 4
        f = S.midi_hz(notes[0])
        sg.put("bass", V.bass_reese(f, arr.step * gate * 0.95, cut=spec.get("bass_cut", 460.0)),
               s, gain=1.0)
        sg.put("sub", V.bass_sub(f, arr.step * gate * 0.95), s, gain=0.8)
    _pad(sg, arr, spec, "pad", octv=0, min_energy=0.28, level=0.4, bars_each=2)
    _arp(sg, arr, spec, "pluck", lambda f, d: V.pluck(f, d, level=0.5, cut=5600.0),
         steps=tuple(range(0, 16, 3)), octv=2, min_energy=0.55, gate=3, level=0.8,
         order=(0, 1, 2, 3, 1))
    _lead(sg, arr, spec, "lead", octv=1, min_energy=0.66, level=0.4,
          voice=lambda f, d, lvl=0.5: V.bell(f, d, level=lvl, decay=min(0.9, d * 0.6)))
    _riser(sg, arr, ["drop"], seconds=2.6)
    _sub_drop(sg, arr, ["drop"])
    _crash(sg, arr, ["drop", "refrain"])


def build_breakbeat(sg, arr, spec):
    """破碎节拍（135-145）：切分底鼓军鼓 + 摇摆沙锤 + 门切锯齿 + 部落打击层。"""
    sg.lane("kick", gain=0.9, hp=32.0)
    sg.lane("snare", gain=0.56, send_rev=0.22, hp=200.0)
    sg.lane("hat", gain=0.22, hp=6600.0)
    sg.lane("shaker", gain=0.2, hp=4200.0)
    sg.lane("bass", gain=0.8, duck=True, duck_depth=0.4, lp=1200.0)
    sg.lane("stab", gain=0.3, duck=True, send_rev=0.26, hp=300.0)
    sg.lane("lead", gain=0.36, send_rev=0.3, send_dly=0.2, hp=280.0)
    sg.lane("pad", gain=0.22, send_rev=0.42, duck=True, duck_depth=0.66, hp=150.0)
    sg.lane("perc", gain=0.34, send_rev=0.34, hp=260.0)
    sg.lane("cym", gain=0.26, send_rev=0.46, hp=2100.0)
    sg.lane("fx", gain=0.34, send_rev=0.36, hp=80.0)

    _drums(sg, arr, spec, "X.....X..X...X..", "....X.....x.X...", "x.X.x.x.x.X.x.x.",
           kick_voice=lambda: V.kick(tune=56.0, drop_to=40.0, decay=0.22, click=0.26),
           snare_voice=lambda **kw: V.snare(tone=210.0, decay=0.14, snap=0.95))
    for s in range(arr.total_steps):
        if arr.energy(s) < 0.5 or (s % 2):
            continue
        sg.put("shaker", V.shaker(decay=0.06), s, gain=0.5 if (s % 8) == 0 else 0.32,
               pan=0.42)
    # 切分贝斯：三对四的重音位移，做出"往前拽"的手感
    bass_pat = "X..x..X...x.X..."
    for s in range(arr.total_steps):
        c = bass_pat[s % 16]
        if c not in "Xx" or arr.energy(s) < 0.4:
            continue
        notes = _chord_at(spec, arr, s, -1)
        f = S.midi_hz(notes[0] + (12 if c == "x" else 0))
        sg.put("bass", V.bass_saw(f, arr.step * 3 * 0.9, cut=880.0, drive=2.0), s)
    for s in range(arr.total_steps):
        if (s % 16) in (2, 7, 11) and arr.energy(s) > 0.55:
            notes = G.hz(_chord_at(spec, arr, s, 1))
            sg.put("stab", V.supersaw(np.full(arr.duration_samples(2), notes[0]),
                                     arr.step * 2 * 0.8, level=0.5, cut=3400.0),
                   s, pan=(-0.25 if (s % 16) == 2 else 0.25))
    _pad(sg, arr, spec, "pad", octv=0, min_energy=0.3, level=0.34, bars_each=2)
    _lead(sg, arr, spec, "lead", octv=2, min_energy=0.6, level=0.42)
    for bar in _bars_range(arr, ["drop", "refrain"]):
        for pos in (0, 3, 6, 11):
            s = bar * 16 + pos
            if s < arr.total_steps:
                sg.put("perc", V.tom(freq=190.0 + 40 * (pos % 3), decay=0.24), s,
                       gain=0.55, pan=0.4 if pos < 6 else -0.4)
    _riser(sg, arr, ["drop"], seconds=2.2)
    _crash(sg, arr, ["drop", "refrain"])


def build_techno_industrial(sg, arr, spec):
    """工业/技术（134-144）：失真四踩 + 303 酸贝斯 + 金属打击 + 催眠式琶音。

    不写大旋律，靠谐振峰值、噪声扫频和逐步叠加制造压迫感。
    """
    sg.lane("kick", gain=0.94, hp=34.0)
    sg.lane("clap", gain=0.42, send_rev=0.3, hp=300.0)
    sg.lane("hat", gain=0.24, hp=6800.0)
    sg.lane("bass", gain=0.74, duck=True, duck_depth=0.36, lp=2200.0)
    sg.lane("sub", gain=0.66, duck=True, duck_depth=0.5)
    sg.lane("arp", gain=0.24, send_rev=0.3, send_dly=0.3, hp=500.0, duck=True, duck_depth=0.62)
    sg.lane("stab", gain=0.26, send_rev=0.36, hp=400.0)
    sg.lane("pad", gain=0.2, send_rev=0.5, hp=200.0)
    sg.lane("perc", gain=0.36, send_rev=0.4, hp=320.0)
    sg.lane("cym", gain=0.22, send_rev=0.5, hp=2600.0)
    sg.lane("fx", gain=0.42, send_rev=0.42, hp=60.0)

    for s in range(arr.total_steps):
        e = arr.energy(s)
        pos = s % 16
        if pos % 4 == 0 and e >= 0.3:
            sg.put("kick", V.kick(tune=64.0, drop_to=44.0, decay=0.24, click=0.4, body=1.05), s)
            sg.mark_kick(s)
            if e > 0.72:
                sg.put("kick", V.kick(tune=48.0, drop_to=36.0, decay=0.1, click=0.2), s,
                       gain=0.4, offset_sec=0.006)
        if pos in (4, 12) and e > 0.5:
            sg.put("clap", V.clap(decay=0.16), s, pan=0.1)
        if pos % 2 == 1 and e > 0.6:
            sg.put("hat", V.hat(decay=0.035, open=(pos == 14)), s,
                   gain=0.7 if pos % 4 == 2 else 0.45, pan=-0.3 if pos < 8 else 0.3)
        if pos in (3, 10) and e > 0.75:
            sg.put("perc", V.impact(freq=320.0, decay=0.5, sub=0.4, air=0.8), s,
                   gain=0.5, pan=0.45)
    # 303：16 分走批，随机重音 + 偶尔长尾
    acid_pat = "X-X-x---X-xX--x-"
    accents = sg.rng.random(16)
    for s in range(arr.total_steps):
        c = acid_pat[s % 16]
        if c not in "Xx-" or arr.energy(s) < 0.42:
            continue
        notes = _chord_at(spec, arr, s, -1)
        idx = [0, 2, 1, 3][(s // 3) % 4]
        f = S.midi_hz(notes[idx % len(notes)] + (12 if c == "x" else 0))
        acc = float(accents[s % 16])
        sg.put("bass", V.bass_acid(f, arr.step * (2 if c == "X" else 1) * 0.9,
                                   accent=0.5 + acc, decay=0.14 + 0.1 * acc), s,
               gain=0.85 + 0.3 * acc)
    for s in range(arr.total_steps):
        if (s % 16) == 0 and arr.energy(s) > 0.5:
            notes = _chord_at(spec, arr, s, -2)
            sg.put("sub", V.bass_sub(S.midi_hz(notes[0]), arr.step * 15 * 0.95), s, gain=0.7)
    _arp(sg, arr, spec, "arp", lambda f, d: V.pluck(f, d, level=0.42, cut=7200.0, decay=0.13),
         steps=tuple(range(16)), octv=2, min_energy=0.62, gate=1, level=0.55,
         order=(0, 1, 2, 3, 2, 1, 0, 2))
    for s in range(arr.total_steps):
        if (s % 16) in (0, 8) and arr.energy(s) > 0.78:
            notes = G.hz(_chord_at(spec, arr, s, 1))
            sg.put("stab", V.supersaw(np.full(arr.duration_samples(6), notes[1]),
                                     arr.step * 6 * 0.8, level=0.42, cut=2400.0, res=0.4),
                   s)
    _pad(sg, arr, spec, "pad", octv=1, min_energy=0.3, level=0.3, bars_each=4)
    _riser(sg, arr, ["drop"], seconds=3.2)
    _sub_drop(sg, arr, ["drop"])


def build_trance(sg, arr, spec):
    """渐进 Trance（128-136）：反拍贝斯 + 16 分琶音瀑布 + 超锯齿副歌主旋律。"""
    sg.lane("kick", gain=0.92, hp=32.0)
    sg.lane("clap", gain=0.5, send_rev=0.24, hp=220.0)
    sg.lane("hat", gain=0.26, hp=6200.0)
    sg.lane("bass", gain=0.72, duck=True, duck_depth=0.32, lp=1050.0)
    sg.lane("sub", gain=0.72, duck=True, duck_depth=0.46)
    sg.lane("arp", gain=0.26, duck=True, send_rev=0.32, send_dly=0.26, hp=380.0)
    sg.lane("lead", gain=0.44, duck=True, send_rev=0.36, send_dly=0.12, hp=240.0)
    sg.lane("pad", gain=0.26, duck=True, duck_depth=0.6, send_rev=0.5, hp=150.0)
    sg.lane("perc", gain=0.24, send_rev=0.34, hp=460.0)
    sg.lane("cym", gain=0.28, send_rev=0.5, hp=2300.0)
    sg.lane("fx", gain=0.34, send_rev=0.4, hp=70.0)

    _drums(sg, arr, spec, "X...X...X...X...", "....X...x...X...", "..o...x...o...x.",
           snare_lane="clap", snare_voice=lambda **kw: V.clap(decay=0.18))
    # 反拍贝斯（offbeat bass）：trance 的引擎
    for s in range(arr.total_steps):
        if (s % 2) != 1 or arr.energy(s) < 0.4:
            continue
        notes = _chord_at(spec, arr, s, -1)
        f = S.midi_hz(notes[0])
        sg.put("bass", V.bass_saw(f, arr.step * 2 * 0.8, cut=spec.get("bass_cut", 720.0),
                                 voices=1, drive=1.5), s)
        if (s % 8) == 3:
            sg.put("sub", V.bass_sub(f, arr.step * 4 * 0.9), s - 1, gain=0.7)
    _arp(sg, arr, spec, "arp", lambda f, d: V.pluck(f, d, level=0.46, cut=6800.0, decay=0.16),
         steps=tuple(range(16)), octv=1, min_energy=0.5, gate=1, level=0.8,
         order=(0, 1, 2, 3, 2, 1))
    _arp(sg, arr, spec, "arp", lambda f, d: V.pluck(f, d, level=0.3, cut=9000.0, decay=0.1),
         steps=(1, 5, 9, 13), octv=2, min_energy=0.8, gate=1, level=0.5, order=(2, 0, 3, 1))
    _pad(sg, arr, spec, "pad", octv=0, min_energy=0.3, level=0.4, bars_each=2)
    _lead(sg, arr, spec, "lead", octv=2, min_energy=0.62, level=0.5,
          voice=lambda f, d, lvl=0.5: V.supersaw(np.full(int(d * S.SR), f), d, level=lvl,
                                                 voices=7, detune=0.016, cut=4200.0,
                                                 vib_hz=5.4, vib_cents=14.0, vib_delay=0.2))
    _riser(sg, arr, ["drop"], seconds=3.6)
    _sub_drop(sg, arr, ["drop"])
    _crash(sg, arr, ["drop", "refrain"])


def build_orchestral_hybrid(sg, arr, spec):
    """管弦混合（108-118）：太鼓 + 铜管重音 + 弦乐 16 分连弓 + 合唱垫。

    没有电子底鼓，推进力来自定音鼓滚奏、弦乐震音密度和铜管的下拍齐奏。
    """
    sg.lane("kick", gain=0.72, hp=26.0)
    sg.lane("perc", gain=0.5, send_rev=0.42, hp=120.0)
    sg.lane("bass", gain=0.6, lp=420.0)
    sg.lane("strings", gain=0.4, send_rev=0.5, hp=110.0)
    sg.lane("brass", gain=0.42, send_rev=0.36, hp=180.0)
    sg.lane("choir", gain=0.26, send_rev=0.6, hp=200.0)
    sg.lane("lead", gain=0.4, send_rev=0.44, hp=240.0)
    sg.lane("cym", gain=0.3, send_rev=0.6, hp=1800.0)
    sg.lane("fx", gain=0.4, send_rev=0.5, hp=45.0)

    for s in range(arr.total_steps):
        e = arr.energy(s)
        pos = s % 16
        if pos in (0, 8) and e > 0.34:
            sg.put("kick", V.kick_acoustic(decay=0.42, tone=54.0, beater=0.12), s, gain=0.95)
        if pos in (4, 12) and e > 0.55:
            sg.put("perc", V.impact(freq=150.0, decay=0.7, sub=0.7, air=0.35), s, gain=0.8)
        if e > 0.7 and pos % 2 == 0:
            sg.put("perc", V.tom(freq=260.0, decay=0.12, tune_drop=0.2, skin=0.5), s,
                   gain=0.35, pan=0.5 if pos % 4 == 0 else -0.5)
        if e > 0.85 and pos % 4 == 2:
            sg.put("cym", V.ride(decay=0.4), s, gain=0.3, pan=-0.2)
    # 弦乐连弓织体：16 分反复当前和弦音，逐小节改变音型
    for s in range(arr.total_steps):
        e = arr.energy(s)
        if e < 0.45:
            continue
        step_in_bar = s % 16
        density = 1 if e > 0.8 else 2
        if step_in_bar % density:
            continue
        notes = _chord_at(spec, arr, s, 0)
        seq = (0, 2, 1, 2)
        idx = seq[(s // density) % len(seq)]
        f = S.midi_hz(notes[idx % len(notes)] + 12)
        sg.put("strings", V.strings([f], arr.step * density * 0.92, level=0.5,
                                    attack=0.012, release=0.05),
               s, gain=0.85 if step_in_bar % 4 == 0 else 0.6,
               pan=-0.45 if idx % 2 else 0.45)
    for s in range(arr.total_steps):
        if (s % 16) in (0, 6) and arr.energy(s) > 0.55:
            notes = G.hz(_chord_at(spec, arr, s, 0))
            sg.put("brass", V.brass(np.full(arr.duration_samples(6), notes[0]),
                                    arr.step * 6 * 0.9, level=0.55,
                                    cut=2900.0), s, gain=1.0 if (s % 16) == 0 else 0.8)
    for s in range(arr.total_steps):
        if (s % 16) == 0 and arr.energy(s) > 0.6:
            notes = _chord_at(spec, arr, s, 0)
            sg.put("bass", V.bass_sub(S.midi_hz(notes[0] - 12), arr.step * 16 * 0.96), s,
                   gain=0.8)
    for bar in range(0, arr.total_bars, 2):
        s = bar * 16
        if arr.energy(s) < 0.72:
            continue
        notes = G.hz(_chord_at(spec, arr, s, 1))
        sg.put("choir", V.choir(notes, arr.step * 32, level=0.3, attack=0.5), s)
    _lead(sg, arr, spec, "lead", octv=1, min_energy=0.66, level=0.46,
          voice=lambda f, d, lvl=0.5: V.brass(np.full(int(d * S.SR), f), d, level=lvl,
                                              cut=3200.0, voices=3, drive=1.4))
    _riser(sg, arr, ["drop"], seconds=2.8)
    for nm in ("drop", "refrain"):
        if arr.has_section(nm):
            s = arr.bars_of_section(nm)[0] * 16
            sg.put("fx", V.impact(freq=70.0, decay=2.2), s, gain=0.8)
            sg.put("cym", V.crash(decay=2.2), s, gain=0.55)


def build_phonk_drift(sg, arr, spec):
    """漂移 Phonk（140-148）：808 滑音 + 牛铃旋律 + 脆军鼓 + 黑胶底噪。"""
    sg.lane("kick", gain=0.86, hp=30.0)
    sg.lane("snare", gain=0.5, send_rev=0.18, hp=220.0)
    sg.lane("hat", gain=0.22, hp=6400.0)
    sg.lane("bass", gain=0.86, lp=1500.0)
    sg.lane("cowbell", gain=0.3, send_rev=0.24, send_dly=0.16, hp=500.0)
    sg.lane("lead", gain=0.3, send_rev=0.34, hp=300.0)
    sg.lane("pad", gain=0.22, send_rev=0.5, hp=180.0)
    sg.lane("perc", gain=0.24, send_rev=0.3, hp=400.0)
    sg.lane("vinyl", gain=0.1, hp=1200.0)
    sg.lane("cym", gain=0.22, send_rev=0.4, hp=2400.0)
    sg.lane("fx", gain=0.34, send_rev=0.36, hp=60.0)

    _drums(sg, arr, spec, "X.....X...X.....", "....X.......X...", "x.Xxx.X.x.Xxx.X.",
           kick_voice=lambda: V.kick(tune=48.0, drop_to=32.0, decay=0.3, click=0.2),
           snare_voice=lambda **kw: V.snare(tone=230.0, decay=0.13, snap=1.1))
    # 808：跟和弦根音，每个音从上一个音滑过来（漂移的推背感就在这里）
    prev = None
    for s in range(arr.total_steps):
        if (s % 16) not in (0, 3, 8, 11) or arr.energy(s) < 0.4:
            continue
        f = S.midi_hz(_chord_at(spec, arr, s, -2)[0])
        glide = f * 1.5 if prev is None else prev
        sg.put("bass", V.bass_808(f, arr.step * 6 * 0.95, glide_from=glide, drive=2.4), s,
               gain=1.0 if (s % 16) == 0 else 0.8)
        prev = f
    # 牛铃旋律：小调五声，切分重复
    for s in range(arr.total_steps):
        if arr.energy(s) < 0.55 or (s % 16) not in (0, 3, 6, 8, 11, 14):
            continue
        notes = _chord_at(spec, arr, s, 1)
        f = S.midi_hz(notes[(s // 3) % len(notes)])
        sg.put("cowbell", _cowbell(f, arr.step * 2 * 0.8), s,
               gain=0.85 if (s % 8) == 0 else 0.6, pan=0.3 if (s % 4) < 2 else -0.3)
    _pad(sg, arr, spec, "pad", octv=0, min_energy=0.3, level=0.34, bars_each=4)
    _lead(sg, arr, spec, "lead", octv=2, min_energy=0.7, level=0.34,
          voice=lambda f, d, lvl=0.5: V.pluck(f, d, level=lvl, cut=4200.0, decay=0.3, voices=3))
    sg.put("vinyl", V.vinyl_crackle(arr.total_seconds, level=1.0), 0)
    _riser(sg, arr, ["drop"], seconds=1.8)
    _sub_drop(sg, arr, ["drop"])


def _cowbell(freq, seconds, level=0.5, sr=S.SR):
    """808 牛铃：两个非整数比方波 + 带通。"""
    n = int(seconds * sr)
    t = np.arange(n) / sr
    a = S.square(np.full(n, freq * 0.649), 0.5, sr=sr)
    b = S.square(np.full(n, freq), 0.5, sr=sr)
    x = S.bandpass(a + b, max(freq * 1.6, 200.0), min(freq * 6.2, sr * 0.45), order=2, sr=sr)
    return x * S.thd_env(n, 0.002, 0.22, sr=sr) * level


BUILDERS = {
    "eurobeat": build_eurobeat,
    "electro_house": build_electro_house,
    "dnb": build_dnb,
    "breakbeat": build_breakbeat,
    "techno_industrial": build_techno_industrial,
    "trance": build_trance,
    "orchestral_hybrid": build_orchestral_hybrid,
    "phonk_drift": build_phonk_drift,
}


def build_song(spec, seed=None):
    """spec → 渲染后的立体声 float 数组（已母带、可无缝循环），连同编排与 Song。"""
    arr = G.Arrangement(spec["bpm"], spec["sections"])
    song = G.Song(arr, seed=spec.get("seed", 1) if seed is None else seed,
                  rev_seconds=spec.get("rev_seconds", 1.9),
                  rev_decay=spec.get("rev_decay", 1.5),
                  lufs_target=spec.get("lufs", -21.0),
                  ceiling_db=spec.get("ceiling", -1.6),
                  post_eq=spec.get("post_eq"),
                  mono_target_db=spec.get("mono_target_db", 1.2),
                  label=spec.get("id", ""))
    BUILDERS[spec["genre"]](song, arr, spec)
    return song.render(), arr, song
