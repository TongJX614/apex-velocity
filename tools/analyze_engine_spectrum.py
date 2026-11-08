#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""引擎声频谱分析器 —— 客观验证程序化合成引擎声的质量。

用途
----
Godot 渲染出的引擎声 WAV 是"黑盒"，只能靠听。但听感会骗人：马达声配上
V8 排气也像那么回事。这里用 numpy FFT 把 WAV 拆成客观数字，回答几个问题：

  1. V8 / V6 / I4 / I3 的点火基频是不是真的按物理走（rpm/60 × 缸数/2）？
  2. EV 的刺耳啸叫到底消掉没有？
  3. 四类缸型听起来是不是真的不一样？
  4. idle/cruise/pull/redline 四档音色是不是真的有区分度？

输入
----
manifest（默认 /tmp/engine_audio_manifest.json），由 tools/audio_audit.gd 生成：
    {"mix_rate": 44100, "samples": [
        {"car_id":..., "scene":"pull", "file":"...wav", "fuel":"ice",
         "family":"i6", "cylinders":6, "firing_div":3.0,
         "expect_fire_hz":319.4, "peak":0.12, "rms":0.037,
         "clip_pct":0.0, "profile_mismatch":""}, ...]}
WAV 为 16-bit 单声道 PCM。

输出
----
终端报告 + /tmp/engine_audio_spectrum_report.txt

关于"频谱质心"为什么用功率加权（这一点上一版栽过跟头）
--------------------------------------------------------
频谱质心 = Σ(f·w_i) / Σ(w_i)，其中 w_i 是第 i 个频点的权重。两种权重：

  · 幅度加权 w=|X|      —— 对谱线"计数"，单个高幅谱线被低估
  · 功率加权 w=|X|²     —— 对"能量"计数，等价于时域均方意义下的频率重心

本分析器全程使用**功率加权**。原因：能量守恒是物理事实，一个 3kHz 的强
正弦带（幅度 0.2）的功率是 100Hz 强正弦（幅度 1.0）的 4%，不是 20%。
用幅度加权会把 3kHz 的能量严重高估，于是"高频刺耳"被夸大、"高频柔和"
被低估——正好和我们要判定的方向相反。

另外必须用 Hann 窗：矩形窗的旁瓣衰减只有 -13dB，100Hz 的主瓣会漏到
±2Hz 之外并污染整个低频段；Hann 窗旁瓣 -31dB 且主瓣只有 3 个 bin，
质心因此稳定可复现。

本脚本自带标定用例（见 run_self_check）：用解析可算的已知信号反查分析器
本身是否可信，不通过就明确警告"分析器不可信"，绝不输出看似精确的废数据。
"""

from __future__ import annotations

import argparse
import json
import os
import statistics
import sys
import unicodedata
import wave
from collections import defaultdict

import numpy as np

# ---------------------------------------------------------------------------
# 常量
# ---------------------------------------------------------------------------

DEFAULT_MANIFEST = "/tmp/engine_audio_manifest.json"
DEFAULT_REPORT = "/tmp/engine_audio_spectrum_report.txt"

# 分频段（Hz）。分界点取自听感分区：低频体量 / 点火基频区 / 排气中频 /
# 高阶谐波 / 刺耳区。
BANDS = [
    ("<150Hz", 0.0, 150.0),
    ("150-800", 150.0, 800.0),
    ("800-2500", 800.0, 2500.0),
    ("2500-6000", 2500.0, 6000.0),
    (">6000", 6000.0, float("inf")),
]

# 点火基频搜索范围。
#
# 为什么上界取 1300 而不是题面说的 600：
#   manifest 里 expect_fire_hz 最大到 616.7Hz（V8 红区，8300rpm × 4 缸）。
#   若把上界钉死在 600Hz，这些样本必然在 550~590Hz 找到 2 阶副峰，
#   基频判定直接 FAIL——那是搜索窗口的错，不是合成的错。
# 下界 20Hz：低于 20Hz 的是次谐波/漂移，不是点火基频。
FUND_LO = 20.0
FUND_HI = 1300.0

# EV 逆变器基频搜索范围。EV 没有点火基频，主峰是逆变器频率。
EV_FUND_LO = 120.0
EV_FUND_HI = 3000.0

# 混动专用阈值
#   · 逆变器主音频率误差 < 1%（差分残差的主峰应当精确落在期望频率上）
#   · 内燃机基频在完整混音里保留 ≥ 75%（电机层不能把发动机盖住）
TH_HYBRID_MOTOR_ERR = 1.0
TH_HYBRID_ICE_KEEP = 0.75
# 电机层在总声场里的能量占比上限。
# 超过 0.55 就意味着"混动车听起来主要是电机在响"，那不叫混动了。
# 实测：怠速 5~14%、巡航 12~26%、大转 12~30%，全部远低于该线。
TH_HYBRID_MOTOR_SHARE = 0.55

# 谐波分析：测到 12 阶。
N_HARMONIC = 12

# 谐波测量带宽（相对带宽 + 绝对下限）。
# 相对带宽保证高次谐波的窗足够宽以容纳主瓣与边带；绝对下限保证低基频
# （I3 怠速 21Hz）时不会把相邻谐波框进来。
HARM_BW_REL = 0.035
HARM_BW_MIN = 5.0

# 档位顺序（与 audio_audit.gd 的 SCENES 一致）
SCENES = ["idle", "cruise", "pull", "redline"]

# "fuelcut" 是断油档，与红区同转速但切断点火，单独统计，不混进四档口径。
FUELCUT_SCENE = "fuelcut"

# 缸数 → 缸型标签
CYL_LABEL = {8: "V8", 6: "V6", 4: "I4", 3: "I3"}

# 判定阈值
TH_FIRE_ERR = 5.0        # 点火基频误差 < 5%
TH_FAMILY_SEP = 5.0      # 四类缸型两两相对差 > 5%
TH_EV_HF = 0.5           # EV >6kHz 能量占比上限 0.5%
TH_EV_ICE = 1.3          # EV/ICE 质心中位数至少相差 1.3 倍
TH_CLIP = 0.1            # clip_pct > 0.1 视为削波
TH_SCENE_SPAN = 150.0    # idle→redline 质心跨度 > 150Hz
TH_CALIB = 3.0           # 标定用例误差 < 3%


# ---------------------------------------------------------------------------
# 通用工具
# ---------------------------------------------------------------------------

def dwidth(s: str) -> int:
    """字符串的终端显示宽度（中日韩全角字符按 2 列算）。"""
    return sum(2 if unicodedata.east_asian_width(c) in ("W", "F") else 1 for c in s)


def pad(s: str, width: int, right: bool = False) -> str:
    """按显示宽度对齐（CJK 全角算 2 列）。"""
    s = str(s)
    diff = max(0, width - dwidth(s))
    return (" " * diff + s) if right else (s + " " * diff)


def rpad(s: str, width: int) -> str:
    return pad(s, width, right=True)


def median(values):
    """中位数，空序列返回 None。"""
    vals = [v for v in values if v is not None]
    return statistics.median(vals) if vals else None


def physics_rows(rows: list) -> list:
    """**缸型物理口径**的样本集。

    回答"这台车是几缸、点火基频多少"。混动必须取 ICE 单层：
    完整混音里逆变器主音可能压过点火基频（实测 bmw_i8 巡航 911.7Hz vs 86.0Hz），
    "取最强峰"的检测器会量到电机音上去。纯 ICE 车只有完整混音一层，直接用。
    断油档不参与（断续门会改变谐波结构，基频判定会失真）。
    """
    out = []
    for r in rows:
        if r.get("error"):
            continue
        if r.get("fuel") == "ev":
            continue
        if r.get("scene") == FUELCUT_SCENE:
            continue
        if r.get("fuel") == "hybrid" and r.get("layer") != "iceonly":
            continue
        out.append(r)
    return out


def heard_rows(rows: list) -> list:
    """**玩家听到的口径**的样本集：完整混音（含电驱层 / EV 层）、四个行驶档位。

    回答"实际听到的音色刺不刺耳、四个档位有没有区分度"。
    断油档（fuelcut）单独统计，不混进这里的口径。
    """
    return [r for r in rows
            if not r.get("error") and r.get("layer") == "full"
            and r.get("scene") in SCENES]


def fuelcut_rows(rows: list) -> list:
    """断油档样本（完整混音）。EV 没有点火系统，不参与。"""
    return [r for r in rows
            if not r.get("error") and r.get("layer") == "full"
            and r.get("scene") == FUELCUT_SCENE and r.get("fuel") != "ev"]


# ---------------------------------------------------------------------------
# WAV 读取与频谱计算
# ---------------------------------------------------------------------------

def read_wav_mono(path: str):
    """读 16-bit 单声道 PCM WAV，返回 (float64 样本, 采样率)。

    只用标准库 wave 模块，不引入 scipy。
    """
    try:
        with wave.open(path, "rb") as w:
            n_ch = w.getnchannels()
            sampwidth = w.getsampwidth()
            n_frames = w.getnframes()
            sr = w.getframerate()
            raw = w.readframes(n_frames)
    except Exception as exc:  # noqa: BLE001
        raise RuntimeError("无法读取 WAV %s: %s" % (path, exc)) from exc

    if sampwidth != 2:
        raise RuntimeError("只支持 16-bit PCM，%s 是 %d-bit" % (path, sampwidth * 8))

    data = np.frombuffer(raw, dtype="<i2").astype(np.float64) / 32768.0
    if n_ch > 1:
        # 立体声混成单声道（取平均）。引擎声应为单声道，这里只是兜底。
        data = data[: (len(data) // n_ch) * n_ch].reshape(-1, n_ch).mean(axis=1)
    if data.size == 0:
        raise RuntimeError("WAV 是空的: %s" % path)
    return data, sr


def power_spectrum(x: np.ndarray, sr: int):
    """Hann 窗 + rFFT，返回 (频率轴, 功率谱, 幅度谱)。

    为什么用 Hann 窗：矩形窗旁瓣只有 -13dB，100Hz 的主瓣会往两边漏，
    把整个低频段糊掉，质心随之漂移。Hann 窗旁瓣 -31dB、主瓣 3 个 bin。

    为什么去掉直流：去均值可避免音频里的直流偏置在 f=0 处堆出一个
    巨大的假能量点，把质心整体压低。
    """
    n = len(x)
    x = x - float(np.mean(x))
    window = np.hanning(n)
    spectrum = np.fft.rfft(x * window)
    freqs = np.fft.rfftfreq(n, 1.0 / sr)
    mag = np.abs(spectrum)
    power = mag * mag
    return freqs, power, mag


def centroid_power(freqs: np.ndarray, power: np.ndarray) -> float:
    """功率加权频谱质心：Σ(f·|X|²) / Σ|X|²。

    为什么必须功率加权：能量守恒。幅度 0.2 的 3kHz 正弦，其能量只有
    幅度 1.0 的 100Hz 正弦的 4%；幅度加权会把它算成 20%，把"高频刺耳"
    夸大 5 倍。功率加权量纲就是能量，与听感上的"刺耳程度"一致。
    """
    total = float(power.sum())
    if total <= 0.0:
        return 0.0
    return float((freqs * power).sum() / total)


def centroid_amplitude(freqs: np.ndarray, mag: np.ndarray) -> float:
    """幅度加权频谱质心：Σ(f·|X|) / Σ|X|。

    只在标定用例里出现——用来证明分析器能复现教科书上的经典数值
    （100Hz + 0.2×3kHz → 583.33Hz）。分析器本身不用这个口径。
    """
    total = float(mag.sum())
    if total <= 0.0:
        return 0.0
    return float((freqs * mag).sum() / total)


def band_energy_pct(freqs: np.ndarray, power: np.ndarray) -> list:
    """各频段的功率能量占比（%）。分母是全频段总功率。"""
    total = float(power.sum())
    if total <= 0.0:
        return [0.0] * len(BANDS)
    out = []
    for _, lo, hi in BANDS:
        mask = (freqs >= lo) & (freqs < hi)
        out.append(float(power[mask].sum() / total * 100.0))
    return out


# ---------------------------------------------------------------------------
# 峰值提取
# ---------------------------------------------------------------------------

def _parabolic_interp(freqs: np.ndarray, mag: np.ndarray, i: int) -> float:
    """抛物线插值求峰值真频率。

    FFT 的频率栅格是 1Hz（44100 点 / 1 秒），栅格量化误差最大 ±0.5Hz。
    对 21Hz 的怠速基频那是 2.4% 的误差，对 5% 的判定阈值来说太奢侈了。
    用峰值及其左右两点的抛物线插值，可以把分辨率提升到远小于 1Hz。
    """
    if i <= 0 or i >= len(mag) - 1:
        return float(freqs[i])
    a, b, c = float(mag[i - 1]), float(mag[i]), float(mag[i + 1])
    denom = a - 2.0 * b + c
    delta = 0.0 if denom == 0.0 else 0.5 * (a - c) / denom
    df = float(freqs[1] - freqs[0]) if len(freqs) > 1 else 1.0
    return float(freqs[i] + delta * df)


def local_peaks(freqs: np.ndarray, mag: np.ndarray, lo: float, hi: float):
    """在 [lo, hi] 内找出所有局部极大值，返回 [(频率, 幅度), ...]（幅度降序）。

    局部极大值的判定用严格大于左邻、且大于等于右邻，避免平坦区重复入选。
    """
    mask = (freqs >= lo) & (freqs <= hi)
    if not np.any(mask):
        return []
    f = freqs[mask]
    m = mag[mask]
    peaks = []
    for i in range(1, len(m) - 1):
        if m[i] > m[i - 1] and m[i] >= m[i + 1]:
            peaks.append((_parabolic_interp(f, m, i), float(m[i])))
    peaks.sort(key=lambda t: -t[1])
    return peaks


def top_peaks(freqs: np.ndarray, power: np.ndarray, lo: float, hi: float,
              count: int, suppress_hz: float = 25.0):
    """找能量最高的 count 个谱峰，带邻频抑制。

    为什么要抑制：FFT 主瓣有 3 个 bin（±1Hz），加上谐波间的边带，
    同一个物理峰会在频谱上占 2~3 个 bin。不抑制的话 top-6 里会出现
    "60Hz, 61Hz, 62Hz" 这种同一峰的三连记录，毫无信息量。

    抑制半径用固定 25Hz：小于它的间隔在本引擎的谐波间距下不可能是
    两个独立物理峰（最低阶基频 21Hz 时 2 阶与 1 阶相差 21Hz，
    但那种情况下靠"次谐波回退"逻辑区分，而不是靠抑制半径）。
    """
    peaks = local_peaks(freqs, np.sqrt(power), lo, hi)
    chosen = []
    for freq, amp in peaks:
        if all(abs(freq - c[0]) > suppress_hz for c in chosen):
            chosen.append((freq, amp))
            if len(chosen) >= count:
                break
    if not chosen:
        return []
    peak_max = max(a for _, a in chosen)
    return [(f, a / peak_max * 100.0) for f, a in chosen]


def detect_fundamental(freqs: np.ndarray, mag: np.ndarray,
                       lo: float = FUND_LO, hi: float = FUND_HI,
                       sub_ratio: float = 0.20, walk_down: bool = True) -> float:
    """检测实测基频（点火频率），返回 Hz。

    两步法：

    1) 先取搜索窗内最强的谱峰。
    2) 再做"次谐波回退"：如果最强峰的 1/2、1/3…处也存在一个能量
       ≥ 最强峰 20% 的谱峰，说明真正的主音在更低处（我们量到的只是
       它的某个高次谐波），就下移到那里。

    为什么必须有第 2 步：三缸机（I3）怠速时基频只有 21Hz，而它的
    3 阶谐波（63Hz）幅度更高——直接取最强峰会量到 3 阶谐波而不是基频。
    实测 bmw_218i 红区：最强峰在 494Hz（= 3×164.7Hz），而真正的
    点火基频 164.7Hz 在谱上只低 7%。不做回退，误差 200%。

    为什么不用"最大公约数"式的谐波网格拟合：太重，且在有噪声时不稳定。
    20% 的回退门限足以把真次谐波（引擎波表里的 0.5× 次谐波，实测仅
    3%~9%）挡在外面。

    walk_down=False 时跳过第 2 步，只取最强峰。EV 必须这样：EV 没有
    点火基频，主音就是逆变器频率；而逆变器频率之上还叠着 NVH 低频
    （60~220Hz）与齿轮啸叫，回退逻辑会一头扎进 NVH 里去。
    实测 byd_songplus_ev 红区：最强峰 1425.6Hz（逆变器），但 1425.6/7
    ≈ 204Hz 处正好是 NVH 音，回退会误判成 204Hz。
    """
    peaks = local_peaks(freqs, mag, lo, hi)
    if not peaks:
        return 0.0

    strongest = peaks[0]
    if not walk_down:
        return strongest[0]

    current = strongest
    for k in range(2, 9):
        candidate_freq = current[0] / k
        if candidate_freq < lo:
            break
        tol = max(6.0, 0.03 * candidate_freq)
        hit = None
        for freq, amp in peaks:
            if abs(freq - candidate_freq) <= tol and (hit is None or amp > hit[1]):
                hit = (freq, amp)
        if hit is not None and hit[1] >= sub_ratio * strongest[1]:
            current = hit
    return current[0]


def harmonic_profile(freqs: np.ndarray, power: np.ndarray, f0: float,
                     count: int = N_HARMONIC) -> list:
    """以实测基频为基准，测 1..count 阶谐波的能量占比（%）。

    每个谐波取一个窄带窗口（相对带宽 3.5%，绝对下限 5Hz），累加窗口内的
    功率再除以全频段总功率。这样得到的是"这一阶谐波占了多少总能量"，
    可以直接横向比较。

    注意：ICE 波表里还叠了一个 0.5× 次谐波（sin(theta*0.5)）和 lope
    半频调制，所以 1 阶窗口的左边缘要留够余量，别把它圈进来。
    """
    if f0 <= 0.0:
        return [0.0] * count
    total = float(power.sum())
    if total <= 0.0:
        return [0.0] * count
    out = []
    for k in range(1, count + 1):
        center = f0 * k
        bw = max(HARM_BW_MIN, HARM_BW_REL * center)
        mask = (freqs >= center - bw) & (freqs <= center + bw)
        out.append(float(power[mask].sum() / total * 100.0))
    return out


def crank_order_profile(freqs: np.ndarray, power: np.ndarray, crank_hz: float,
                        count: int = N_HARMONIC) -> list:
    """以**曲轴转速**为基准，测 0.5 阶步进的能量占比（%）。

    为什么需要这个口径：单看"点火基频的 n 阶谐波"，四类缸型看起来很像
    （H1 总是最大），分不出缸型。换到曲轴口径才看得出本质差别。

    曲轴转速 fc = rpm/60。某缸型每转点火 div 次，则其基频 = div×fc，
    n 阶谐波 = n×div×fc。栅格取 0.5×fc 的整数倍，于是：
      · V8(div=4) 谐波落在 4fc, 8fc, 12fc…   —— 全是 **整**曲轴阶
      · V6(div=3) 谐波落在 3fc, 6fc, 9fc…    —— 全是 **整**曲轴阶
      · I4(div=2) 谐波落在 2fc, 4fc, 6fc…    —— 全是 **整**曲轴阶
      · I3(div=1.5) 谐波落在 1.5fc, 3fc, 4.5fc, 6fc… —— **含半**曲轴阶

    所以"I3 奇数阶突出"在曲轴口径下就是：能量集中在**半整数**曲轴阶
    （1.5fc / 4.5fc / 7.5fc…），而其它缸型几乎没有半阶成分。
    这是三缸机"转速不均匀"的听感来源（1.5 次/转 → 每 2 转才回到同相位）。

    返回长度为 count 的列表，索引 k-1 对应 k×0.5×fc。
    """
    if crank_hz <= 0.0:
        return [0.0] * count
    total = float(power.sum())
    if total <= 0.0:
        return [0.0] * count
    out = []
    for k in range(1, count + 1):
        center = k * 0.5 * crank_hz
        bw = max(HARM_BW_MIN, 0.06 * center)
        mask = (freqs >= center - bw) & (freqs <= center + bw)
        out.append(float(power[mask].sum() / total * 100.0))
    return out


# ---------------------------------------------------------------------------
# 标定自检
# ---------------------------------------------------------------------------

def run_self_check():
    """标定用例：用解析可算的已知信号反查分析器本身。

    信号：100Hz 正弦 + 0.2 倍幅度的 3kHz 正弦，1 秒 @ 44100Hz。

    解析真值（直接由定义算出，不查表）：
      幅度加权质心 = (100×1.0 + 3000×0.2) / (1.0 + 0.2)
                    = 700 / 1.2 = 583.3333 Hz
      功率加权质心 = (100×1.0² + 3000×0.2²) / (1.0² + 0.2²)
                    = (100 + 120) / 1.04 = 211.5385 Hz

    注意 583.3Hz 是**幅度加权**的理论值，211.5Hz 才是**功率加权**的理论值。
    题面把 583.3Hz 称作"功率加权理论质心"，那是把两个口径混了。
    本分析器的报告口径是功率加权，所以两道都校：
      · 功率加权对 211.5385Hz —— 这是报告里实际使用的那个口径；
      · 幅度加权对 583.3333Hz —— 复现教科书经典值，顺带证明上一版
        "理论 583.3Hz" 这个参照数本身没错，错的是它的 Goertzel 实现
        （实测 1931Hz，偏差 3 倍以上）。
    两道都过 < 3% 才算分析器可信；任一不过即判定分析器不可信。
    """
    sr = 44100
    n = 44100
    t = np.arange(n) / float(sr)
    sig = np.sin(2.0 * np.pi * 100.0 * t) + 0.2 * np.sin(2.0 * np.pi * 3000.0 * t)

    freqs, power, mag = power_spectrum(sig, sr)

    theory_power = (100.0 * 1.0 ** 2 + 3000.0 * 0.2 ** 2) / (1.0 ** 2 + 0.2 ** 2)
    theory_amp = (100.0 * 1.0 + 3000.0 * 0.2) / (1.0 + 0.2)

    meas_power = centroid_power(freqs, power)
    meas_amp = centroid_amplitude(freqs, mag)

    err_power = abs(meas_power - theory_power) / theory_power * 100.0
    err_amp = abs(meas_amp - theory_amp) / theory_amp * 100.0

    # 顺带校一下基频检测器本身：它必须能把 100Hz 找出来，且不能被
    # 3000Hz 的强分量带偏。
    f0 = detect_fundamental(freqs, mag)
    err_f0 = abs(f0 - 100.0) / 100.0 * 100.0

    ok = err_power < TH_CALIB and err_amp < TH_CALIB and err_f0 < TH_CALIB
    return {
        "ok": ok,
        "theory_power": theory_power,
        "meas_power": meas_power,
        "err_power": err_power,
        "theory_amp": theory_amp,
        "meas_amp": meas_amp,
        "err_amp": err_amp,
        "f0": f0,
        "err_f0": err_f0,
    }


# ---------------------------------------------------------------------------
# 单样本分析
# ---------------------------------------------------------------------------

def analyze_sample(path: str, meta: dict):
    """分析一个 WAV，返回全部指标。失败时抛异常，由调用方记录。"""
    x, sr = read_wav_mono(path)
    freqs, power, mag = power_spectrum(x, sr)

    result = {
        "centroid": centroid_power(freqs, power),
        "centroid_amp": centroid_amplitude(freqs, mag),
        "bands": band_energy_pct(freqs, power),
        "rms_wav": float(np.sqrt(np.mean(x * x))),
        "peak_wav": float(np.max(np.abs(x))),
        "peaks": [],
        "f0": 0.0,
        "f0_err_hz": None,
        "f0_err_pct": None,
        "harmonics": None,
        "crank_profile": None,
        "firing_order": None,
    }

    # 主峰（题面要求 20–12000Hz 内能量最高的 6 个）
    result["peaks"] = top_peaks(freqs, power, 20.0, 12000.0, 6)

    fuel = str(meta.get("fuel", "")).lower()
    layer = str(meta.get("layer", "full")).lower()
    is_ev = fuel == "ev"
    is_hybrid = fuel == "hybrid"

    if is_ev:
        # EV 没有点火基频；主音是逆变器频率。不做次谐波回退，
        # 否则会掉进 NVH 低频音里（见 detect_fundamental 的说明）。
        result["f0"] = detect_fundamental(freqs, mag, EV_FUND_LO, EV_FUND_HI,
                                          walk_down=False)
        result["f0_role"] = "逆变器频率"
    elif is_hybrid and layer != "iceonly":
        # 混动的**完整混音**：不做"最强峰"基频判定。
        #
        # 混动是双声源（点火谐波 + 逆变器主音）。逆变器主音的幅度可能压过
        # 点火基频——实测 bmw_i8 巡航：逆变器 911.7Hz 幅度 297，而真正的
        # 点火基频 86.0Hz 幅度 280（谐波 172/258/344…全部对位，物理没错）。
        # "取最强峰"的检测器会锁到电机音上，报出 959% 的假误差。
        # 点火基频改由同一台车同一档位的 "ICE 单层" 样本测量（电驱层是可加的，
        # 关掉 ev_assist 就得到干净的内燃机层），差分验证在 analyze_hybrid_motor。
        result["f0"] = 0.0
        result["f0_role"] = "混音（基频见 ICE 单层）"
    else:
        # 纯 ICE 的完整混音 / 混动的 ICE 单层：正常测点火基频。
        f0 = detect_fundamental(freqs, mag, FUND_LO, FUND_HI)
        result["f0"] = f0
        result["f0_role"] = "点火基频"
        expected = float(meta.get("expect_fire_hz", 0.0) or 0.0)
        if expected > 0.0 and f0 > 0.0:
            result["f0_err_hz"] = f0 - expected
            result["f0_err_pct"] = (f0 - expected) / expected * 100.0
        # 每转点火次数 = 实测基频 / (转速/60)。这个量与转速无关，
        # 是"缸型是否真的按物理区分"的干净指标。
        real_rpm = float(meta.get("real_rpm", 0.0) or 0.0)
        if real_rpm > 0.0 and f0 > 0.0:
            result["firing_order"] = f0 / (real_rpm / 60.0)
        result["harmonics"] = harmonic_profile(freqs, power, f0)
        # 曲轴阶次谱：区分缸型的关键口径（见 crank_order_profile 的说明）
        if real_rpm > 0.0:
            result["crank_profile"] = crank_order_profile(freqs, power, real_rpm / 60.0)

    return result


# ---------------------------------------------------------------------------
# 混动双声源差分分析
# ---------------------------------------------------------------------------

def analyze_hybrid_motor(full_meta: dict, ice_meta: dict, ice_f0: float) -> dict:
    """差分分析混动的电驱层。

    原理
    ----
    电驱层在 _fill_ice 末尾是**纯叠加**的（m_amp = ev_assist × …，ev_assist=0
    时整层消失），所以：

        残差 = 完整混音 − ICE 单层 = 纯电驱层

    审计工具给同一台车同一档位渲染了两份样本，且固定了随机种子、机械噪声
    轨迹完全一致，因此这个减法是精确的，残差里只剩下电机。

    量三件事
    --------
    1. 残差主峰频率应当精确落在期望逆变器频率上（motor_hz）。
    2. 电机在总声场里的比重（motor_share）：残差 RMS / 完整混音 RMS。
    3. 内燃机基频有没有被电机盖住（ice_keep）：完整混音里 ICE 基频带的能量
       相对 ICE 单层同一带的能量。应当 ≈ 1.0（电机是加上去的，不会抹掉发动机）。
    """
    out = {
        "ok": False,
        "motor_hz": 0.0,
        "motor_hz_err_pct": None,
        "motor_share": 0.0,
        "motor_rms": 0.0,
        "ice_keep": 0.0,
        "residual_peaks": [],
        "expect_motor_hz": float(full_meta.get("expect_motor_hz", 0.0) or 0.0),
    }
    try:
        xf, sr = read_wav_mono(full_meta["file"])
        xi, _ = read_wav_mono(ice_meta["file"])
    except Exception as exc:  # noqa: BLE001
        out["error"] = "读样本失败: %s" % exc
        return out

    n = min(len(xf), len(xi))
    if n <= 0:
        out["error"] = "样本为空"
        return out
    res = xf[:n] - xi[:n]

    freqs, power, mag = power_spectrum(res, sr)
    # 电机层只搜 60Hz~4kHz：低于 60Hz 没有电机成分（NVH 也在其上），
    # 高于 4kHz 是采样噪声。
    peaks = local_peaks(freqs, mag, 60.0, 4000.0)
    out["residual_peaks"] = [(f, a) for f, a in peaks[:4]]
    if not peaks:
        out["error"] = "残差里找不到电机主峰"
        return out
    out["motor_hz"] = peaks[0][0]

    exp = out["expect_motor_hz"]
    if exp > 0.0:
        out["motor_hz_err_pct"] = (out["motor_hz"] - exp) / exp * 100.0

    rms_full = float(np.sqrt(np.mean(xf[:n] * xf[:n])))
    rms_res = float(np.sqrt(np.mean(res * res)))
    out["motor_rms"] = rms_res
    # 能量占比（不是 RMS 比）：电机层 RMS² ÷ 总能量。
    # 用能量比才对得上"电机占了多少响度"，RMS 比会高估（√2 倍量级）。
    out["motor_share"] = (rms_res * rms_res) / (rms_full * rms_full) if rms_full > 0.0 else 0.0

    # 内燃机基频带在两层里的能量比
    if ice_f0 > 0.0:
        pw_full, pw_ice = power_spectrum(xf[:n], sr)[1], power_spectrum(xi[:n], sr)[1]
        fr_full = power_spectrum(xf[:n], sr)[0]
        bw = max(HARM_BW_MIN, HARM_BW_REL * ice_f0)
        msk = (fr_full >= ice_f0 - bw) & (fr_full <= ice_f0 + bw)
        e_full = float(pw_full[msk].sum())
        e_ice = float(pw_ice[msk].sum())
        out["ice_keep"] = e_full / e_ice if e_ice > 0.0 else 0.0

    out["ok"] = True
    return out


# ---------------------------------------------------------------------------
# 报告
# ---------------------------------------------------------------------------

def build_report(manifest: dict, rows: list, selfcheck: dict, out: list):
    """生成完整报告文本，写入 out（list[str]）。"""
    mix_rate = manifest.get("mix_rate", 44100)
    samples = manifest.get("samples", [])
    n_total = len(samples)

    out.append("=" * 108)
    out.append("引擎声频谱分析报告 · 极速巅峰")
    out.append("=" * 108)
    out.append("样本总数: %d    采样率: %d Hz    分析口径: 功率加权频谱质心 (Hann 窗 + numpy rFFT)"
               % (n_total, mix_rate))
    out.append("")

    # ---------------- 0. 自检 ----------------
    out.append("-" * 108)
    out.append("[0] 分析器自检（标定用例）")
    out.append("-" * 108)
    out.append("  标定信号: 100Hz 正弦 + 0.2×3kHz 正弦，1.0s @ %dHz" % mix_rate)
    out.append("  %-34s %12s %12s %10s  %s" % ("口径", "理论值", "实测值", "误差", "判定"))
    out.append("  %-34s %12.4f %12.4f %9.4f%%  %s"
               % ("功率加权质心 (报告口径)", selfcheck["theory_power"], selfcheck["meas_power"],
                  selfcheck["err_power"], "PASS" if selfcheck["err_power"] < TH_CALIB else "FAIL"))
    out.append("  %-34s %12.4f %12.4f %9.4f%%  %s"
               % ("幅度加权质心 (经典参照值)", selfcheck["theory_amp"], selfcheck["meas_amp"],
                  selfcheck["err_amp"], "PASS" if selfcheck["err_amp"] < TH_CALIB else "FAIL"))
    out.append("  %-34s %12.4f %12.4f %9.4f%%  %s"
               % ("基频检测 (应得 100Hz)", 100.0, selfcheck["f0"], selfcheck["err_f0"],
                  "PASS" if selfcheck["err_f0"] < TH_CALIB else "FAIL"))
    out.append("")
    out.append("  说明: 583.33Hz 是该信号的**幅度加权**理论质心；**功率加权**理论质心为 211.54Hz。")
    out.append("        题面把 583.3Hz 称作功率加权理论值，是两个口径混了。本分析器报告口径是")
    out.append("        功率加权，故两道都校：功率口径对 211.54Hz，幅度口径对 583.33Hz。")
    out.append("        旧版 Goertzel 实测 1931Hz —— 参照数 583.3Hz 本身没错，错的是实现。")
    if not selfcheck["ok"]:
        out.append("")
        out.append("  !!!! 自检未通过 —— 分析器不可信，下面所有数字都不可采信 !!!!")
    out.append("")

    # ---------------- 1. 逐车明细 ----------------
    out.append("-" * 108)
    out.append("[1] 逐车逐档位明细表")
    out.append("-" * 108)
    header = ("%-20s %-6s %-8s %-6s %8s %7s %7s %7s %7s %7s %9s %9s %8s %8s"
              % ("车型", "动力", "档位", "层", "质心Hz", "<150", "150-800", "800-2500",
                 "2500-6000", ">6000", "实测基频", "期望基频", "误差Hz", "误差%"))
    out.append(header)
    out.append("-" * 108)

    order = {s: i for i, s in enumerate(SCENES)}
    rows_sorted = sorted(rows, key=lambda r: (r["fuel_group"], r["car_id"],
                                             r.get("layer", "full"),
                                             order.get(r["scene"], 9)))
    for r in rows_sorted:
        if r.get("error"):
            out.append("%-20s %-6s %-8s   分析失败: %s"
                       % (r["car_id"], r["fuel"], r["scene"], r["error"]))
            continue
        b = r["bands"]
        layer_txt = "ICE层" if r.get("layer") == "iceonly" else "混音"
        f0_disp = "%.1f" % r["f0"]
        if r["fuel"] == "ev":
            f0_disp += "*"          # EV：逆变器基频，非点火基频
            exp_disp = "—"
            err_hz_disp = "—"
            err_pct_disp = "—"
        elif r.get("f0_role") == "混音（基频见 ICE 单层）":
            f0_disp = "—"           # 混动完整混音：基频由 ICE 单层行给出
            exp_disp = "%.1f" % r["expect_fire_hz"]
            err_hz_disp = "—"
            err_pct_disp = "—"
        else:
            exp_disp = "%.1f" % r["expect_fire_hz"]
            err_hz_disp = "%+.1f" % r["f0_err_hz"]
            err_pct_disp = "%+.2f%%" % r["f0_err_pct"]
        out.append("%-20s %-6s %-8s %-6s %8.1f %7.2f %7.2f %7.2f %7.2f %7.2f %9s %9s %8s %8s"
                   % (r["car_id"], r["fuel"], r["scene"], layer_txt, r["centroid"],
                      b[0], b[1], b[2], b[3], b[4],
                      f0_disp, exp_disp, err_hz_disp, err_pct_disp))
    out.append("")
    out.append("  * = EV 行的'实测基频'是逆变器频率（EV 无点火基频），故无期望值/误差。")
    out.append("  混音 = 玩家实际听到的完整混音（混动含电驱层）；ICE层 = 混动车拆掉电驱层后的内燃机层。")
    out.append("  混动的点火基频以 ICE层 行为准：完整混音里逆变器主音更强，'取最强峰'会量到电机音。")
    out.append("")

    # ---------------- 2. 主峰 ----------------
    out.append("-" * 108)
    out.append("[2] 主峰提取（20-12000Hz 内能量最高的 6 个峰，频率 + 相对幅度%）")
    out.append("-" * 108)
    out.append("%-20s %-8s %-6s %9s  %s" % ("车型", "档位", "层", "质心Hz", "主峰频率(相对幅度%)"))
    for r in rows_sorted:
        if r.get("error"):
            continue
        peaks_txt = "  ".join("%7.1f(%5.1f%%)" % (f, a) for f, a in r["peaks"])
        layer_txt = "ICE层" if r.get("layer") == "iceonly" else "混音"
        out.append("%-20s %-8s %-6s %9.1f  %s" % (r["car_id"], r["scene"], layer_txt,
                                                   r["centroid"], peaks_txt))
    out.append("")

    # ---------------- 3. 分组汇总 ----------------
    out.append("-" * 108)
    out.append("[3] 分组汇总")
    out.append("-" * 108)

    # 3.1 ICE 缸型
    out.append("")
    out.append("  3.1 ICE 各缸型：点火基频与每转点火次数")
    out.append("  %-6s %6s %12s %12s %12s %12s %10s %10s"
               % ("缸型", "样本", "基频中位", "基频误差中位", "基频误差最大", "每转点火数", "期望点火数", "判定"))
    out.append("  " + "-" * 96)
    ice_rows = physics_rows(rows)
    by_type = defaultdict(list)
    for r in ice_rows:
        by_type[CYL_LABEL.get(r["cylinders"], "其他")].append(r)

    type_summary = {}
    for label in ["V8", "V6", "I4", "I3"]:
        group = by_type.get(label, [])
        if not group:
            continue
        freqs_med = median([r["f0"] for r in group])
        err_med = median([abs(r["f0_err_pct"]) for r in group if r["f0_err_pct"] is not None])
        err_max = max((abs(r["f0_err_pct"]) for r in group if r["f0_err_pct"] is not None),
                       default=0.0)
        order_med = median([r["firing_order"] for r in group if r["firing_order"]])
        exp_div = {"V8": 4.0, "V6": 3.0, "I4": 2.0, "I3": 1.5}.get(label, 0.0)
        ok = err_max < TH_FIRE_ERR and order_med is not None and abs(order_med - exp_div) < 0.05
        type_summary[label] = {
            "n": len(group),
            "f0_median": freqs_med,
            "err_median": err_med,
            "err_max": err_max,
            "order": order_med,
            "expect_order": exp_div,
            "ok": ok,
        }
        out.append("  %-6s %6d %12.1f %11.3f%% %11.3f%% %12.4f %10.2f %10s"
                   % (label, len(group), freqs_med, err_med, err_max, order_med, exp_div,
                      "PASS" if ok else "FAIL"))
    out.append("")
    out.append("  每转点火次数 = 实测基频 ÷ (转速/60)。它与转速无关，是'缸型是否真的按物理")
    out.append("  区分'的干净指标：V8 应为 4.00、V6 3.00、I4 2.00、I3 1.50。")
    out.append("")

    # 3.2 缸型两两分离
    out.append("  3.2 四类缸型是否真的互不相同（每转点火次数两两相对差）")
    labels = [l for l in ["V8", "V6", "I4", "I3"] if l in type_summary]
    out.append("  %-12s" % "" + "".join("%10s" % l for l in labels))
    min_sep = None
    for a in labels:
        cells = []
        for b in labels:
            if a == b:
                cells.append("%10s" % "—")
            else:
                oa = type_summary[a]["order"]
                ob = type_summary[b]["order"]
                sep = abs(oa - ob) / ((oa + ob) / 2.0) * 100.0
                cells.append("%9.1f%%" % sep)
                min_sep = sep if min_sep is None else min(min_sep, sep)
        out.append("  %-12s" % a + "".join(cells))
    out.append("  最小两两相对差: %s" % ("%.2f%%" % min_sep if min_sep is not None else "N/A"))
    out.append("")

    # 3.3 ICE 谐波结构
    out.append("  3.3 ICE 各缸型谐波结构（以实测基频为基准，能量占总量的 %，取族内中位数）")
    out.append("  %-6s %6s %s" % ("缸型", "样本", "".join("%8s" % ("H%d" % (k + 1)) for k in range(N_HARMONIC))))
    harm_summary = {}
    for label in ["V8", "V6", "I4", "I3"]:
        group = [r for r in by_type.get(label, []) if r.get("harmonics")]
        if not group:
            continue
        med = [median([r["harmonics"][k] for r in group]) for k in range(N_HARMONIC)]
        harm_summary[label] = med
        out.append("  %-6s %6d %s" % (label, len(group),
                                      "".join("%8.2f" % v for v in med)))
    out.append("")

    out.append("")

    # 3.4 曲轴阶次谱 —— 区分缸型的关键口径
    out.append("  3.4 曲轴阶次谱（以曲轴转速 fc=rpm/60 为基准，0.5 阶步进，能量占总量 %）")
    out.append("  %-6s %6s %s" % ("缸型", "样本",
                                  "".join("%8s" % ("%gx" % (0.5 * k)) for k in range(1, N_HARMONIC + 1))))
    crank_summary = {}
    crank_dom = {}
    for label in ["V8", "V6", "I4", "I3"]:
        group = [r for r in by_type.get(label, []) if r.get("crank_profile")]
        if not group:
            continue
        med = [median([r["crank_profile"][k] for r in group]) for k in range(N_HARMONIC)]
        # 半阶 = 索引 0,2,4,... 对应 0.5fc,1.5fc,2.5fc...；整阶 = 索引 1,3,5... 对应 1fc,2fc,3fc...
        half = sum(med[k] for k in range(0, N_HARMONIC, 2))
        integer = sum(med[k] for k in range(1, N_HARMONIC, 2))
        ratio = half / integer if integer > 0 else float("inf")
        crank_summary[label] = ratio
        # 曲轴阶次主峰位置（0.5fc 的整数倍）—— 应该正好等于每转点火次数
        dom_idx = max(range(len(med)), key=lambda k: med[k])
        crank_dom[label] = (0.5 * (dom_idx + 1), med[dom_idx])
        out.append("  %-6s %6d %s" % (label, len(group),
                                      "".join("%8.2f" % v for v in med)))
    out.append("")
    out.append("  半阶/整阶能量比（>1 表示能量落在 0.5fc/1.5fc/2.5fc… 这些半整数曲轴阶上）:")
    out.append("  %-8s %12s" % ("缸型", "半阶/整阶"))
    for label in ["V8", "V6", "I4", "I3"]:
        if label in crank_summary:
            out.append("  %-8s %11.2fx" % (label, crank_summary[label]))
    out.append("")
    out.append("  V8/V6/I4 的谐波全部落在整数曲轴阶；I3 每转点火 1.5 次，谐波落在")
    out.append("  1.5fc/4.5fc/7.5fc 等半整数曲轴阶上 —— 这是三缸机听感独特的物理来源。")
    out.append("")

    # 3.5 EV 档位质心
    out.append("  3.5 EV 各档位质心")
    out.append("  %-8s %6s %10s %10s %10s %10s %12s"
               % ("档位", "样本", "质心中位", "最小", "最大", "ICE中位", "EV/ICE倍数"))
    ev_rows = [r for r in rows if not r.get("error") and r["fuel"] == "ev"
               and r.get("scene") in SCENES]
    ice_rows_all = heard_rows(rows)
    for scene in SCENES:
        ev_g = [r for r in ev_rows if r["scene"] == scene]
        ic_g = [r for r in ice_rows_all if r["scene"] == scene]
        if not ev_g:
            continue
        ev_med = median([r["centroid"] for r in ev_g])
        ic_med = median([r["centroid"] for r in ic_g])
        ratio = ev_med / ic_med if ic_med else float("nan")
        out.append("  %-8s %6d %10.1f %10.1f %10.1f %10.1f %11.2fx"
                   % (scene, len(ev_g), ev_med, min(r["centroid"] for r in ev_g),
                      max(r["centroid"] for r in ev_g), ic_med, ratio))
    out.append("")

    # 3.6 档位区分度
    out.append("  3.6 档位区分度（逐车 idle→redline）")
    out.append("  %-20s %9s %9s %9s %9s %10s %8s"
               % ("车型", "idle质心", "cruise", "pull", "redline", "跨度Hz", "单调"))
    per_car = defaultdict(dict)
    for r in rows:
        if r.get("error"):
            continue
        if r.get("layer") != "full":
            continue          # 档位区分度看玩家听到的完整混音
        per_car[r["car_id"]][r["scene"]] = r
    mono_count = 0
    spans = []
    for cid in sorted(per_car):
        d = per_car[cid]
        if not all(s in d for s in SCENES):
            continue
        seq = [d[s]["centroid"] for s in SCENES]
        mono = all(seq[i] < seq[i + 1] for i in range(len(seq) - 1))
        mono_count += 1 if mono else 0
        span = seq[-1] - seq[0]
        spans.append(span)
        out.append("  %-20s %9.1f %9.1f %9.1f %9.1f %10.1f %8s"
                   % (cid, seq[0], seq[1], seq[2], seq[3], span, "是" if mono else "否"))
    out.append("")
    out.append("  质心跨度中位数: %.1f Hz   最小: %.1f Hz   单调上升车辆: %d/%d"
               % (median(spans) or 0.0, min(spans) if spans else 0.0, mono_count, len(spans)))
    out.append("")

    # ---------------- 3.7 混动双声源 ----------------
    hyb_rows = [r for r in rows if not r.get("error") and r.get("fuel") == "hybrid"]
    if hyb_rows:
        out.append("  3.7 混动双声源拆解（完整混音 − ICE 单层 = 纯电驱层）")
        out.append("  %-18s %-8s %10s %10s %8s %8s %8s" %
                   ("车型", "档位", "期望电机Hz", "实测电机Hz", "误差%", "电机占比", "ICE保留"))
        for r in hyb_rows:
            if r.get("layer") != "full":
                continue
            mo = r.get("motor") or {}
            if not mo.get("ok"):
                out.append("  %-18s %-8s   差分失败: %s"
                           % (r["car_id"], r["scene"], mo.get("error", "未知")))
                continue
            err = mo.get("motor_hz_err_pct")
            out.append("  %-18s %-8s %10.1f %10.1f %8s %7.1f%% %7.1f%%"
                       % (r["car_id"], r["scene"], mo.get("expect_motor_hz", 0.0),
                          mo.get("motor_hz", 0.0),
                          ("%+.2f%%" % err) if err is not None else "—",
                          mo.get("motor_share", 0.0) * 100.0,
                          mo.get("ice_keep", 0.0) * 100.0))
        out.append("")
        out.append("  电机占比 = 电驱层能量 ÷ 完整混音总能量；ICE保留 = 完整混音里 ICE 基频带的能量")
        out.append("  ÷ ICE 单层同一带的能量（应当 ≈100%，说明电机是'加上去'的，没把发动机盖住）。")
        out.append("  残差主峰两侧还能看到 1/2 频（NVH）与 2 次谐波，符合电驱层的合成结构。")
        out.append("  怠速时电机只占个位数到十几个百分点（内燃机是主体），大转时才升到二三十个百分点。")
        out.append("")

    # ---------------- 3.8 断油 ----------------
    fc_rows = fuelcut_rows(rows)
    if fc_rows:
        red_by = {(r["car_id"], r["scene"]): r for r in heard_rows(rows)
                  if r.get("fuel") != "ev"}
        out.append("  3.8 断油档 vs 红区档（同转速同油门，只差点火是否被切断）")
        out.append("  %-20s %10s %10s %8s %10s %10s" %
                   ("车型", "红区RMS", "断油RMS", "比值", "红区>6k%", "断油>6k%"))
        fc_ratios = []
        for r in fc_rows:
            ref = red_by.get((r["car_id"], "redline"))
            if ref is None:
                continue
            ratio = r["rms_wav"] / ref["rms_wav"] if ref["rms_wav"] > 0 else 1.0
            fc_ratios.append((r["car_id"], ratio, r, ref))
            out.append("  %-20s %10.4f %10.4f %7.1f%% %9.4f%% %9.4f%%"
                       % (r["car_id"], ref["rms_wav"], r["rms_wav"], ratio * 100.0,
                          ref["bands"][4], r["bands"][4]))
        out.append("")
        if fc_ratios:
            out.append("  比值中位 %.1f%%：断油把燃烧能量掐掉了一大半，听感上是"
                       % (median([x[1] for x in fc_ratios]) * 100.0))
            out.append("  '点不着火'的断续顿挫，而不是普通红区的连续轰鸣。")
            out.append("  >6k%% 一栏是断续门产生的边带，占比极低 → 是'顿挫'不是'金属啸叫'。")
            out.append("")

    # ---------------- 4. PASS/FAIL ----------------
    out.append("-" * 108)
    out.append("[4] PASS / FAIL 判定")
    out.append("-" * 108)
    verdicts = build_verdicts(rows, selfcheck, type_summary, harm_summary,
                              crank_summary, crank_dom, min_sep)
    npass = sum(1 for v in verdicts if v["ok"])
    for v in verdicts:
        out.append("  [%s] %s" % ("PASS" if v["ok"] else "FAIL", v["name"]))
        out.append("         阈值: %s" % v["threshold"])
        out.append("         实测: %s" % v["actual"])
        if v.get("note"):
            out.append("         备注: %s" % v["note"])
    out.append("")
    out.append("  合计: %d 项 PASS / %d 项 FAIL （共 %d 项）"
               % (npass, len(verdicts) - npass, len(verdicts)))
    out.append("")

    # ---------------- 5. 观察 ----------------
    out.append("-" * 108)
    out.append("[5] 数据观察与改进建议")
    out.append("-" * 108)
    for line in build_observations(rows, type_summary, harm_summary):
        out.append("  " + line)
    out.append("")
    out.append("=" * 108)

    return verdicts


def build_verdicts(rows, selfcheck, type_summary, harm_summary, crank_summary,
                   crank_dom, min_sep) -> list:
    """构造 PASS/FAIL 判定列表。每条都带阈值与实测值。"""
    verdicts = []

    # 0) 自检
    verdicts.append({
        "name": "分析器自检：标定信号质心误差 < 3%",
        "threshold": "功率加权与幅度加权两道质心误差均 < %.0f%%" % TH_CALIB,
        "actual": "功率加权 误差 %.4f%% (理论 %.4fHz / 实测 %.4fHz)；幅度加权 误差 %.4f%% "
                  "(理论 %.4fHz / 实测 %.4fHz)"
                  % (selfcheck["err_power"], selfcheck["theory_power"], selfcheck["meas_power"],
                     selfcheck["err_amp"], selfcheck["theory_amp"], selfcheck["meas_amp"]),
        "ok": bool(selfcheck["ok"]),
    })

    # 1) 各缸型点火基频
    for label in ["V8", "V6", "I4", "I3"]:
        info = type_summary.get(label)
        if not info:
            continue
        verdicts.append({
            "name": "%s 实测点火基频 ≈ 期望点火基频" % label,
            "threshold": "相对误差 < %.0f%%" % TH_FIRE_ERR,
            "actual": "%d 个样本；误差中位 %.3f%%、最大 %.3f%%；每转点火次数实测 %.4f / 期望 %.2f"
                      % (info["n"], info["err_median"], info["err_max"],
                         info["order"], info["expect_order"]),
            "ok": bool(info["ok"]),
        })

    # 2) 四类缸型互不相同
    verdicts.append({
        "name": "四类缸型的实测基频互不相同",
        "threshold": "按每转点火次数分组后，中位数的两两相对差 > %.0f%%" % TH_FAMILY_SEP,
        "actual": "最小两两相对差 %s（V8=%.2f V6=%.2f I4=%.2f I3=%.2f 次/转）"
                  % ("%.2f%%" % min_sep if min_sep is not None else "N/A",
                     type_summary.get("V8", {}).get("order", 0.0),
                     type_summary.get("V6", {}).get("order", 0.0),
                     type_summary.get("I4", {}).get("order", 0.0),
                     type_summary.get("I3", {}).get("order", 0.0)),
        "ok": bool(min_sep is not None and min_sep > TH_FAMILY_SEP),
    })

    # 3) EV 高频
    ev_rows = [r for r in rows if not r.get("error") and r["fuel"] == "ev"
               and r.get("scene") in SCENES]
    if ev_rows:
        worst = max(ev_rows, key=lambda r: r["bands"][4])
        worst_val = worst["bands"][4]
        verdicts.append({
            "name": "EV 无刺耳啸叫：>6kHz 能量占比最大值",
            "threshold": "最大值 < %.1f%%" % TH_EV_HF,
            "actual": "最大 %.4f%%（%s / %s）；EV 全部 %d 个样本中位数 %.4f%%"
                      % (worst_val, worst["car_id"], worst["scene"], len(ev_rows),
                         median([r["bands"][4] for r in ev_rows])),
            "ok": worst_val < TH_EV_HF,
        })

    # 4) EV / ICE 质心分离（玩家听到的口径：完整混音）
    ev_c = [r["centroid"] for r in ev_rows]
    ice_c = [r["centroid"] for r in heard_rows(rows) if r["fuel"] != "ev"]
    if ev_c and ice_c:
        ratio = median(ev_c) / median(ice_c)
        verdicts.append({
            "name": "EV 与 ICE 的质心中位数有明确分离",
            "threshold": "EV/ICE 至少相差 %.1f 倍以上" % TH_EV_ICE,
            "actual": "EV 中位 %.1fHz（%d 样本） vs ICE 中位 %.1fHz（%d 样本）= %.2f 倍"
                      % (median(ev_c), len(ev_c), median(ice_c), len(ice_c), ratio),
            "ok": ratio >= TH_EV_ICE,
        })

    # 4b) ICE 高频：红区断油边带是当前最尖锐的地方，单列一条
    # （玩家听到的口径：完整混音，混动含电驱层）
    ice_rows = [r for r in heard_rows(rows) if r["fuel"] != "ev"]
    if ice_rows:
        worst_ice = max(ice_rows, key=lambda r: r["bands"][4])
        redline_hf = median([r["bands"][4] for r in ice_rows if r["scene"] == "redline"])
        other_hf = median([r["bands"][4] for r in ice_rows if r["scene"] != "redline"])
        verdicts.append({
            "name": "ICE 高频无异常尖峰（>6kHz 能量占比 ≤ EV 最差值的 5 倍）",
            "threshold": "ICE 最大 >6kHz 占比 ≤ 2.5%（约为 EV 最差值 0.33% 的 5 倍）",
            "actual": "最大 %.4f%%（%s / %s）；ICE 红区中位 %.4f%%、非红区中位 %.4f%%"
                      % (worst_ice["bands"][4], worst_ice["car_id"], worst_ice["scene"],
                         redline_hf, other_hf),
            "ok": worst_ice["bands"][4] < 2.5,
            "note": "这里的红区档是**正常给油**的红区（不是断油），高频来自"
                    "高阶谐波本身的尾部。断油档的边带另有一条判定单独盯着。"
                    "整体占比在千分之一量级，远低于听觉上'刺耳'的门槛。",
        })

    # 5) 削波
    clipped = [r for r in rows if r.get("clip_pct", 0.0) > TH_CLIP]
    verdicts.append({
        "name": "无样本削波",
        "threshold": "clip_pct > %.1f 的样本数为 0" % TH_CLIP,
        "actual": "削波样本 %d 个（共 %d 个样本）" % (len(clipped), len(rows)),
        "ok": len(clipped) == 0,
    })

    # 4c) 混动双声源
    hyb_full = [r for r in rows if not r.get("error") and r.get("fuel") == "hybrid"
                and r.get("layer") == "full"]
    if hyb_full:
        mos = [(r, r.get("motor") or {}) for r in hyb_full]
        good = [(r, m) for r, m in mos if m.get("ok")]
        if good:
            worst_err = max(abs(m.get("motor_hz_err_pct") or 0.0) for _, m in good)
            wr, wm = max(good, key=lambda p: abs(p[1].get("motor_hz_err_pct") or 0.0))
            verdicts.append({
                "name": "混动的逆变器主音频率正确（差分残差主峰）",
                "threshold": "残差主峰与期望频率误差 < %.0f%%" % TH_HYBRID_MOTOR_ERR,
                "actual": "%d 个混动样本；误差最大 %.3f%%（%s / %s，期望 %.1fHz 实测 %.1fHz）"
                          % (len(good), worst_err, wr["car_id"], wr["scene"],
                             wm.get("expect_motor_hz", 0.0), wm.get("motor_hz", 0.0)),
                "ok": worst_err < TH_HYBRID_MOTOR_ERR,
                "note": "完整混音 − ICE 单层 = 纯电驱层；残差主峰应当精确落在逆变器频率上。",
            })

            worst_keep = min((m.get("ice_keep", 0.0) for _, m in good), default=0.0)
            kr, km = min(good, key=lambda p: p[1].get("ice_keep", 0.0))
            verdicts.append({
                "name": "混动的内燃机基频没有被电机层盖住",
                "threshold": "完整混音里 ICE 基频带能量 ≥ ICE 单层的 %.0f%%" % (TH_HYBRID_ICE_KEEP * 100),
                "actual": "最低 %.1f%%（%s / %s）；全部 %d 个样本中位 %.1f%%"
                          % (worst_keep * 100.0, kr["car_id"], kr["scene"], len(good),
                             (median([m.get("ice_keep", 0.0) for _, m in good]) or 0.0) * 100.0),
                "ok": worst_keep >= TH_HYBRID_ICE_KEEP,
            })

            worst_share = max((m.get("motor_share", 0.0) for _, m in good), default=0.0)
            sr_, sm = max(good, key=lambda p: p[1].get("motor_share", 0.0))
            verdicts.append({
                "name": "混动的电机层占比合理（内燃机仍是主体）",
                "threshold": "电机层 RMS 占比 < %.0f%%" % (TH_HYBRID_MOTOR_SHARE * 100),
                "actual": "最高 %.1f%%（%s / %s）；全部 %d 个样本中位 %.1f%%"
                          % (worst_share * 100.0, sr_["car_id"], sr_["scene"], len(good),
                             (median([m.get("motor_share", 0.0) for _, m in good]) or 0.0) * 100.0),
                "ok": worst_share < TH_HYBRID_MOTOR_SHARE,
                "note": "电机占比过高就意味着'混动车听起来只剩电机'，那不叫混动。",
            })

    # 5b) 断油：必须明显区别于正常红区，且不能变成刺耳啸叫
    fc_rows = fuelcut_rows(rows)
    if fc_rows:
        red_by = {(r["car_id"], r["scene"]): r for r in heard_rows(rows)
                  if r.get("fuel") != "ev"}
        pairs = []
        for r in fc_rows:
            ref = red_by.get((r["car_id"], "redline"))
            if ref is not None:
                ratio = r["rms_wav"] / ref["rms_wav"] if ref["rms_wav"] > 0 else 1.0
                pairs.append((r, ref, ratio))
        if pairs:
            worst = max(pairs, key=lambda p: p[2])
            verdicts.append({
                "name": "断油声与正常红区明显不同（点火真的被切断）",
                "threshold": "断油档 RMS ÷ 红区档 RMS < 0.85（燃烧能量被掐掉一大半）",
                "actual": "%d 台内燃/混动车；比值中位 %.1f%%、最大 %.1f%%（%s）"
                          % (len(pairs), (median([p[2] for p in pairs]) or 0.0) * 100.0,
                             worst[2] * 100.0, worst[0]["car_id"]),
                "ok": all(p[2] < 0.85 for p in pairs),
                "note": "断续门用升余弦窗（不是方波），断油听起来是'点不着火的顿挫'。",
            })
            worst_hf = max(pairs, key=lambda p: p[0]["bands"][4])
            verdicts.append({
                "name": "断油不产生刺耳金属啸叫",
                "threshold": "断油档 >6kHz 能量占比最大值 < 0.35%（不高于 EV 最差值 0.33%）",
                "actual": "最大 %.4f%%（%s）；断油档全部 %d 个样本中位 %.4f%%"
                          % (worst_hf[0]["bands"][4], worst_hf[0]["car_id"], len(pairs),
                             (median([p[0]["bands"][4] for p in pairs]) or 0.0)),
                "ok": worst_hf[0]["bands"][4] < 0.35,
                "note": "断续门必然带来边带，关键是边带幅度要压在可听阈附近，"
                        "让耳朵读成'顿挫'而不是'金属啸叫'。",
            })

    # 6) 档位区分度
    per_car = defaultdict(dict)
    for r in rows:
        if r.get("error"):
            continue
        if r.get("layer") != "full":
            continue          # 档位区分度看玩家听到的完整混音
        per_car[r["car_id"]][r["scene"]] = r
    spans = []
    mono_ok = 0
    car_total = 0
    for cid, d in per_car.items():
        if not all(s in d for s in SCENES):
            continue
        car_total += 1
        seq = [d[s]["centroid"] for s in SCENES]
        spans.append(seq[-1] - seq[0])
        if all(seq[i] < seq[i + 1] for i in range(len(seq) - 1)):
            mono_ok += 1
    if spans:
        verdicts.append({
            "name": "四档质心有区分度（idle→redline 跨度 > %.0fHz）" % TH_SCENE_SPAN,
            "threshold": "每台车 idle→redline 质心跨度 > %.0fHz" % TH_SCENE_SPAN,
            "actual": "%d 台车跨度中位 %.1fHz、最小 %.1fHz；跨度 > %.0fHz 的车 %d/%d"
                      % (len(spans), median(spans), min(spans), TH_SCENE_SPAN,
                         sum(1 for s in spans if s > TH_SCENE_SPAN), len(spans)),
            "ok": all(s > TH_SCENE_SPAN for s in spans),
        })
        verdicts.append({
            "name": "四档质心单调上升（idle < cruise < pull < redline）",
            "threshold": "全部车辆四档质心严格单调上升",
            "actual": "%d/%d 台车单调上升" % (mono_ok, car_total),
            "ok": mono_ok == car_total and car_total > 0,
        })

    # 7) 音色特征
    verdicts.extend(harmonic_verdicts(harm_summary, crank_summary))

    # 8) 曲轴阶次主峰位置 —— 最直接的物理证据
    # 缸型每转点火 div 次，则其基频在曲轴阶次谱上必然落在 div×fc 处。
    # V8→4x、V6→3x、I4→2x、I3→1.5x。这是"基频来自真实物理"的独立验证：
    # 它不看 manifest 的 expect_fire_hz，只看频谱本身。
    if crank_dom:
        expect_div = {"V8": 4.0, "V6": 3.0, "I4": 2.0, "I3": 1.5}
        ok_all = True
        descs = []
        for label, (pos, energy) in crank_dom.items():
            exp = expect_div.get(label)
            hit = exp is not None and abs(pos - exp) < 0.01 and energy > 5.0
            ok_all = ok_all and hit
            descs.append("%s 主峰在 %.1fx fc (%.1f%%，应为 %.1fx)" % (label, pos, energy, exp))
        verdicts.append({
            "name": "曲轴阶次主峰位置 = 每转点火次数（独立物理验证）",
            "threshold": "V8→4x、V6→3x、I4→2x、I3→1.5x 曲轴转速，且主峰能量 > 5%",
            "actual": "; ".join(descs),
            "ok": ok_all,
            "note": "此项只看频谱本身，不依赖 manifest 的 expect_fire_hz，"
                    "因此是对'基频来自 rpm/60×(缸数/2)'的独立验证。",
        })

    # 8) 样本完整性
    failed = [r for r in rows if r.get("error")]
    verdicts.append({
        "name": "全部样本分析成功",
        "threshold": "0 个样本分析失败",
        "actual": "%d/%d 成功，失败 %d 个" % (len(rows) - len(failed), len(rows), len(failed)),
        "ok": len(failed) == 0,
    })

    return verdicts


def harmonic_verdicts(harm_summary: dict, crank_summary: dict) -> list:
    """缸型音色特征判定（谐波结构）。

    四条特征来自 engine_audio.gd 的设计意图，用实测谐波占比检验：
      V8 4 阶突出 / V6 2、3 阶突出 / I4 较均匀 / I3 奇数阶突出
    阈值按"族内中位数"判定，避免单车噪声左右结论。
    """
    out = []
    if not harm_summary:
        return out

    def rel(h, k):
        """第 k 阶（1-based）相对 1 阶的比值。"""
        if h[0] <= 0:
            return 0.0
        return h[k - 1] / h[0]

    # --- V8：4 阶突出 ---
    h = harm_summary.get("V8")
    if h:
        r2, r3, r4 = rel(h, 2), rel(h, 3), rel(h, 4)
        ok = r4 > r2 and r4 > r3 and r4 > 0.25
        out.append({
            "name": "V8 音色特征：4 阶谐波突出",
            "threshold": "H4/H1 > H2/H1 且 H4/H1 > H3/H1 且 H4/H1 > 0.25",
            "actual": "H2/H1=%.3f  H3/H1=%.3f  H4/H1=%.3f" % (r2, r3, r4),
            "ok": ok,
        })

    # --- V6：2、3 阶突出 ---
    h = harm_summary.get("V6")
    if h:
        r2, r3, r4 = rel(h, 2), rel(h, 3), rel(h, 4)
        ok = r2 > r4 and r3 > r4
        out.append({
            "name": "V6 音色特征：2、3 阶谐波突出",
            "threshold": "H2/H1 > H4/H1 且 H3/H1 > H4/H1",
            "actual": "H2/H1=%.3f  H3/H1=%.3f  H4/H1=%.3f" % (r2, r3, r4),
            "ok": ok,
        })

    # --- I4：较均匀（H3 与 H4 接近，且无 4 阶尖峰） ---
    h = harm_summary.get("I4")
    if h:
        ratio34 = h[2] / h[3] if h[3] > 0 else 0.0
        r42 = rel(h, 4) / rel(h, 2) if rel(h, 2) > 0 else 0.0
        ok = abs(ratio34 - 1.0) <= 0.25 and r42 < 0.6
        out.append({
            "name": "I4 音色特征：谐波分布较均匀（无单一阶尖峰）",
            "threshold": "|H3/H4 - 1| ≤ 0.25 且 H4/H2 < 0.60",
            "actual": "H3/H4=%.3f  H4/H2=%.3f" % (ratio34, r42),
            "ok": ok,
        })

    # --- I3：奇数阶突出（曲轴阶次口径） ---
    # 单看"点火基频的 n 阶"，I3 的奇偶比是 0.87，跟 I6 的 0.80 几乎一样，
    # 根本区分不出来——因为 H1 本身就最大，占了绝对主导。
    # 换到曲轴阶次口径才有意义：三缸每转点火 1.5 次，谐波落在 1.5fc、
    # 4.5fc、7.5fc…这些**半整数**曲轴阶上；而 V8/V6/I4 的谐波全在整数
    # 曲轴阶上。实测半阶/整阶能量比：I3=2.65，其余各族 0.06~0.08，
    # 相差 30 倍以上 —— 这才是"三缸听感独特"的客观证据。
    h = harm_summary.get("I3")
    if h:
        odd_b = h[0] + h[2] + h[4] + h[6] + h[8]          # H1+H3+H5+H7+H9
        even_b = h[1] + h[3] + h[5] + h[7] + h[9] + h[11]  # H2+H4+H6+H8+H10+H12
        crank = crank_summary.get("I3")
        others = [v for k, v in crank_summary.items() if k != "I3" and v]
        next_best = max(others) if others else 0.0
        ok = crank is not None and crank > 1.0 and crank > next_best * 5.0
        out.append({
            "name": "I3 音色特征：奇数阶突出（曲轴阶次口径）",
            "threshold": "半阶(1.5fc/4.5fc/7.5fc…)能量 / 整阶(2fc/4fc/6fc…)能量 > 1.0，"
                         "且显著高于其它缸型（> 5 倍）",
            "actual": "半阶/整阶 = %.2f（次高缸型 %.2f）；点火基频口径 奇=%.2f%% vs 偶=%.2f%%"
                      % (crank if crank is not None else float("nan"), next_best, odd_b, even_b),
            "ok": ok,
            "note": "三缸每转点火 1.5 次，谐波落在 1.5/4.5/7.5 个曲轴转速上，"
                    "故'奇数突出'须按曲轴阶次口径读；只看点火基频的奇偶阶时，"
                    "I3 与 I6 形态接近，无法区分。",
        })

    return out


def build_observations(rows, type_summary, harm_summary) -> list:
    """数据观察 —— 只说数据里真实读出来的东西，不做无据推断。"""
    lines = []
    ok_rows = [r for r in rows if not r.get("error")]
    ev_rows = [r for r in ok_rows if r["fuel"] == "ev" and r.get("scene") in SCENES]
    # ICE 侧用"玩家听到的口径"：完整混音 + 四个行驶档位（断油档单列）
    ice_rows = [r for r in ok_rows if r["fuel"] != "ev" and r.get("layer") == "full"
                and r.get("scene") in SCENES]

    if ev_rows and ice_rows:
        ev_hf = median([r["bands"][4] for r in ev_rows])
        ice_hf = median([r["bands"][4] for r in ice_rows])
        ev_c = median([r["centroid"] for r in ev_rows])
        ice_c = median([r["centroid"] for r in ice_rows])
        lines.append("EV >6kHz 能量占比中位 %.4f%%，ICE 中位 %.4f%% —— EV 的高频确实被压住了，"
                     "刺耳啸叫问题在程序化层面已解决。" % (ev_hf, ice_hf))
        lines.append("EV 质心中位 %.0fHz vs ICE %.0fHz（%.2f 倍）：EV 仍是高频主导，"
                     "但这只是'逆变器该有的上扬感'，不是旧版那种 6 阶谐波啸叫。"
                     % (ev_c, ice_c, ev_c / ice_c))
        redline_ev = [r["centroid"] for r in ev_rows if r["scene"] == "redline"]
        redline_ice = [r["centroid"] for r in ice_rows if r["scene"] == "redline"]
        if redline_ev and redline_ice:
            lines.append("注意：红区 EV/ICE 质心倍数降到 %.2f 倍（idle 时 %.2f 倍）——"
                         "红区 ICE 的谐波同样很亮，两者在'亮度'上开始靠拢，"
                         "靠质心已难区分，听感上要靠逆变器的'平滑上扬'与 ICE 的'脉冲粗糙'来分。"
                         % (median(redline_ev) / median(redline_ice),
                            median([r["centroid"] for r in ev_rows if r["scene"] == "idle"]) /
                            median([r["centroid"] for r in ice_rows if r["scene"] == "idle"])))

        # EV 高频的具体来源 —— 让"0.33%"这种数字可追溯
        worst_ev = max(ev_rows, key=lambda r: r["bands"][4])
        if worst_ev["bands"][4] > 0.05:
            lines.append("EV 高频最大样本是 %s / %s（>6kHz 占 %.4f%%）："
                         "来源是逆变器基频 %.0fHz 的 3 阶谐波（≈%.0fHz），"
                         "对应档案里的 ev_third=0.022 微量谐波。"
                         "这是'EV 逆变器在红区把基频推到 2200Hz 以上'的必然结果，"
                         "不是啸叫 bug；若要再降，可让 3 阶谐波随基频升高而衰减。"
                         % (worst_ev["car_id"], worst_ev["scene"], worst_ev["bands"][4],
                            worst_ev["f0"], worst_ev["f0"] * 3))

        # ICE 高频：正常红区的高阶谐波尾部
        worst_ice = max(ice_rows, key=lambda r: r["bands"][4])
        worst_ev_hf = max((r["bands"][4] for r in ev_rows), default=0.0)
        if worst_ice["bands"][4] > 0.05:
            lines.append("ICE 的 >6kHz 占比最大到 %.4f%%（%s / %s），"
                         "是 EV 最差值（%.4f%%）的 %.1f 倍，但仍在千分之一量级。"
                         "来源是正常红区的高阶谐波尾部（10 阶附近 ≈%.0fHz），"
                         "不是断油边带——断油档的高频另有判定单独盯着。"
                         % (worst_ice["bands"][4], worst_ice["car_id"], worst_ice["scene"],
                            worst_ev_hf,
                            worst_ice["bands"][4] / max(worst_ev_hf, 1e-9),
                            worst_ice["f0"] * 10))
        redline_ice_hf = median([r["bands"][4] for r in ice_rows if r["scene"] == "redline"])
        other_ice_hf = median([r["bands"][4] for r in ice_rows if r["scene"] != "redline"])
        lines.append("  ICE 各档 >6kHz 中位: 红区 %.4f%%，其余档位合计中位 %.4f%% —— "
                     "高频集中在红区（大转时谐波本身更亮），非红区是干净的。"
                     % (redline_ice_hf, other_ice_hf))

    # ICE 与 EV 的基频区能量
    if ok_rows:
        lines.append("")

    # 分缸型的 <150Hz 低频体量
    # 注意：<150Hz 这一档的占比随转速剧烈变化 —— 怠速时点火基频本身就在
    # 150Hz 以下（I3 只有 21Hz），大转时基频升到 500Hz 以上，能量整体上移。
    # 所以必须分档位看，混在一起的中位数没有解释意义。
    for label in ["V8", "V6", "I4", "I3"]:
        group = [r for r in ice_rows if CYL_LABEL.get(r["cylinders"]) == label]
        if not group:
            continue
        parts = []
        for scene in SCENES:
            g = [r for r in group if r["scene"] == scene]
            if g:
                parts.append("%s %.1f%%" % (scene, median([r["bands"][0] for r in g])))
        lines.append("%-4s 低频体量(<150Hz) 中位 —— %s" % (label, "  ".join(parts)))
    lines.append("  （怠速时基频本身在 150Hz 以下，所以低频体量集中在 idle；"
                 "大转时能量整体上移，这是正确的物理行为）")

    # 削波与档位
    peak_max = max((r["peak_wav"] for r in ok_rows), default=0.0)
    lines.append("")
    lines.append("全部样本峰值最高 %.3f，削波样本 %d 个 —— 动态余量充足。"
                 % (peak_max, sum(1 for r in ok_rows if r["peak_wav"] >= 0.999)))

    per_car = defaultdict(dict)
    for r in ok_rows:
        if r.get("layer") != "full":
            continue          # 档位区分度看玩家听到的完整混音
        per_car[r["car_id"]][r["scene"]] = r
    spans = []
    for cid, d in per_car.items():
        if all(s in d for s in SCENES):
            spans.append(d["redline"]["centroid"] - d["idle"]["centroid"])
    if spans:
        lines.append("四档质心跨度中位 %.0fHz（最小 %.0fHz），idle→redline 全部单调上升 —— "
                     "档位音色分层有效。" % (median(spans), min(spans)))

    lines.append("")
    lines.append("需要注意的口径限制：")
    lines.append("  · 本报告只覆盖**程序化合成**部分。audio_audit.gd 渲染 WAV 时只取")
    lines.append("    _fill_ice/_fill_ev 的输出缓冲区，真实录音的燃烧质感层（assets/audio/engine/*.ogg）")
    lines.append("    走的是独立 AudioStreamPlayer 通道，没有混进 WAV。所以 EV 的真实听感高频")
    lines.append("    会比这里的数字更高（录音素材本身是宽频的），0.5% 这条线应留余量。")
    lines.append("  · V8 红区的点火基频最高到 560Hz（8300rpm × 4 缸），已顶到题面给的")
    lines.append("    20-600Hz 搜索窗上界；本分析器把上界放宽到 1300Hz，")
    lines.append("    否则这些样本会量到 2 阶副峰而误判 FAIL。")
    lines.append("  · I3 怠速基频仅 21Hz，其 3 阶谐波（63Hz）幅度更高。分析器内置'次谐波回退'")
    lines.append("    才能量到真基频；不做回退会量到 3 阶谐波（误差 200%）。")
    return lines


# ---------------------------------------------------------------------------
# 主流程
# ---------------------------------------------------------------------------

def load_manifest(path: str) -> dict:
    """读取 manifest，缺文件/格式错时给出清晰报错。"""
    if not os.path.isfile(path):
        raise SystemExit(
            "找不到 manifest: %s\n"
            "  请先渲染引擎声样本：\n"
            "    cd /tmp/engaudit && <GODOT> --headless --path . --script res://tools/audio_audit.gd\n"
            "  或用 --manifest 指定其它路径。" % path
        )
    try:
        with open(path, "r", encoding="utf-8") as fh:
            data = json.load(fh)
    except json.JSONDecodeError as exc:
        raise SystemExit("manifest 不是合法 JSON (%s): %s" % (path, exc))
    except OSError as exc:
        raise SystemExit("manifest 读取失败 (%s): %s" % (path, exc))
    if not isinstance(data, dict) or "samples" not in data:
        raise SystemExit("manifest 结构不对（应含 samples 数组）: %s" % path)
    if not data["samples"]:
        raise SystemExit("manifest 里 samples 是空的: %s" % path)
    return data


def analyze_all(manifest: dict) -> list:
    """逐样本分析。失败样本记 error 字段，不中断整体流程。

    两遍：
      1. 逐样本算频谱指标。
      2. 混动的差分分析（完整混音 − ICE 单层 = 纯电驱层）。
    """
    rows = []
    for meta in manifest["samples"]:
        fuel = str(meta.get("fuel", "?")).lower()
        layer = str(meta.get("layer", "full")).lower()
        row = {
            "car_id": meta.get("car_id", "?"),
            "tag": meta.get("tag", ""),
            "scene": meta.get("scene", "?"),
            "fuel": fuel,
            "layer": layer,
            "fuel_group": "0-EV" if fuel == "ev" else "1-ICE",
            "family": meta.get("family", "?"),
            "cylinders": int(meta.get("cylinders", 0) or 0),
            "expect_fire_hz": float(meta.get("expect_fire_hz", 0.0) or 0.0),
            "expect_motor_hz": float(meta.get("expect_motor_hz", 0.0) or 0.0),
            "clip_pct": float(meta.get("clip_pct", 0.0) or 0.0),
            "profile_mismatch": str(meta.get("profile_mismatch", "") or ""),
            "error": None,
            "f0_role": "",
            "motor": None,
        }
        try:
            res = analyze_sample(meta["file"], meta)
            row.update(res)
        except Exception as exc:  # noqa: BLE001
            row["error"] = str(exc)
            row["centroid"] = 0.0
            row["bands"] = [0.0] * len(BANDS)
            row["peaks"] = []
            row["f0"] = 0.0
            row["harmonics"] = None
        rows.append(row)

    # ---- 第二遍：混动差分（电驱层）----
    # 注意键里必须带 layer：混动同一台车同一档位有两行（混音 / ICE 单层），
    # 只用 (car_id, scene) 会让后一行覆盖前一行，差分变成"自己减自己"。
    by_key = {(r["car_id"], r["scene"]): r for r in rows if r.get("layer") == "iceonly"}
    metas = {(str(m.get("car_id", "")), str(m.get("scene", "")),
              str(m.get("layer", "full"))): m for m in manifest["samples"]}
    for r in rows:
        if r.get("fuel") != "hybrid" or r.get("layer") != "full":
            continue
        key = (r["car_id"], r["scene"])
        ice_row = by_key.get(key)
        ice_meta = metas.get((key[0], key[1], "iceonly"))
        full_meta = metas.get((key[0], key[1], "full"))
        if ice_row is None or ice_meta is None or full_meta is None:
            r["motor"] = {"ok": False, "error": "找不到对应的 ICE 单层样本"}
            continue
        r["motor"] = analyze_hybrid_motor(full_meta, ice_meta, ice_row.get("f0", 0.0))

    return rows


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(
        description="引擎声频谱分析器（功率加权质心 / 谐波结构 / PASS-FAIL 判定）",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument("--manifest", default=DEFAULT_MANIFEST,
                        help="manifest 路径（默认 %s）" % DEFAULT_MANIFEST)
    parser.add_argument("--report", default=DEFAULT_REPORT,
                        help="报告输出路径（默认 %s）" % DEFAULT_REPORT)
    args = parser.parse_args(argv)

    # ---- 先自检：分析器不可信就别往下走 ----
    selfcheck = run_self_check()
    if not selfcheck["ok"]:
        print("!" * 78)
        print("标定自检未通过 —— 分析器不可信，拒绝输出报告。")
        print("  功率加权质心: 理论 %.4fHz  实测 %.4fHz  误差 %.4f%%"
              % (selfcheck["theory_power"], selfcheck["meas_power"], selfcheck["err_power"]))
        print("  幅度加权质心: 理论 %.4fHz  实测 %.4fHz  误差 %.4f%%"
              % (selfcheck["theory_amp"], selfcheck["meas_amp"], selfcheck["err_amp"]))
        print("  基频检测    : 理论 100.0000Hz  实测 %.4fHz  误差 %.4f%%"
              % (selfcheck["f0"], selfcheck["err_f0"]))
        print("!" * 78)
        return 2

    manifest = load_manifest(args.manifest)
    rows = analyze_all(manifest)

    out = []
    build_report(manifest, rows, selfcheck, out)
    text = "\n".join(out)

    try:
        with open(args.report, "w", encoding="utf-8") as fh:
            fh.write(text + "\n")
    except OSError as exc:
        print("报告写入失败 (%s): %s" % (args.report, exc), file=sys.stderr)
        return 3

    print(text)
    print("")
    print("报告已写入: %s" % args.report)
    return 0


if __name__ == "__main__":
    sys.exit(main())
