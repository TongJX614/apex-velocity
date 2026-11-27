#!/usr/bin/env python3
"""把 library.py 的规格表渲染成游戏里的 OGG 主题曲，并写回 bgm_manifest.json。

流程
----
spec → genres.build_song()（母带、折成无缝循环）→ 16 bit WAV → libvorbis OGG
→ 解码回来实测（有损编码会动响度，清单里的数字必须是**最终文件**的）
→ 写 maps/audio/bgm/<id>.ogg + 更新 data/bgm_manifest.json。

字段口径与现有 18 条完全一致：id,name,cn,genre,bpm,map,color,file,
loopSeconds,samples,peak,rms,sourceLufs,lufs,gainDb,bytes。

用法
----
    python3 build.py --list
    python3 build.py --maps coast                 # 只出 demo，不写仓库
    python3 build.py --maps coast --write         # 写 ogg + manifest
    python3 build.py --write                      # 11 条全出
    python3 build.py --write --quality 180k

写完之后要在项目根跑一次 Godot 导入，让 .ogg.import 与 .godot/imported 生成：
    ~/Applications/Godot.app/Contents/MacOS/Godot --headless --import --path .
"""

import argparse
import json
import os
import subprocess
import sys
import tempfile
import time

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import genres                                            # noqa: E402
import library as LIB                                    # noqa: E402
import measure                                              # noqa: E402
import song as G                                         # noqa: E402
import synth as S                                        # noqa: E402

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
BGM_DIR = os.path.join(ROOT, "maps", "audio", "bgm")
MANIFEST = os.path.join(ROOT, "data", "bgm_manifest.json")


def _wav_path_for(spec, out_dir):
    return os.path.join(out_dir, "%s.wav" % spec["id"])


def ogg_seam_ratio(path, zone=240):
    """解码后再看循环点：Vorbis 的 pre-skip 与编码器延迟会把接缝挪位，
    所以"无缝"必须在最终文件上验证，而不是在内存里。"""
    tmp = tempfile.mktemp(suffix=".wav")
    subprocess.run([G.ffmpeg_bin(), "-y", "-loglevel", "error", "-i", path,
                    "-ac", "2", "-ar", str(S.SR), tmp], check=True)
    import wave
    with wave.open(tmp) as w:
        data = np.frombuffer(w.readframes(w.getnframes()), dtype="<i2").astype(np.float64) / 32768.0
    os.unlink(tmp)
    x = data.reshape(-1, 2).T
    d = np.abs(np.diff(x, axis=1))
    ref = float(np.percentile(d, 99.9)) + 1e-9
    return max(float(d[:, -zone:].max()), float(d[:, :zone].max())) / ref, x


def decode_stats(path):
    """用 ffmpeg 解回 PCM，实测最终文件的响度/峰值/样本数。"""
    tmp = tempfile.mktemp(suffix=".wav")
    subprocess.run([G.ffmpeg_bin(), "-y", "-loglevel", "error", "-i", path,
                    "-ac", "2", "-ar", str(S.SR), tmp], check=True)
    import wave
    with wave.open(tmp) as w:
        data = np.frombuffer(w.readframes(w.getnframes()), dtype="<i2").astype(np.float64) / 32768.0
        frames, ch = w.getnframes(), w.getnchannels()
    os.unlink(tmp)
    x = data.reshape(-1, ch).T
    return {"samples": int(frames), "loopSeconds": round(frames / S.SR, 2),
            "peak": round(float(np.max(np.abs(x))), 4), "rms": round(_rms(x), 4),
            "lufs": round(S.lufs(x), 2)}


def _rms(x):
    return float(np.sqrt(np.mean(np.asarray(x) ** 2)))


def seam_error(x):
    """接缝处是否出现"跳步"：循环点附近的样本差 vs 全曲样本差的 99.9 分位。

    音乐本身在循环点前后当然不一样，所以不能比内容；比的是**不连续性**——
    真正的咔哒会让相邻样本差远大于全曲的正常最大值。> 2.5 判为有风险。
    """
    d = np.abs(np.diff(np.asarray(x), axis=1))
    ref = float(np.percentile(d, 99.9)) + 1e-9
    zone = 240
    worst = max(float(d[:, -zone:].max()), float(d[:, :zone].max()))
    return worst / ref


TARGET_LUFS = -18.0          # ffmpeg/loudnorm 口径，与 bgm_manifest.json 现有条目一致
TARGET_TP = -1.5             # dBTP 上限，留出游戏内总线的余量


def render(spec, quality="160k", write=False, verbose=True):
    """spec → 成品波形；两遍定电平：内部近似 → ffmpeg 权威值精修。"""
    t0 = time.time()
    x, arr, song = genres.build_song(spec)
    rep = G.loudness_report(x)
    seam = seam_error(x)
    if not write:
        if verbose:
            print("%-8s %-18s %5.1fs peak=%6.2f lufs=%6.2f mono_drop=%+5.2f seam=%.2f "
                  "%.1fs" % (spec["map"], spec["genre"], arr.total_seconds, rep["peak"],
                             rep["lufs"], rep["mono_drop"], seam, time.time() - t0))
        if seam > 2.5:
            print("  !! 接缝跳步风险 ratio=%.2f（>2.5 需处理）" % seam)
        return None

    wav = _wav_path_for(spec, tempfile.gettempdir())
    S.write_wav(wav, x)
    first = measure.loudnorm(wav)
    err = TARGET_LUFS - first["i"]
    if abs(err) > 0.15 or first["tp"] > TARGET_TP:
        # 电平精修：先按差值静态增益，再让限制器把抬起来的峰值压回 ceiling
        x = x * (10.0 ** (err / 20.0))
        x = S.limiter(x, spec.get("ceiling", -1.6), release_ms=90.0)
        S.write_wav(wav, x)
    pre = measure.loudnorm(wav)

    ogg = os.path.join(BGM_DIR, "%s.ogg" % spec["id"])
    os.makedirs(BGM_DIR, exist_ok=True)
    G.encode_ogg(wav, ogg, bitrate=quality)
    os.unlink(wav)
    final = decode_stats(ogg)
    ogg_seam, _ = ogg_seam_ratio(ogg)
    if ogg_seam > 2.5:
        print("  !! %s 解码后接缝跳步 ratio=%.2f（编码侧问题）" % (spec["id"], ogg_seam))
    after = measure.loudnorm(ogg)
    if verbose:
        print("%-8s %-18s %5.1fs  I=%6.2f TP=%6.2f  (pre %6.2f / %+5.2f dB)  %.1fs"
              % (spec["map"], spec["genre"], final["loopSeconds"], after["i"],
                 after["tp"], pre["i"], pre["i"] - first["i"], time.time() - t0))
    entry = {
        "id": spec["id"],
        "name": spec["name"],
        "cn": spec["cn"],
        "genre": LIB.GENRE_DISPLAY[spec["genre"]],
        "bpm": int(spec["bpm"]),
        "map": spec["map"],
        "color": spec["color"],
        "file": "bgm/%s.ogg" % spec["id"],
        "loopSeconds": final["loopSeconds"],
        "samples": final["samples"],
        "peak": final["peak"],
        "rms": final["rms"],
        "sourceLufs": round(first["i"], 2),
        "lufs": round(after["i"], 2),
        "gainDb": round(after["i"] - first["i"], 2),
        "bytes": os.path.getsize(ogg),
    }
    return entry


def update_manifest(entries, out):
    by_id = {e.get("id"): i for i, e in enumerate(entries)}
    for e in out:
        if e["id"] in by_id:
            entries[by_id[e["id"]]] = e
        else:
            entries.append(e)
    with open(MANIFEST, "w", encoding="utf-8") as f:
        json.dump(entries, f, ensure_ascii=False, indent=2)
        f.write("\n")
    return len(entries)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--maps", default="", help="逗号分隔的赛道 id，空=全部")
    ap.add_argument("--genre", default="", help="只出某个曲风（调试用）")
    ap.add_argument("--quality", default="160k")
    ap.add_argument("--write", action="store_true", help="写入仓库 ogg + manifest")
    ap.add_argument("--list", action="store_true")
    args = ap.parse_args()

    specs = LIB.TRACKS
    if args.genre:
        specs = [t for t in specs if t["genre"] == args.genre]
    if args.maps:
        want = [m.strip() for m in args.maps.split(",") if m.strip()]
        specs = [t for t in specs if t["map"] in want]

    if args.list:
        for t in specs:
            print("%-8s %-18s %4d  %-20s %s / %s" % (t["map"], t["genre"], t["bpm"],
                                                     t["name"], t["cn"], t["note"]))
        return

    with open(MANIFEST, encoding="utf-8") as f:
        existing = json.load(f)
    done = []
    for spec in specs:
        if not os.path.isdir(BGM_DIR):
            os.makedirs(BGM_DIR, exist_ok=True)
        e = render(spec, quality=args.quality, write=args.write)
        if e:
            done.append(e)
    if args.write and done:
        n = update_manifest(existing, done)
        print("manifest entries=%d (+%d new) -> %s" % (n, len(done), MANIFEST))
        print("下一步：Godot --headless --import --path . 生成 .ogg.import")


if __name__ == "__main__":
    main()
