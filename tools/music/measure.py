#!/usr/bin/env python3
"""用 ffmpeg 的 ebur128/loudnorm 做权威响度计量（与现有 bgm_manifest.json 同口径）。

自己写的 S.lufs() 没做门限分段，量同一批现网曲子会低 3 dB 左右，写进清单
会让新旧曲目的数字看起来不一致。这里统一走 ffmpeg 的 ITU-R BS.1770-4 实现，
Integrated 就是曲库里 sourceLufs / lufs 字段的那个值。
"""

import json
import re
import subprocess

import song as G


def loudnorm(path):
    """返回 {'i': LUFS, 'tp': dBTP, 'lra': LU, 'threshold': LUFS}。"""
    proc = subprocess.run(
        [G.ffmpeg_bin(), "-hide_banner", "-nostats", "-i", path,
         "-af", "loudnorm=I=-18:TP=-1.5:LRA=11:print_format=json", "-f", "null", "-"],
        capture_output=True, text=True, check=True)
    text = proc.stderr
    start = text.rfind("{")
    end = text.rfind("}")
    if start < 0 or end < start:
        raise RuntimeError("loudnorm 输出无法解析:\n" + text[-800:])
    raw = json.loads(text[start:end + 1])
    return {"i": float(raw["input_i"]), "tp": float(raw["input_tp"]),
            "lra": float(raw["input_lra"]), "threshold": float(raw.get("input_thresh", "nan"))}


def ebur128(path):
    """多帧 ebur128 汇总（用于二次确认 Integrated/TruePeak，含单声道折叠）。"""
    proc = subprocess.run(
        [G.ffmpeg_bin(), "-hide_banner", "-nostats", "-i", path,
         "-filter_audio", "ebur128=peak=true", "-f", "null", "-"],
        capture_output=True, text=True)
    text = proc.stderr
    def grab(pattern):
        m = re.findall(pattern, text)
        return float(m[-1]) if m else float("nan")
    return {"i": grab(r"Integrated loudness:\s*\S*\s*([-\d.]+) LUFS"),
            "tp": grab(r"True peak:\s*([-\d.]+) dBFS"),
            "m": grab(r"M:\s+([-\d.]+)")}


if __name__ == "__main__":
    import sys
    for p in sys.argv[1:]:
        ln = loudnorm(p)
        print("%-28s I=%7.2f LUFS  TP=%6.2f dBTP  LRA=%5.2f" % (p.split("/")[-1], ln["i"], ln["tp"], ln["lra"]))
