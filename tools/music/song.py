#!/usr/bin/env python3
"""曲式与混音框架：给 genres.py 提供"写歌"需要的最小结构。

分工
----
· 乐理工具（音名/音阶/和弦/织体）——纯函数，返回 MIDI 符号。
· Arrangement：把"每段几小节"的段落表展开成逐 16 分步的段落索引与强度，
  写歌时按 energy 开关元素，不必到处判段落名。
· Song：轨道总线（lane）+ 发送（混响/乒乓延迟）+ 侧链泵 + 母带。
  轨道要**手动注册**并显式给电平和发送，因为赛车曲库里"哪个元素站在
  mix 前面"正是每首歌的差异所在。
· 无缝循环：轨道缓冲比循环长度多留一段尾音（默认 2.6 s），混响/延迟
  溢出到循环点之后，master() 再 fold_loop 绕回开头叠加——接缝处既不缺
  块也不爆点。

导出格式对齐现有曲库：44.1 kHz 立体声 Vorbis、约 -18 LUFS、峰值 ≤ 0.9。
"""

import subprocess

import numpy as np
from scipy import signal as _sig

import synth as S

SR = S.SR
NOTE_SEMI = {"c": 0, "c#": 1, "db": 1, "d": 2, "d#": 3, "eb": 3, "e": 4, "f": 5,
             "f#": 6, "gb": 6, "g": 7, "g#": 8, "ab": 8, "a": 9, "a#": 10,
             "bb": 10, "b": 11}
SCALE = {
    "minor": [0, 2, 3, 5, 7, 8, 10],
    "harmonic_minor": [0, 2, 3, 5, 7, 8, 11],
    "major": [0, 2, 4, 5, 7, 9, 11],
    "dorian": [0, 2, 3, 5, 7, 9, 10],
    "phrygian": [0, 1, 3, 5, 7, 8, 10],
    "mixolydian": [0, 2, 4, 5, 7, 9, 10],
    "minor_penta": [0, 3, 5, 7, 10],
    "hungarian_minor": [0, 2, 3, 6, 7, 8, 11],
    "double_harmonic": [0, 1, 4, 5, 7, 8, 11],
}
# 各音程在第几级上（叠三度时用：根-三-五-七 = 级 0/2/4/6）
_DEG = {0: 0, 2: 1, 3: 1, 4: 2, 5: 2, 6: 3, 7: 3, 8: 4, 10: 4, 11: 5}


def note_midi(name):
    """'A2' / 'C#4' → MIDI 符号。"""
    i = 1
    while i < len(name) and name[i] in "#b":
        i += 1
    base, suffix = name[:i].lower(), name[i:]
    octv = int(suffix) if suffix else 4
    return 12 * (octv + 1) + NOTE_SEMI[base]


def note_hz(name):
    return S.midi_hz(note_midi(name))


def chord_span(root_midi, scale, degree, quality="", octave_up=0):
    """调内叠置和弦：degree 从 0 起（i=0），返回 MIDI 列表。

    和弦性质默认由音阶决定（小调的 i 自动是小三、III 自动是大三）；
    quality 只用来追加七/六音、替换挂留，或强制 m/maj/dim/aug。
    """
    steps = SCALE[scale]
    n = len(steps)

    def at(idx):
        return steps[idx % n] + 12 * (idx // n)

    iv = [at(degree), at(degree + 2), at(degree + 4)]
    if quality == "m" and iv[1] - iv[0] != 3:
        iv[1] -= 1
    elif quality == "maj" and iv[1] - iv[0] != 4:
        iv[1] += 1
    elif quality == "dim":
        iv[1] = iv[0] + 3
        iv[2] = iv[0] + 6
    elif quality == "aug":
        iv[2] += 1
    if quality in ("7", "m7", "dom7"):
        iv.append(at(degree + 6))
    elif quality == "maj7":
        iv.append(iv[0] + 11)
    elif quality in ("6", "m6"):
        iv.append(at(degree + 5))
    elif quality == "sus4":
        iv[1] = iv[0] + 5
    elif quality == "sus2":
        iv[1] = iv[0] + 2
    elif quality == "add9":
        iv.append(iv[0] + 14)
    base = root_midi + 12 * octave_up
    return [base + x for x in iv]


def scale_note(root_midi, scale, degree, octave_up=0):
    steps = SCALE[scale]
    n = len(steps)
    return root_midi + steps[degree % n] + 12 * (degree // n + octave_up)


def upoct(notes, octaves=1):
    return [m + 12 * octaves for m in notes]


def hz(notes):
    return [S.midi_hz(m) for m in notes]


class Arrangement:
    """段落表 → 逐 16 分步的段落索引与强度曲线。"""

    STEPS_PER_BAR = 16

    def __init__(self, bpm, sections):
        self.bpm = float(bpm)
        self.names = [s[0] for s in sections]
        self.bar_counts = [int(s[1]) for s in sections]
        self.energies = [float(s[2]) for s in sections]
        self.spb = 60.0 / self.bpm
        self.step = self.spb / 4.0                    # 一个 16 分音符的秒数
        self.total_bars = sum(self.bar_counts)
        self.total_steps = self.total_bars * self.STEPS_PER_BAR
        self.total_seconds = self.total_steps * self.step
        self.total_samples = int(round(self.total_seconds * SR))
        self.sec_of_step = np.zeros(self.total_steps, dtype=np.int32)
        self.energy_of_step = np.zeros(self.total_steps)
        self.sec_start_step = []
        cursor = 0
        for k, bars in enumerate(self.bar_counts):
            span = bars * self.STEPS_PER_BAR
            self.sec_of_step[cursor:cursor + span] = k
            self.energy_of_step[cursor:cursor + span] = self.energies[k]
            self.sec_start_step.append(cursor)
            cursor += span

    def step_sample(self, step):
        return int(round(step * self.step * SR))

    def duration_samples(self, steps):
        return int(round(steps * self.step * SR))

    def has_section(self, name):
        return name in self.names

    def sec_index(self, name):
        return self.names.index(name)

    def bars_of_section(self, name):
        k = self.sec_index(name)
        base = sum(self.bar_counts[:k])
        return list(range(base, base + self.bar_counts[k]))

    def bar_of_step(self, step):
        return step // self.STEPS_PER_BAR

    def bar_in_section(self, step):
        k = int(self.sec_of_step[step])
        return (step - self.sec_start_step[k]) // self.STEPS_PER_BAR

    def energy(self, step):
        return float(self.energy_of_step[step])

    def is_section(self, step, name):
        return int(self.sec_of_step[step]) == self.sec_index(name)

    def chord_at(self, step, chords):
        """chords: [(和弦标记, 持续小节数), ...] → 当前步落在哪个和弦序号。"""
        bar = step // self.STEPS_PER_BAR
        pos = 0
        for idx, entry in enumerate(chords):
            span = int(entry[1])
            if bar < pos + span:
                return idx
            pos += span
        return len(chords) - 1

    def steps_of_bars(self, bars):
        for bar in bars:
            for k in range(self.STEPS_PER_BAR):
                yield bar * self.STEPS_PER_BAR + k


class Lane:
    __slots__ = ("name", "buf", "gain", "send_rev", "send_dly", "hp", "lp",
                 "duck", "duck_depth", "duck_release")

    def __init__(self, name, n, gain=0.5, send_rev=0.0, send_dly=0.0,
                 hp=0.0, lp=0.0, duck=False, duck_depth=0.42, duck_release=0.19):
        self.name = name
        self.buf = np.zeros((2, n))
        self.gain = gain
        self.send_rev = send_rev
        self.send_dly = send_dly
        self.hp = hp
        self.lp = lp
        self.duck = duck
        self.duck_depth = duck_depth
        self.duck_release = duck_release


class Song:
    """一首曲子：编排 + 轨道 + 混音 + 母带。"""

    def __init__(self, arr, seed=1, rev_seconds=1.9, rev_decay=1.5,
                 tail_seconds=2.6, lufs_target=-21.0, ceiling_db=-1.6, label="",
                 post_eq=None, mono_target_db=1.2):
        self.arr = arr
        self.seed = int(seed)
        self.rng = np.random.default_rng(seed)
        self.label = label
        self.lufs_target = float(lufs_target)
        self.ceiling_db = float(ceiling_db)
        self.mono_target_db = float(mono_target_db)
        self.post_eq = list(post_eq or ())
        self.source_lufs = 0.0
        self.gain_db = 0.0
        self.loop_n = arr.total_samples
        self.buf_n = arr.total_samples + int(round(tail_seconds * SR))
        self.lanes = {}
        self.kick_samples = []
        self._ir_l = S.make_ir(rev_seconds, rev_decay, seed=seed + 11, lp_hz=11500.0)
        self._ir_r = S.make_ir(rev_seconds * 1.06, rev_decay * 1.08, seed=seed + 29,
                               lp_hz=9600.0, predelay_ms=17.0)

    # -- 轨道 -------------------------------------------------------------
    def lane(self, name, **kw):
        if name not in self.lanes:
            self.lanes[name] = Lane(name, self.buf_n, **kw)
        elif kw:
            for key, value in kw.items():
                setattr(self.lanes[name], key, value)
        return self.lanes[name]

    def put(self, lane_name, sig, step, gain=1.0, pan=0.0, offset_sec=0.0):
        """事件入轨。等功率声像：pan=0 时两路各 -3 dB， mono 向下混合不丢电平。"""
        ln = self.lanes[lane_name]
        pos = self.arr.step_sample(step) + int(offset_sec * SR)
        x = np.asarray(sig, dtype=np.float64)
        if x.size == 0:
            return
        if x.ndim == 1:
            angle = (float(np.clip(pan, -1.0, 1.0)) + 1.0) * np.pi / 4.0
            two = np.vstack([x * np.cos(angle), x * np.sin(angle)])
        else:
            two = x
            if abs(pan) > 1e-6:
                angle = (float(np.clip(pan, -1.0, 1.0)) + 1.0) * np.pi / 4.0
                # 立体声源：整体平移但不破坏原有相关性
                two = np.vstack([two[0] * np.cos(angle) * 1.4142,
                                 two[1] * np.sin(angle) * 1.4142])
        S.place(ln.buf, S.fade_edges(two), pos, gain)

    def mark_kick(self, step, strength=1.0):
        self.kick_samples.append((self.arr.step_sample(step), float(strength)))

    # -- 混音 -------------------------------------------------------------
    def mixdown(self):
        n = self.buf_n
        hits = [h for h, _ in self.kick_samples]
        out = np.zeros((2, n))
        for ln in self.lanes.values():
            x = ln.buf
            if not np.any(x):
                continue
            if ln.hp > 20.0:
                x = np.vstack([S.highpass(x[c], ln.hp, order=2) for c in (0, 1)])
            if 0.0 < ln.lp < SR * 0.45:
                x = np.vstack([S.lowpass(x[c], ln.lp, order=2) for c in (0, 1)])
            if ln.duck and hits:
                env = S.duck_envelope(n, hits, ln.duck_depth, 0.005, ln.duck_release)
                x = x * env[None, :]
            out += x * ln.gain
            mono = x.mean(axis=0)
            if ln.send_rev > 0.0:
                wet = np.vstack([S.convolve(mono, self._ir_l), S.convolve(mono, self._ir_r)])
                out += wet[:, :n] * (ln.send_rev * ln.gain)
            if ln.send_dly > 0.0:
                ping = S.pingpong_delay(mono, self.arr.step * 3.0, 0.40, 1.0)[: , :n]
                out += ping * (ln.send_dly * ln.gain * 0.5)
        return out

    # -- 母带 -------------------------------------------------------------
    def master(self, x):
        """粘合 EQ → 曲风后置 EQ → 单声道安全宽度 → LUFS 对齐 → 前瞻限制器 → 折回循环。

        这里**不做**总线 tanh：软削峰把峰值与响度之间的余量（crest）从
        19 dB 压到 6 dB，整曲变成一堵墙，和曲库现有 18-20 dB 的呼吸感完全
        两样。动态只交给带前瞻的限制器处理，瞬态保住、峰值封顶。
        """
        arr = np.atleast_2d(x)
        arr = self._glue(arr)
        for freq, db, q in (self.post_eq or ()):
            arr = peaking(arr, freq, db, q)
        arr = self._mono_safe(arr, self.mono_target_db)
        self.source_lufs = lufs_of(arr)
        self.gain_db = self.lufs_target - self.source_lufs
        arr = arr * S.gain_to_lufs(arr, self.lufs_target)
        arr = S.limiter(arr, self.ceiling_db, release_ms=90.0)
        return self._fold_to_loop(arr)

    def _mono_safe(self, arr, target_db=1.2):
        """把 Side 分量收窄到"折单声道只掉 target_db 以内"。

        混响双 IR、乒乓延迟、超锯齿扩散叠起来能让 stereo→mono 掉 3-4 dB，
        笔记本外放下就会比曲库现有曲子明显小声。M/S 解析式一次算完：
        L=M+kS、R=M-kS 时 drop = 10log10(1 + k²·Ps/Pm)，反解 k 即可。
        宽度是连续可调的，不必砍混响或砍立体声源。
        """
        m = (arr[0] + arr[1]) * 0.5
        s = (arr[0] - arr[1]) * 0.5
        pm = float(np.mean(m ** 2)) + 1e-12
        ps = float(np.mean(s ** 2))
        if ps <= 1e-12 or target_db <= 0.0:
            return np.vstack([m, m]) if target_db <= 0.0 else arr
        ratio = 10.0 ** (target_db / 10.0)
        k = min(1.0, float(np.sqrt(pm * (ratio - 1.0) / ps)))
        return np.vstack([m + k * s, m - k * s])

    def _glue(self, arr):
        """总线整形：扣一点浑浊低频、抬一点空气，让不同曲风落到同一档。"""
        out = peaking(arr, 250.0, -1.4, 1.0)
        out = peaking(out, 3200.0, 1.0, 1.1)
        out = peaking(out, 11000.0, 1.5, 0.7)
        return out

    def _fold_to_loop(self, arr):
        """循环点之后的尾音绕回开头叠加，再做 8 ms 等功率交叉淡化。"""
        keep = self.loop_n
        out = arr[:, :keep].copy()
        tail = arr[:, keep:]
        k = min(tail.shape[1], keep)
        if k:
            out[:, :k] += tail[:, :k]
        fade = int(0.008 * SR)
        ramp = np.linspace(0.0, 1.0, fade)
        out[:, :fade] = out[:, :fade] * ramp + out[:, -fade:] * (1.0 - ramp)
        out[:, -fade:] *= 0.0
        return out

    # -- 便捷渲染 ---------------------------------------------------------
    def render(self, eq=None):
        if eq is not None:
            self.post_eq = list(eq)
        return self.master(self.mixdown())


def lufs_of(x, sr=SR):
    return S.lufs(x, sr)


def loudness_report(x):
    """峰值 / RMS / 立体声 LUFS / 折成单声道的 LUFS（mono 掉多少 = 空间层风险）。"""
    mono = S.lufs(S.to_stereo(np.asarray(x).mean(axis=0)))
    return {"peak": S.peak_db(x), "rms": S.rms_db(x), "lufs": S.lufs(x),
            "mono_lufs": mono, "mono_drop": S.lufs(x) - mono}


# ---------------------------------------------------------------------------
# EQ（RBJ 双二阶）
# ---------------------------------------------------------------------------
def peaking(x, freq, db, q=1.0, sr=SR):
    arr = np.atleast_2d(np.asarray(x, dtype=np.float64))
    w = 2.0 * np.pi * min(freq, sr * 0.45) / sr
    alpha = np.sin(w) / (2.0 * max(q, 0.05))
    a_g = 10.0 ** (db / 40.0)
    b = np.array([a_g, -2.0 * np.cos(w) * a_g, a_g])
    a = np.array([1.0 + alpha / a_g, -2.0 * np.cos(w), 1.0 - alpha / a_g])
    b = b / a[0]
    a = a / a[0]
    return np.vstack([_sig.lfilter(b, a, arr[c]) for c in range(arr.shape[0])])


def shelf(x, freq, db, kind="low", sr=SR):
    arr = np.atleast_2d(np.asarray(x, dtype=np.float64))
    a_g = 10.0 ** (db / 40.0)
    w0 = 2.0 * np.pi * min(freq, sr * 0.45) / sr
    cw, sw = np.cos(w0), np.sin(w0)
    q = 0.707
    alpha = sw / (2.0 * q)
    beta = 2.0 * np.sqrt(a_g) * alpha
    if kind == "low":
        b = np.array([a_g * ((a_g + 1) - (a_g - 1) * cw + beta),
                      2 * a_g * ((a_g - 1) - (a_g + 1) * cw),
                      a_g * ((a_g + 1) - (a_g - 1) * cw - beta)])
        a = np.array([(a_g + 1) + (a_g - 1) * cw + beta,
                      -2 * ((a_g - 1) + (a_g + 1) * cw),
                      (a_g + 1) + (a_g - 1) * cw - beta])
    else:
        b = np.array([a_g * ((a_g + 1) + (a_g - 1) * cw + beta),
                      -2 * a_g * ((a_g - 1) + (a_g + 1) * cw),
                      a_g * ((a_g + 1) + (a_g - 1) * cw - beta)])
        a = np.array([(a_g + 1) - (a_g - 1) * cw + beta,
                      2 * ((a_g - 1) - (a_g + 1) * cw),
                      (a_g + 1) - (a_g - 1) * cw - beta])
    b = b / a[0]
    a = a / a[0]
    return np.vstack([_sig.lfilter(b, a, arr[c]) for c in range(arr.shape[0])])


def ffmpeg_bin():
    try:
        import imageio_ffmpeg
        return imageio_ffmpeg.get_ffmpeg_exe()
    except Exception:
        return "ffmpeg"


def encode_ogg(wav_path, ogg_path, bitrate="160k"):
    cmd = [ffmpeg_bin(), "-y", "-loglevel", "error", "-i", wav_path,
           "-c:a", "libvorbis", "-b:a", bitrate, ogg_path]
    subprocess.run(cmd, check=True)
    return ogg_path
