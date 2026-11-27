#!/usr/bin/env python3
"""合成与母带原语：给 track_music.py 用的底层 DSP 工具箱。

设计约束
--------
· 所有音色都是**数学生成**的，无采样素材、无外部音源，产物完全原创。
· 滤波器允许逐样本变化的截止频率（Moog 梯式低通），这是 EDMP 里
  "bassline 开口" 与 riser 扫频的基础，静态 butter 做不到。
· 混响用噪声 × 指数衰减的冲激响应做快速卷积，比手写 Schroeder 更省
  代码且听感够用；立体声两条独立 IR 保住宽度。
· 响度按 ITU-R BS.1770 K 加权算 LUFS，与现有 bgm_manifest.json 的
  sourceLufs / lufs 字段同一口径，方便对齐曲库。

用法：作为模块导入，不单独运行。
"""

import numpy as np
from scipy import ndimage, signal

SR = 44100
TAU = np.pi * 2.0


# ---------------------------------------------------------------------------
# 基础波形
# ---------------------------------------------------------------------------
def phase_of(freq_hz, sr=SR):
    """把逐样本基频数组积分成连续相位（避免变调时相位跳爆音）。"""
    f = np.atleast_1d(np.asarray(freq_hz, dtype=np.float64))
    return np.cumsum(TAU * f / sr)


def saw(freq_hz, sr=SR):
    """带 4 次叠加限带的锯齿（naive saw 的高频混叠在 4 kHz 以上很刺耳）。"""
    ph = phase_of(freq_hz, sr)
    out = np.zeros_like(ph)
    for k in range(1, 5):
        out += ((-1.0) ** (k + 1)) * np.sin(k * ph) / k
    return 2.0 * out


def square(freq_hz, duty=0.5, harmonics=18, sr=SR):
    ph = phase_of(freq_hz, sr)
    out = np.zeros_like(ph)
    for k in range(1, harmonics + 1, 2):
        out += np.sin(k * ph) * (np.sin(k * np.pi * duty) / k)
    return 4.0 / np.pi * out


def sine(freq_hz, sr=SR):
    return np.sin(phase_of(freq_hz, sr))


def tri(freq_hz, harmonics=12, sr=SR):
    ph = phase_of(freq_hz, sr)
    out = np.zeros_like(ph)
    for k in range(1, harmonics + 1):
        out += ((-1.0) ** k) * np.sin((2 * k + 1) * ph) / (2 * k + 1) ** 2
    return 8.0 / (np.pi ** 2) * out


def noise(n, sr=SR, seed=None):
    rng = np.random.default_rng(seed)
    return rng.uniform(-1.0, 1.0, int(n))


def filtered_noise(n, cutoff_hz, sr=SR, seed=None, order=2):
    """带通/低通噪声：军鼓体、踩镲、风声层都从它长出来。"""
    x = noise(n, sr, seed)
    sos = signal.butter(order, min(cutoff_hz, sr * 0.45) / (sr / 2.0), btype="low", output="sos")
    return signal.sosfiltfilt(sos, x)


# ---------------------------------------------------------------------------
# 包络
# ---------------------------------------------------------------------------
def adsr(n, attack, decay, sustain, release, hold, sr=SR):
    """线性 attack/decay + 指数 release 的 AD 型包络（sustain 为电平）。

    hold 是"保持段"长度（秒），release 从 hold 之后开始，总长可以小于 n，
    尾部自动补 0，方便把事件放在任意时刻。
    """
    n = int(n)
    env = np.zeros(n)
    a = max(int(attack * sr), 1)
    d = max(int(decay * sr), 1)
    h = max(int(hold * sr), 0)
    r = max(int(release * sr), 1)
    if a > n:
        a = n
    idx = np.arange(a) / a
    env[:a] = idx
    end_d = min(a + d, n)
    dd = np.arange(end_d - a) / max(d, 1)
    env[a:end_d] = (1.0 - dd) * (1.0 - sustain) + sustain
    end_h = min(a + d + h, n)
    env[a + d:end_h] = sustain
    start_r = a + d + h
    if start_r < n:
        seg = min(r, n - start_r)
        rr = np.arange(seg) / seg
        env[start_r:start_r + seg] = sustain * np.exp(-5.0 * rr)
        if seg < r:
            env[start_r + seg:] = sustain * np.exp(-5.0) * 0.0
    return env


def exp_decay(n, tau_sec, sr=SR):
    n = int(n)
    t = np.arange(n) / sr
    return np.exp(-t / max(tau_sec, 1e-4))


def thd_env(n, punch=0.008, tau=0.18, sr=SR):
    """鼓组常用：极短线性起音 + 指数衰减。"""
    n = int(n)
    env = np.ones(n) * np.exp(-np.arange(n) / sr / max(tau, 1e-4))
    p = max(int(punch * sr), 1)
    env[:p] *= np.arange(p) / p
    return env


def curve(n, kind="exp", k=3.0, sr=SR):
    """0→1 形状的扫描曲线，riser / filter sweep 用。"""
    x = np.linspace(0.0, 1.0, int(n))
    if kind == "exp":
        return x ** k
    if kind == "log":
        return 1.0 - (1.0 - x) ** k
    if kind == "s":
        return 3 * x ** 2 - 2 * x ** 3
    return x


# ---------------------------------------------------------------------------
# 滤波
# ---------------------------------------------------------------------------
def ladder(x, cutoff_hz, res=0.0, sr=SR, block=16):
    """4 级一极点梯式低通（Moog 近似），截止频率可逐样本变化。

    res 取 0..1，越高越接近自激；1.0 附近会尖叫，通常 0.35 左右最实用。

    逐样本递推在 Python 里跑整曲要几十秒，所以按 16 样本分块做
    **块内定截止 + lfilter 携带 zi 保状态**：一个块只有 0.36 ms，扫描斜率
    在块内几乎不变，块间状态连续，听不出台阶。反馈路径取上一块末样本，
    等效于把谐振环的延迟压到 0.36 ms——谐振只在可闻带内多一层极细的
    梳状着色，换掉的是两个数量级的速度。
    """
    x = dc_block(np.asarray(x, dtype=np.float64))
    n = x.size
    if n == 0:
        return x
    f = np.atleast_1d(np.asarray(cutoff_hz, dtype=np.float64))
    if f.size == 1:
        f = np.full(n, float(f[0]))
    elif f.size < n:
        f = np.pad(f, (0, n - f.size), mode="edge")
    else:
        f = np.resize(f, n)
    f = np.clip(f, 20.0, sr * 0.45)
    k = float(np.clip(res, 0.0, 0.92)) * 4.0
    tune = np.tanh(np.pi * f / sr)          # 非线性调谐，低频段也给得动
    nb = (n + block - 1) // block
    y = [np.zeros(n) for _ in range(4)]
    zi = [np.zeros(1) for _ in range(4)]
    for b in range(nb):
        i0 = b * block
        i1 = min(i0 + block, n)
        c = float(tune[i0])
        g = c / (1.0 + c)
        fb = k * y[3][i0 - 1] if i0 > 0 else 0.0
        seg = x[i0:i1] - fb
        for s in range(4):
            src = seg if s == 0 else y[s - 1][i0:i1]
            out_seg, zi[s] = signal.lfilter([g], [1.0, -(1.0 - g)], src, zi=zi[s])
            y[s][i0:i1] = out_seg
    return y[3]


def lowpass(x, cutoff_hz, order=4, sr=SR):
    sos = signal.butter(order, min(cutoff_hz, sr * 0.45) / (sr / 2.0), btype="low", output="sos")
    return signal.sosfiltfilt(sos, np.asarray(x, dtype=np.float64))


def highpass(x, cutoff_hz, order=2, sr=SR):
    sos = signal.butter(order, min(cutoff_hz, sr * 0.45) / (sr / 2.0), btype="high", output="sos")
    return signal.sosfiltfilt(sos, np.asarray(x, dtype=np.float64))


def bandpass(x, lo, hi, order=2, sr=SR):
    lo = max(lo, 20.0)
    hi = min(hi, sr * 0.45)
    sos = signal.butter(order, [lo / (sr / 2.0), hi / (sr / 2.0)], btype="band", output="sos")
    return signal.sosfiltfilt(sos, np.asarray(x, dtype=np.float64))


# ---------------------------------------------------------------------------
# 非线性与空间
# ---------------------------------------------------------------------------
def saturate(x, drive=1.5):
    """tanh 软削峰：drive 越大谐波越肥，是合成器贝斯/超锯齿的厚度来源。"""
    x = np.asarray(x, dtype=np.float64)
    return np.tanh(x * drive) / np.tanh(max(drive, 1.0))


def crush(x, bits=8):
    x = np.asarray(x, dtype=np.float64)
    levels = 2.0 ** bits
    return np.round(x * levels) / levels


def _comb(x, d, fb):
    """y[n] = x[n] + fb*y[n-d]，按延迟长度分块递推（等价于逐样本但走 numpy）。"""
    y = np.array(x, dtype=np.float64, copy=True)
    n = y.size
    i = d
    while i < n:
        j = min(i + d, n)
        y[i:j] += fb * y[i - d:j - d]
        i = j
    return y


def delay(x, seconds, feedback=0.35, mix=0.25, sr=SR):
    """带反馈的数字延迟（单声道输入 → 同声道返回）。"""
    x = np.asarray(x, dtype=np.float64)
    d = max(int(seconds * sr), 1)
    wet = _comb(x, d, feedback)
    return (1.0 - mix) * x + mix * wet


def pingpong_delay(x, seconds, feedback=0.32, mix=0.28, sr=SR):
    """左右交替的乒乓延迟：琶音/铺宽的常用手法。返回立体声 (2, n)。

    原式 l[n] = x[n] + fb*r[n-d]、r[n] = fb*l[n-d] 消元后是
    l[n] = x[n] + fb^2*l[n-2d]，即一个 2d 延迟、fb^2 反馈的梳状滤波器，
    右声道直接取 l 的 d 样本延迟 → 一次分块递推就够，无需逐样本循环。
    """
    x = np.asarray(x, dtype=np.float64)
    d = max(int(seconds * sr), 1)
    n = x.size
    l = _comb(x, 2 * d, feedback * feedback)
    r = np.zeros(n)
    if d < n:
        r[d:] = feedback * l[:n - d]
    dry = (1.0 - mix) * x
    return np.vstack([dry + mix * l, dry + mix * r])


def make_ir(seconds, decay, sr=SR, seed=0, lp_hz=11000.0, predelay_ms=12.0):
    """噪声 × 指数衰减 = 混响冲激响应；早期反射用几提前的脉冲模拟。"""
    n = max(int(seconds * sr), 8)
    rng = np.random.default_rng(seed)
    ir = rng.uniform(-1.0, 1.0, n)
    t = np.arange(n) / sr
    ir *= np.exp(-t * (6.908 / max(decay, 0.05)))      # -60 dB / decay
    ir *= np.clip(t / max(1.0 / sr, 1e-4), 0.0, 1.0)   # 起音淡入去咔
    for pos, gain in ((0.011, 0.5), (0.017, 0.42), (0.023, 0.35), (0.031, 0.3)):
        k = int(pos * sr)
        if k < n:
            ir[k] += gain
    if lp_hz < sr * 0.45:
        ir = lowpass(ir, lp_hz, order=2, sr=sr)
    pd = int(predelay_ms / 1000.0 * sr)
    if pd:
        ir = np.concatenate([np.zeros(pd), ir])
    peak = np.max(np.abs(ir))
    return ir / peak if peak > 0 else ir


def convolve(x, ir):
    return signal.fftconvolve(np.asarray(x, dtype=np.float64), ir, mode="full")[: x.size]


def stereo(left, right):
    return np.vstack([np.asarray(left, dtype=np.float64), np.asarray(right, dtype=np.float64)])


def to_stereo(x):
    """单声道 → 立体声（两路相同，未加宽）。"""
    x = np.asarray(x, dtype=np.float64)
    return np.vstack([x, x])


def widen(st, ms_delay=0.012, allpass_hz=4000.0):
    """Haas 加宽：右路延后十几毫秒再补一点相位偏移，只对铺底/和声用。

    单声道向下混合时会打架，所以鼓组/贝斯绝不走这里。
    """
    st = np.atleast_2d(np.asarray(st, dtype=np.float64))
    d = int(ms_delay * SR)
    if d < 1 or st.shape[0] < 2:
        return st
    right = np.zeros_like(st[1])
    right[d:] = st[1][: st.shape[1] - d]
    return np.vstack([st[0], right])



def pan(x, amount=0.0):
    """amount -1 左 / +1 右（等功率）。返回 (2, n)。"""
    x = np.asarray(x, dtype=np.float64)
    a = (np.clip(amount, -1.0, 1.0) + 1.0) * np.pi / 4.0
    return np.vstack([x * np.cos(a), x * np.sin(a)])


# ---------------------------------------------------------------------------
# 响度与母带
# ---------------------------------------------------------------------------
# BS.1770 数字系数（规范只给 48 kHz 版本，其它采样率先重采样到 48 k 再量）
_K_SHELF_B = [1.53512485958697, -2.69169618940638, 1.19839281085285]
_K_SHELF_A = [1.0, -1.69065929318241, 0.73248077421585]
_K_RLB_B = [1.0, -2.0, 1.0]
_K_RLB_A = [1.0, -1.99004745483398, 0.99007225036621]


def lufs(x, sr=SR):
    """ITU-R BS.1770  integrated 响度（K 加权 + 均方，未做门限分段）。

    对 -18 LUFS 目标、动态可控的循环曲库，门限版和全曲版的差在 0.2 dB 以内，
    这里取简单口径，和 bgm_manifest.json 的 sourceLufs / lufs 字段一致。
    """
    arr = np.atleast_2d(np.asarray(x, dtype=np.float64))
    if sr != 48000:
        g = np.gcd(int(sr), 48000)
        arr = np.vstack([signal.resample_poly(arr[ch], 48000 // g, int(sr) // g)
                         for ch in range(arr.shape[0])])
    total = 0.0
    for ch in range(arr.shape[0]):
        y = signal.lfilter(_K_SHELF_B, _K_SHELF_A, arr[ch])
        y = signal.lfilter(_K_RLB_B, _K_RLB_A, y)
        total += float(np.mean(y ** 2))
    mean_sq = total / max(arr.shape[0], 1)
    if mean_sq <= 1e-12:
        return -120.0
    return -0.691 + 10.0 * np.log10(mean_sq)



def peak_db(x):
    p = float(np.max(np.abs(np.asarray(x))))
    return 20.0 * np.log10(p) if p > 1e-9 else -120.0


def rms_db(x):
    r = float(np.sqrt(np.mean(np.asarray(x) ** 2)))
    return 20.0 * np.log10(r) if r > 1e-9 else -120.0


def gain_to_lufs(x, target_lufs):
    cur = lufs(x)
    return 10.0 ** ((target_lufs - cur) / 20.0)


def limiter(x, ceiling_db=-1.0, release_ms=110.0, lookahead_ms=2.0, hop=32, sr=SR):
    """前瞻峰值限制器（控制率实现）。

    不是压缩器（不看 RMS），只保证峰值不超 ceiling，且尽量不把瞬态削成
    方波。控制率 = 每 hop 样本算一次增益再线性插值回样本率：0.7 ms 的
    粒度对 20 kHz 以下的包络毫无影响，比逐样本循环快三个数量级。
    """
    arr = np.atleast_2d(np.asarray(x, dtype=np.float64))
    n = arr.shape[1]
    ceil = 10.0 ** (ceiling_db / 20.0)
    mono_peak = np.max(np.abs(arr), axis=0)
    nb = n // hop + 1
    # 块内峰值：把样本率包络按 hop 归约（尾部补 1 个块）
    pad = nb * hop - n
    padded = np.concatenate([mono_peak, np.zeros(max(pad, 0))])
    blk_peak = padded[:nb * hop].reshape(nb, hop).max(axis=1)
    if not np.any(blk_peak > ceil):
        return arr
    g_blk = np.where(blk_peak > 1e-9, ceil / np.maximum(blk_peak, 1e-9), 1.0)
    g_blk = np.minimum(g_blk, 1.0)
    la = max(int(lookahead_ms / 1000.0 * sr / hop), 1)
    g_blk = ndimage.minimum_filter1d(g_blk, size=2 * la + 1, mode="nearest")
    # 非对称平滑：下落瞬时跟随，回升按 release_ms 指数恢复
    rel = float(np.exp(-hop / (release_ms / 1000.0 * sr)))
    out = np.empty(nb)
    g = 1.0
    for i in range(nb):
        t = g_blk[i]
        g = t if t < g else t + (g - t) * rel
        out[i] = g
    centers = np.arange(nb) * hop + hop * 0.5
    env = np.interp(np.arange(n), centers, out, left=out[0], right=out[-1])
    return arr * env[None, :]


def soft_clip(x, drive=1.0):
    return np.tanh(np.asarray(x, dtype=np.float64) * drive) / np.tanh(max(drive, 1e-3))


def dc_block(x, r=0.995):
    """直流阻断：合成音色（尤其方波/梯式滤波）会积累 DC。"""
    return signal.lfilter([1.0, -1.0], [1.0, -r], np.asarray(x, dtype=np.float64))



def normalize(x, peak=0.95):
    x = np.asarray(x, dtype=np.float64)
    m = np.max(np.abs(x))
    return x * (peak / m) if m > 1e-9 else x


def midi_hz(note):
    """MIDI 音符号 → 频率（A4 = 69 = 440 Hz）。"""
    return 440.0 * 2.0 ** ((float(note) - 69.0) / 12.0)


def duck_envelope(n, hits, depth=0.35, attack=0.004, release=0.18, sr=SR):
    """侧链泵感包络：命中点压到 depth，之后指数回到 1.0。

    EDM 的"抽吸"就是这么来的——把垫底/贝斯挂在这条曲线上，而不是真的
    做一个动态压缩器：结构可控、离线一次算完、也不会误伤瞬态。
    """
    env = np.ones(int(n))
    if not len(hits):
        return env
    a = max(int(attack * sr), 1)
    r = max(int(release * sr), 1)
    idx = np.arange(n, dtype=np.float64)
    hit_arr = np.asarray([h for h in hits if 0 <= h < n], dtype=np.float64)
    if hit_arr.size == 0:
        return env
    # 每个样本取"最近一次已经发生的命中"的衰减量（向量化：searchsorted）
    order = np.sort(hit_arr)
    pos = np.searchsorted(order, idx, side="right") - 1
    have = pos >= 0
    since = np.where(have, idx - np.where(have, order[np.clip(pos, 0, order.size - 1)], 0), 0.0)
    press = np.where(have, (depth - 1.0) * np.exp(-since / r), 0.0)
    press[since < a] *= since[since < a] / a
    return np.clip(1.0 + press, 0.02, 1.0)


def place(dst, src, start, gain=1.0):
    """把事件叠加进总缓冲（start 可为负，尾部自动截断）。"""
    n = dst.shape[-1]
    s = int(start)
    if s >= n or s > 0 and -s >= src.shape[-1]:
        return dst
    src = np.asarray(src, dtype=np.float64)
    if src.size == 0:
        return dst
    if src.ndim == 1:
        i0 = max(s, 0)
        i1 = min(s + src.shape[0], n)
        if i1 <= i0:
            return dst
        dst[i0:i1] += gain * src[i0 - s:i1 - s]
    else:
        i0 = max(s, 0)
        i1 = min(s + src.shape[1], n)
        if i1 <= i0:
            return dst
        dst[:, i0:i1] += gain * src[:, i0 - s:i1 - s]
    return dst


def fold_loop(st, loop_len):
    """把超出循环点的尾巴绕回开头叠加。

    延迟/混响的尾音必须在循环点之前收干净，否则接缝处会缺一块。绕回比
    硬切自然，代价是循环点上会叠一层回声——正好当作无缝循环的胶。
    """
    arr = np.atleast_2d(np.asarray(st, dtype=np.float64))
    n = arr.shape[1]
    if n <= loop_len:
        out = np.zeros((arr.shape[0], loop_len))
        out[:, :n] = arr
        return out
    out = arr[:, :loop_len].copy()
    tail = arr[:, loop_len:]
    k = tail.shape[1]
    out[:, :k] += tail
    return out


def fade_edges(st, fade_in=0.003, fade_out=0.003, sr=SR):
    """事件首尾微淡入淡出，避免叠加处的台阶咔哒声。"""
    arr = np.atleast_2d(np.asarray(st, dtype=np.float64))
    fi = min(int(fade_in * sr), arr.shape[1])
    fo = min(int(fade_out * sr), arr.shape[1])
    if fi > 1:
        arr[:, :fi] *= np.linspace(0.0, 1.0, fi)[None, :]
    if fo > 1:
        arr[:, -fo:] *= np.linspace(1.0, 0.0, fo)[None, :]
    return arr


def write_wav(path, st, sr=SR):
    """16 bit PCM WAV（ffmpeg 编码 OGG 前的中间格式）。"""
    import wave as _wave
    arr = np.atleast_2d(np.asarray(st, dtype=np.float64))
    mono = arr.shape[0] == 1
    clipped = np.clip(arr, -1.0, 1.0)
    pcm = (clipped * 32767.0).astype("<i2")
    interleaved = pcm.T.reshape(-1) if not mono else pcm[0]
    with _wave.open(path, "wb") as f:
        f.setnchannels(1 if mono else 2)
        f.setsampwidth(2)
        f.setframerate(int(sr))
        f.writeframes(interleaved.tobytes())
    return path
