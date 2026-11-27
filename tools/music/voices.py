#!/usr/bin/env python3
"""器乐音色：全部由 synth.py 的原语数学生成，不依赖任何采样素材。

命名约定
--------
每个函数返回**单事件**波形（1-D 或 (2, n)），时长由参数决定，调用方负责
放到总缓冲的正确位置。首尾由调用处统一 fade，避免叠加咔哒。

关键做法
--------
· 底鼓 = 指数下滑正弦 + 点击噪声，两者幅度比例决定"硬/圆"。
· 808 = 正弦 + 端口滑音 + tanh 泛音；纯弦波在笔记本喇叭上会消失，
  所以靠饱和补 2/3 次谐波而不是直接抬低频。
· 超锯齿 = N 只略微失谐的限带锯齿 + 单边声道扩散，是 trance/eurobeat
  主题厚度的唯一来源；扩散必须和单声道兼容（先 Mid 再 Side）。
· 弦乐/合唱 = 锯齿堆过**共振峰带通**，用几提前的 Formant 峰模拟人声/
  琴身，比堆谐波更像真实乐器。
"""

import numpy as np
from scipy import signal

import synth as S


# ---------------------------------------------------------------------------
# 鼓组
# ---------------------------------------------------------------------------
def kick(tune=58.0, drop_to=38.0, decay=0.30, click=0.30, click_hz=1900.0,
         body=1.0, punch=0.42, n=None, sr=S.SR):
    """电子底鼓：正弦体（频率指数下滑）+ 高频点击。

    tune→drop_to 的下滑时间常数决定"砰"还是"咚"：drop 越接近 tune 越紧。
    """
    dur = decay * 1.9 + 0.03 if n is None else n / sr
    n = int(dur * sr)
    t = np.arange(n) / sr
    f = drop_to + (tune - drop_to) * np.exp(-t / max(punch * 0.09, 0.001))
    ph = S.phase_of(f, sr)
    env = np.exp(-t / max(decay * 0.42, 0.005))
    body_sig = np.sin(ph) * env * body
    # 基频下滑带一点负向偏移会积累 DC，这里显式阻断
    body_sig = S.dc_block(body_sig)
    cl = S.filtered_noise(int(0.02 * sr), click_hz, sr=sr, seed=7)
    cl = cl * np.exp(-np.arange(cl.size) / sr / 0.004)
    out = body_sig
    out[:cl.size] += cl * click * 3.0
    return S.normalize(out, 0.98) * body


def _resonator(x, freq, q, sr=S.SR):
    """2 极点谐振器：噪声激励出的衰减正弦，即鼓腔/管体的一个耦合模式。

    butter 的 bandpass 要 [lo, hi] 且峰宽不可控，做不出"某个模式响多久"；
    这里由 q 直接给环响时间常数（-1/ln r = 2q/w），稳定又可预测。
    """
    x = np.asarray(x, dtype=np.float64)
    w = S.TAU * min(max(float(freq), 20.0), sr * 0.45) / sr
    r = float(np.exp(-w / (2.0 * max(q, 0.3))))
    return signal.lfilter([1.0 - r, 0.0, 0.0], [1.0, -2.0 * r * np.cos(w), r * r], x)


def kick_acoustic(decay=0.24, tone=118.0, beater=0.28, n=None, sr=S.SR):
    """真鼓质感：低 Q 共振体 + 鼓皮敲击，管弦/摇滚段落用，别和电子底鼓混。"""
    dur = (decay * 2.2 + 0.05) if n is None else n / sr
    n = int(dur * sr)
    x = S.filtered_noise(n, 210.0, sr=sr, seed=3)
    sos_body = np.zeros(n)
    # 两个耦合模式：基模 + 1.6 倍泛音，做出"胸腔"感
    for freq, gain, q in ((tone, 1.0, 7.0), (tone * 1.62, 0.45, 11.0)):
        sos_body += gain * _resonator(x, freq, q, sr)
    env = np.exp(-np.arange(n) / sr / max(decay * 0.35, 0.005))
    out = S.dc_block(sos_body * env)
    bt = S.filtered_noise(int(0.012 * sr), 3200.0, sr=sr, seed=11)
    bt = bt * np.exp(-np.arange(bt.size) / sr / 0.003)
    out[:bt.size] += bt * beater
    return S.normalize(out, 0.95)


def snare(tone=190.0, decay=0.20, snap=0.85, band=(1500.0, 6800.0), n=None, sr=S.SR):
    """军鼓：腔体正弦 + 带通噪声响弦。band 决定"干/亮"。"""
    dur = (decay * 2.4 + 0.02) if n is None else n / sr
    n = int(dur * sr)
    t = np.arange(n) / sr
    body = np.sin(S.phase_of(np.full(n, tone) * (0.85 + 0.15 * np.exp(-t / 0.01)), sr))
    body *= np.exp(-t / max(decay * 0.28, 0.004))
    nz = S.noise(n, sr, seed=13)
    nz = S.bandpass(nz, band[0], band[1], order=2, sr=sr)
    nz *= np.exp(-t / max(decay * 0.55, 0.006))
    out = body * 0.55 + nz * snap
    return S.normalize(out, 0.95)


def clap(layers=3, spacing=0.011, decay=0.20, band=(900.0, 5600.0), n=None, sr=S.SR):
    """拍手：几提前的窄带噪声副本叠加，形成"啪"的密集起音。"""
    dur = (decay + spacing * layers + 0.05) if n is None else n / sr
    n = int(dur * sr)
    out = np.zeros(n)
    for k in range(layers):
        seg_n = int((decay * (1.0 - 0.18 * k) + 0.02) * sr)
        seg = S.bandpass(S.noise(seg_n, sr, seed=21 + k), band[0], band[1], order=3, sr=sr)
        seg *= np.exp(-np.arange(seg_n) / sr / max(decay * 0.30, 0.004))
        i0 = int(k * spacing * sr)
        out[i0:i0 + seg.size] += seg * (1.0 - 0.12 * k)
    tail = S.bandpass(S.noise(int(decay * sr), sr, seed=44), band[0], band[1] * 1.2, order=2, sr=sr)
    tail *= np.exp(-np.arange(tail.size) / sr / max(decay * 0.6, 0.01))
    out[:tail.size] += tail * 0.5
    return S.normalize(out, 0.95)


def hat(open=False, decay=0.045, band=(7200.0, 15500.0), metal=1.0, n=None, sr=S.SR):
    """踩镲：金属比值谐波堆 + 高通噪声。open 只是拉长衰减。"""
    dur = (0.30 if open else decay * 3.0) + 0.02 if n is None else n / sr
    n = int(min(dur, 1.0) * sr)
    t = np.arange(n) / sr
    base = 40.0 * metal
    stack = np.zeros(n)
    for mult in (1.0, 1.342, 1.229, 2.500, 1.876, 3.142):
        stack += np.sin(S.phase_of(np.full(n, base * mult * 22.0), sr))
    stack = S.highpass(stack, 6200.0, order=2, sr=sr)
    nz = S.highpass(S.noise(n, sr, seed=31), band[0], order=2, sr=sr)
    nz = S.lowpass(nz, band[1], order=2, sr=sr)
    out = stack * 0.35 + nz * 0.85
    dec = 0.30 if open else decay
    out *= np.exp(-t / max(dec * 0.42, 0.003))
    return S.normalize(out, 0.9)


def tom(freq=165.0, decay=0.30, tune_drop=0.35, skin=0.25, n=None, sr=S.SR):
    """嗵鼓/部落鼓：下滑正弦 + 一点点鼓皮噪声。"""
    dur = (decay * 2.2 + 0.05) if n is None else n / sr
    n = int(dur * sr)
    t = np.arange(n) / sr
    f = freq * (1.0 - tune_drop * (1.0 - np.exp(-t / max(decay * 0.22, 0.004))))
    body = np.sin(S.phase_of(f, sr)) * np.exp(-t / max(decay * 0.45, 0.006))
    nz = S.lowpass(S.noise(n, sr, seed=51), 2600.0, order=2, sr=sr)
    nz *= np.exp(-t / 0.012)
    out = S.dc_block(body + nz * skin)
    return S.normalize(out, 0.95)


def crash(decay=1.5, band=(2600.0, 13000.0), n=None, sr=S.SR):
    dur = (decay * 1.6 + 0.05) if n is None else n / sr
    n = int(dur * sr)
    t = np.arange(n) / sr
    nz = S.bandpass(S.noise(n, sr, seed=61), band[0], band[1], order=2, sr=sr)
    ring = np.zeros(n)
    for mult in (1.0, 1.412, 1.702, 2.342):
        ring += np.sin(S.phase_of(np.full(n, 812.0 * mult), sr))
    ring = S.highpass(ring, 1800.0, order=2, sr=sr) * np.exp(-t / (decay * 0.6))
    out = nz * np.exp(-t / max(decay * 0.42, 0.01)) * 0.9 + ring * 0.22
    return S.normalize(out, 0.9)


def ride(decay=0.5, n=None, sr=S.SR):
    dur = (decay * 2.0 + 0.03) if n is None else n / sr
    n = int(dur * sr)
    t = np.arange(n) / sr
    ping = np.sin(S.phase_of(np.full(n, 3100.0), sr)) * np.exp(-t / 0.09)
    nz = S.highpass(S.noise(n, sr, seed=71), 6800.0, order=2, sr=sr)
    nz *= np.exp(-t / max(decay * 0.4, 0.01))
    return S.normalize(ping * 0.5 + nz * 0.8, 0.9)


def shaker(decay=0.08, band=(4200.0, 10500.0), n=None, sr=S.SR):
    dur = (decay * 3.0 + 0.02) if n is None else n / sr
    n = int(dur * sr)
    t = np.arange(n) / sr
    env = np.sin(np.pi * np.clip(t / max(decay * 2.4, 0.01), 0.0, 1.0)) ** 1.5
    nz = S.bandpass(S.noise(n, sr, seed=81), band[0], band[1], order=3, sr=sr)
    return S.normalize(nz * env, 0.9)


def impact(freq=88.0, decay=1.4, sub=1.0, air=0.5, n=None, sr=S.SR):
    """电影式撞击：次低频下沉 + 空气感噪声，用于段落起点。"""
    dur = (decay * 1.4 + 0.05) if n is None else n / sr
    n = int(dur * sr)
    t = np.arange(n) / sr
    f = freq * (0.55 + 0.45 * np.exp(-t / 0.05))
    body = np.sin(S.phase_of(f, sr)) * np.exp(-t / max(decay * 0.32, 0.02))
    nz = S.lowpass(S.noise(n, sr, seed=91), 900.0, order=2, sr=sr) * np.exp(-t / 0.06)
    air_nz = S.highpass(S.noise(n, sr, seed=92), 4000.0, order=2, sr=sr)
    air_nz *= np.exp(-t / max(decay * 0.5, 0.02))
    out = S.dc_block(body * sub + nz * 0.5 + air_nz * air * 0.35)
    return S.normalize(out, 0.95)


def riser(seconds=2.0, lo=420.0, hi=9200.0, shape=3.0, n=None, sr=S.SR, seed=101):
    """加建：噪声过带通上扫 + 音高上行正弦，段落最后 2-4 小节用。"""
    n = int(seconds * sr) if n is None else n
    t = np.arange(n) / sr
    k = S.curve(n, "exp", shape)
    x = S.noise(n, sr, seed=seed)
    # 逐样本带通用不了，改成按 64 段分段带通再拼接
    segs = 64
    out = np.zeros(n)
    per = n // segs + 1
    for i in range(segs):
        i0, i1 = i * per, min((i + 1) * per, n)
        if i0 >= n:
            break
        c = lo + (hi - lo) * (i / max(segs - 1, 1)) ** 1.4
        blk = S.bandpass(x[max(0, i0 - 512):i1], max(c * 0.55, 60.0), min(c * 1.8, sr * 0.45), order=2, sr=sr)
        out[i0:i1] = blk[blk.size - (i1 - i0):]
    tone = np.sin(S.phase_of(lo + (hi - lo) * 0.28 * k, sr)) * 0.25
    env = k ** 0.8 * np.clip((t / seconds) * 6.0, 0.0, 1.0)
    return S.normalize((out * 0.9 + tone) * env, 0.9)


def downlifter(seconds=1.2, start_hz=2600.0, n=None, sr=S.SR, seed=111):
    """反加建：段落结束后往下泄的气声。"""
    n = int(seconds * sr) if n is None else n
    t = np.arange(n) / sr
    x = S.noise(n, sr, seed=seed)
    segs = 48
    out = np.zeros(n)
    per = n // segs + 1
    for i in range(segs):
        i0, i1 = i * per, min((i + 1) * per, n)
        if i0 >= n:
            break
        c = start_hz * (1.0 - i / max(segs - 1, 1)) ** 2.0
        blk = S.lowpass(x[max(0, i0 - 512):i1], max(c, 200.0), order=2, sr=sr)
        out[i0:i1] = blk[blk.size - (i1 - i0):]
    return S.normalize(out * np.exp(-t / max(seconds * 0.5, 0.05)), 0.9)


def vinyl_crackle(seconds, level=0.06, sr=S.SR, seed=121):
    """黑胶底噪（phonk / lo-fi 质感层）。"""
    n = int(seconds * sr)
    rng = np.random.default_rng(seed)
    x = rng.uniform(-1.0, 1.0, n) * 0.15
    pops = np.zeros(n)
    idx = rng.integers(0, n - 8, size=int(seconds * 26))
    for i in idx:
        pops[i] += rng.uniform(-1.0, 1.0)
    pops = S.highpass(pops, 2200.0, order=2, sr=sr)
    hiss = S.highpass(x, 3000.0, order=2, sr=sr) * 0.25
    return (pops * level * 6.0 + hiss * level)


def _contour(freq, n):
    """把标量音高或稀疏控制点数组展开成长度 n 的逐样本频率曲线。"""
    f = np.atleast_1d(np.asarray(freq, dtype=np.float64))
    if f.size == 1:
        return np.full(n, float(f[0]))
    if f.size == n:
        return f.astype(np.float64)
    x_old = np.linspace(0.0, 1.0, f.size)
    x_new = np.linspace(0.0, 1.0, n)
    return np.interp(x_new, x_old, f)


# ---------------------------------------------------------------------------
# 合成器音色
# ---------------------------------------------------------------------------
def _detuned_unison(freq, voices=5, detune=0.008, sr=S.SR, shape="saw", seed=0,
                    spread=0.6):
    """失谐齐奏，按 Mid/Side 分配：全部声部之和进 Mid，交替极性部分进 Side。

    左右各拿一半声部听起来很宽，但折单声道时两路互不相关会掉 3 dB；
    改成 Mid + k·Side 之后宽度基本保留，mono 只掉 1 dB 出头——笔记本
    外放和手机单声道下不会突然变小。
    """
    n = freq.size
    mid = np.zeros(n)
    side = np.zeros(n)
    rng = np.random.default_rng(seed)
    for i in range(voices):
        sign = 1.0 if i % 2 == 0 else -1.0
        amt = 0.0 if i == 0 else sign * detune * (1.0 + 0.35 * rng.random())
        f = freq * (2.0 ** (amt / 2.0))
        w = S.saw(f, sr) if shape == "saw" else (
            S.tri(f, sr=SR) if shape == "tri" else S.square(f, 0.5, sr=sr))
        mid += w
        side += sign * w
    d = float(voices)
    k = float(np.clip(spread, 0.0, 1.0))
    return S.stereo(mid / d + k * side / d, mid / d - k * side / d)


def supersaw(freq, seconds, level=0.55, cut=3200.0, voices=5, detune=0.010,
             attack=0.006, decay=0.30, sustain=0.72, release=0.14, res=0.22,
             drive=1.35, vib_hz=0.0, vib_cents=0.0, vib_delay=0.25, sr=S.SR):
    """超锯齿主音/和声：trance、eurobeat 的招牌厚度。"""
    n = int(seconds * sr)
    t = np.arange(n) / sr
    f = _contour(freq, n)
    if vib_hz > 0:
        shape = np.clip((t - vib_delay) / max(seconds - vib_delay, 1e-3), 0.0, 1.0)
        f = f * (1.0 + (2.0 ** (vib_cents / 1200.0) - 1.0) * shape * np.sin(S.TAU * vib_hz * t))
    st = _detuned_unison(f, voices, detune, sr, seed=int(f[0] * 7) % 997)
    # 每声道同参数滤波：立体声宽度来自失谐，不来自滤波差异
    a = int(attack * sr)
    cut_arr = np.full(n, cut * 0.42)
    ramp = int(min(0.08, seconds * 0.5) * sr)
    if ramp > 1:
        cut_arr[:ramp] = np.linspace(cut * 0.42, cut, ramp)
    for ch in range(2):
        st[ch] = S.ladder(st[ch], cut_arr, res, sr=sr)
    env = S.adsr(n, attack, decay, level * sustain, release, max(n - a - int(decay * sr) - int(release * sr), 0), sr)
    if env.max() <= 0:
        env = S.adsr(n, attack, seconds * 0.4, level * sustain, release, 0, sr)
    return S.saturate(st * env[None, :], drive)


def pluck(freq, seconds=0.42, level=0.5, cut=5200.0, cut_floor=900.0, decay=0.22,
          voices=2, detune=0.006, drive=1.2, bright=1.0, sr=S.SR):
    """拨弦/键击：短衰减 + 截止频率快速下扫，琶音的主力。"""
    n = max(int(seconds * sr), 32)
    f = float(np.atleast_1d(freq)[0])
    st = _detuned_unison(np.full(n, f), voices, detune, sr, seed=int(f * 13) % 991)
    sweep = cut_floor + (bright * cut - cut_floor) * np.exp(-np.arange(n) / sr / max(decay * 0.45, 0.005))
    for ch in range(2):
        st[ch] = S.ladder(st[ch], sweep, 0.30, sr=sr)
    body = S.saw(np.full(n, f), sr)
    env = S.thd_env(n, 0.002, decay, sr)
    return S.saturate((st * 0.8 + body[None, :] * 0.25) * (level * env)[None, :], drive)


def pad(freqs, seconds, level=0.30, cut=1700.0, voices=3, detune=0.012,
        attack=0.55, release=0.9, res=0.12, lfo_hz=0.28, lfo_depth=260.0,
        sr=S.SR, shape="saw"):
    """铺底：慢起音齐奏，截止频率被 LFO 缓慢推动，避免"死住"。"""
    n = int(seconds * sr)
    t = np.arange(n) / sr
    acc = np.zeros((2, n))
    for j, fr in enumerate(np.atleast_1d(freqs)):
        f = float(fr)
        st = _detuned_unison(np.full(n, f), voices, detune * (1.0 + 0.2 * j), sr,
                             shape=shape, seed=int(f * 31) % 977)
        sweep = cut + lfo_depth * np.sin(S.TAU * lfo_hz * t + j * 0.7)
        for ch in range(2):
            st[ch] = S.ladder(st[ch], sweep, res, sr=sr)
        acc += st
    env = S.adsr(n, attack, seconds * 0.25, level / max(len(np.atleast_1d(freqs)), 1), release,
                 max(n - int(attack * sr) - int(seconds * 0.25 * sr) - int(release * sr), 0), sr)
    if env.max() <= 0:
        env = np.full(n, level / max(len(np.atleast_1d(freqs)), 1))
    return acc * env[None, :]


def brass(freq, seconds, level=0.55, cut=2600.0, attack=0.035, decay=0.2,
          sustain=0.8, release=0.12, voices=4, detune=0.009, drive=1.6,
          vib_hz=5.2, vib_cents=9.0, sr=S.SR):
    """铜管式齐奏（管弦混合曲风的强调点）。"""
    return supersaw(freq, seconds, level, cut, voices, detune, attack, decay,
                    sustain, release, 0.30, drive, vib_hz, vib_cents, 0.05, sr)


def strings(freqs, seconds, level=0.34, cut=2600.0, attack=0.16, release=0.5,
            vib_hz=4.6, vib_cents=7.0, sr=S.SR):
    """弦乐群：锯齿 + 共振峰带通，比纯谐波堆更像弓弦。"""
    n = int(seconds * sr)
    t = np.arange(n) / sr
    acc = np.zeros((2, n))
    for j, fr in enumerate(np.atleast_1d(freqs)):
        f = float(fr)
        st = _detuned_unison(np.full(n, f), 4, 0.006, sr, seed=int(f * 17) % 991)
        if vib_hz > 0:
            shape = np.clip((t - 0.22) / max(seconds - 0.22, 1e-3), 0.0, 1.0)
            mod = 1.0 + (2.0 ** (vib_cents / 1200.0) - 1.0) * shape * np.sin(S.TAU * vib_hz * t + j)
            st = _detuned_unison(np.full(n, f) * mod, 4, 0.006, sr, seed=int(f * 17) % 991)
        # 弓身共振峰
        body = np.zeros((2, n))
        for ch in range(2):
            for fc, gain in ((420.0, 0.5), (1050.0, 0.75), (2600.0, 0.4)):
                body[ch] += S.bandpass(st[ch], fc * 0.7, fc * 1.35, order=2, sr=sr) * gain
        env = S.adsr(n, attack, seconds * 0.3, 1.0, release,
                     max(n - int(attack * sr) - int(seconds * 0.3 * sr) - int(release * sr), 0), sr)
        acc += body * (env / max(len(np.atleast_1d(freqs)), 1))[None, :]
    acc = S.lowpass(acc, cut * 1.6, order=2, sr=sr)
    return acc * level


def choir(freqs, seconds, level=0.28, attack=0.35, release=0.7, sr=S.SR):
    """合唱垫：锯齿过三共振峰，做出"啊"的元声色彩。"""
    n = int(seconds * sr)
    acc = np.zeros((2, n))
    for j, fr in enumerate(np.atleast_1d(freqs)):
        f = float(fr)
        st = _detuned_unison(np.full(n, f), 5, 0.014, sr, shape="saw", seed=int(f * 41) % 983)
        form = np.zeros((2, n))
        for ch in range(2):
            for fc, bw, gain in ((730.0, 240.0, 1.0), (1090.0, 300.0, 0.72), (2440.0, 420.0, 0.34)):
                form[ch] += S.bandpass(st[ch], fc - bw / 2, fc + bw / 2, order=2, sr=sr) * gain
        env = S.adsr(n, attack, seconds * 0.3, 1.0, release,
                     max(n - int(attack * sr) - int(seconds * 0.3 * sr) - int(release * sr), 0), sr)
        acc += form * (env / max(len(np.atleast_1d(freqs)), 1))[None, :]
    return acc * level


def bell(freq, seconds=1.6, level=0.4, ratio=2.76, index=2.4, decay=0.9, sr=S.SR):
    """FM 钟琴：trance 的高频点睛，non-integer ratio 才有金属感。"""
    n = int(seconds * sr)
    f = float(np.atleast_1d(freq)[0])
    t = np.arange(n) / sr
    mod_env = np.exp(-t / max(decay * 0.16, 0.005))
    sig = np.sin(S.TAU * f * t + index * np.sin(S.TAU * f * ratio * t) * mod_env)
    sig += 0.28 * np.sin(S.TAU * f * 4.01 * t) * np.exp(-t / 0.09)
    return sig * level * np.exp(-t / max(decay * 0.42, 0.01))


# ---------------------------------------------------------------------------
# 贝斯
# ---------------------------------------------------------------------------
def bass_saw(freq, seconds, level=0.85, cut=780.0, cut_kick=240.0, voices=2,
             detune=0.004, drive=1.9, res=0.18, glide=0.0, sr=S.SR):
    """大空间/电子贝斯：失谐锯齿 + tanh 饱和，截止随音符长度开合。"""
    n = int(seconds * sr)
    f = _contour(freq, n)
    if glide > 0:
        k = np.clip(np.arange(n) / max(glide * sr, 1), 0.0, 1.0) ** 2
        f = f[0] + (f - f[0]) * k
    st = _detuned_unison(f, voices, detune, sr, seed=int(f[0] * 11) % 991)
    sweep = cut_kick + (cut - cut_kick) * np.clip(np.arange(n) / sr / 0.055, 0.0, 1.0) ** 1.5
    # 音符越短开口越小：做出"闷—开"的泵感
    tail = np.exp(-np.arange(n) / sr / max(seconds * 0.75, 0.03))
    sweep = sweep * (0.55 + 0.45 * np.exp(-np.arange(n) / sr / max(seconds * 0.35, 0.02)))
    for ch in range(2):
        st[ch] = S.ladder(st[ch], np.maximum(sweep, 60.0), res, sr=sr)
    env = S.thd_env(n, 0.004, max(seconds * 0.85, 0.03), sr)
    out = S.saturate(st * env[None, :] * (1.0 + tail[None, :] * 0.25), drive)
    return out * level


def bass_808(freq, seconds=0.7, level=0.9, glide_from=0.0, drive=2.1, decay=0.65,
             tone=0.55, cut=1400.0, sr=S.SR):
    """808 低音：正弦 + 滑音 + 饱和补谐波（小喇叭也听得到根音）。"""
    n = int(seconds * sr)
    t = np.arange(n) / sr
    f0 = float(np.atleast_1d(freq)[0])
    target = f0
    if glide_from > 0:
        k = np.clip(t / max(0.055, seconds * 0.12), 0.0, 1.0) ** 1.6
        f = glide_from + (target - glide_from) * k
    else:
        f = np.full(n, target)
    sig = np.sin(S.phase_of(f, sr))
    sig += tone * 0.5 * np.sin(S.phase_of(f * 2.0, sr)) * np.exp(-t / 0.16)
    sig += 0.22 * np.sin(S.phase_of(f * 3.0, sr)) * np.exp(-t / 0.07)
    env = S.thd_env(n, 0.006, decay, sr)
    out = S.saturate(sig * env, drive)
    out = S.lowpass(out, cut, order=2, sr=sr)
    return S.dc_block(out) * level


def bass_reese(freq, seconds, level=0.8, voices=4, detune=0.016, cut=520.0,
               drive=2.2, res=0.3, flip=0.34, sr=S.SR):
    """Reese 贝斯（DnB/工业）：两组反向失谐锯齿对撞，天然缓慢起伏。"""
    n = int(seconds * sr)
    f = _contour(freq, n)
    a = _detuned_unison(f, voices, detune, sr, seed=5)
    b = _detuned_unison(f, voices, detune * (1.0 + flip), sr, seed=9)
    st = (a - b) * 0.5
    for ch in range(2):
        st[ch] = S.ladder(st[ch], cut, res, sr=sr)
    env = np.ones(n) * 0.9 + 0.1 * np.sin(S.TAU * 0.42 * np.arange(n) / sr)
    return S.saturate(st * (env * 1.0)[None, :], drive) * level


def bass_acid(freq, seconds, level=0.7, cut=520.0, peak=2400.0, res=0.72,
              accent=1.0, decay=0.16, sr=S.SR):
    """303 式酸贝斯：高谐振 + 瞬时开口包络。"""
    n = max(int(seconds * sr), 32)
    t = np.arange(n) / sr
    f = float(np.atleast_1d(freq)[0])
    x = S.saw(np.full(n, f), sr) * 0.7 + S.square(np.full(n, f), 0.22, sr=sr) * 0.35
    sweep = cut + (peak * accent - cut) * np.exp(-t / max(decay * 0.4, 0.004))
    x = S.ladder(x, sweep, res, sr=sr)
    return S.saturate(x * S.thd_env(n, 0.002, decay, sr), 1.5) * level


def bass_sub(freq, seconds, level=0.8, sr=S.SR):
    """纯次低音层：和大贝斯并联，负责 60 Hz 以下的胸腔感。"""
    n = int(seconds * sr)
    f = _contour(freq, n)
    sig = np.sin(S.phase_of(f, sr))
    env = S.thd_env(n, 0.010, max(seconds * 0.9, 0.05), sr)
    return S.dc_block(sig * env) * level
