#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""analog_bridge.py —— 把「按键深度 / 模拟量」通过本机 UDP 送进游戏。

游戏端（scripts/core/analog_input.gd）默认监听 127.0.0.1:48255，
收到后按 Settings 里的死区/曲线映射成转向角与油门开度；超时 380ms 没包就回退普通键盘。

三种用法：
  1) 仅验证游戏链路（不需要任何硬件）：
       python3 tools/analog_input/analog_bridge.py --test
     发送正弦转向 + 锯齿油门，进游戏开一段即可看到方向/油门连续变化。
  2) 任何外部程序/脚本把深度写到标准输入（每行 "steer,throttle" 或 "s=..;t=.."）：
       python3 tools/analog_input/analog_bridge.py --stdin
     或者用 --command 每秒调用一次外部命令、读取其输出。
  3) 磁轴键盘 HID 直读（可选，需要 pip install hid）：
       pip3 install hid
       python3 tools/analog_input/analog_bridge.py --hid config.json
     配置示例见 tools/analog_input/hid_config.example.json（VID/PID 用
     `system_profiler SPUSBDataType` 查）。不同品牌协议不同，按实际情况改 byte/scale。

注意：macOS 没有系统级「按键深度」API；Wooting 的 Analog SDK 主要面向 Windows，
Razer 模拟轴也依赖 Windows 驱动。多数磁轴键盘在 macOS 下最省事的做法是
用厂商软件把按键映射成**虚拟手柄模拟轴** —— 游戏已支持手柄左摇杆/扳机模拟量，无需本脚本。
"""

import argparse
import json
import math
import socket
import sys
import time

DEFAULT_HOST = "127.0.0.1"
DEFAULT_PORT = 48255


def send_packet(sock, addr, steer, throttle, brake=0.0):
    payload = json.dumps(
        {"steer": round(max(-1.0, min(1.0, steer)), 4),
         "throttle": round(max(0.0, min(1.0, throttle)), 4),
         "brake": round(max(0.0, min(1.0, brake)), 4)},
        separators=(",", ":")).encode("utf-8")
    sock.sendto(payload, addr)


def parse_line(line):
    line = line.strip()
    if not line or line.startswith("#"):
        return None
    if line.startswith("{"):
        try:
            d = json.loads(line)
            return (float(d.get("steer", 0.0)), float(d.get("throttle", 0.0)), float(d.get("brake", 0.0)))
        except Exception:
            return None
    text = line.replace(";", ",")
    if "=" in text:
        vals = {"steer": 0.0, "throttle": 0.0, "brake": 0.0}
        for part in text.split(","):
            if "=" not in part:
                continue
            k, v = part.split("=", 1)
            k = k.strip().lower()
            try:
                fv = float(v)
            except ValueError:
                continue
            if k.startswith("b"):
                vals["brake"] = fv
            elif k.startswith("s"):
                vals["steer"] = fv
            elif k.startswith("t"):
                vals["throttle"] = fv
        return vals["steer"], vals["throttle"], vals["brake"]
    parts = [p for p in text.split(",") if p.strip()]
    try:
        steer = float(parts[0]) if len(parts) > 0 else 0.0
        thr = float(parts[1]) if len(parts) > 1 else 0.0
        brake = float(parts[2]) if len(parts) > 2 else 0.0
        return steer, thr, brake
    except ValueError:
        return None


def mode_test(sock, addr, hz):
    period = 1.0 / max(1.0, hz)
    t0 = time.time()
    print(f"[bridge] test 模式 → {addr[0]}:{addr[1]} @ {hz}Hz；Ctrl+C 结束")
    try:
        while True:
            t = time.time() - t0
            steer = 0.85 * math.sin(t * 1.2)
            throttle = abs(math.sin(t * 0.8))  # 0..1 锯齿/呼吸
            send_packet(sock, addr, steer, throttle)
            time.sleep(period)
    except KeyboardInterrupt:
        print("\n[bridge] 结束")


def mode_stdin(sock, addr, hz):
    period = 1.0 / max(1.0, hz)
    print(f"[bridge] stdin 模式 → {addr[0]}:{addr[1]} @ {hz}Hz；每行 'steer,throttle' 或 's=..;t=..'")
    last = (0.0, 0.0, 0.0)
    try:
        for line in sys.stdin:
            parsed = parse_line(line)
            if parsed:
                last = parsed
            send_packet(sock, addr, *last)
            time.sleep(period)
    except KeyboardInterrupt:
        print("\n[bridge] 结束")
    send_packet(sock, addr, 0.0, 0.0)


def _read_field(report, spec):
    byte = int(spec.get("byte", 0))
    bits = int(spec.get("bits", 8))
    offset = int(spec.get("offset", 0))
    if byte >= len(report):
        return 0
    raw = 0
    for i in range((bits + 7) // 8):
        if byte + i >= len(report):
            break
        raw |= report[byte + i] << (8 * i)
    raw = (raw >> offset) & ((1 << bits) - 1)
    scale = float(spec.get("scale", (1 << bits) - 1)) or 1.0
    value = raw / scale
    if spec.get("signed"):
        value = value * 2.0 - 1.0 if bool(spec.get("unsigned_centered")) else value
    return value


def mode_hid(sock, addr, hz, cfg_path):
    try:
        import hid  # type: ignore
    except ImportError:
        print("[bridge] 缺少 hid 库：pip3 install hid")
        sys.exit(2)
    cfg = json.load(open(cfg_path, encoding="utf-8"))
    vid = int(cfg["vid"])
    pid = int(cfg["pid"])
    report_len = int(cfg.get("report_len", 64))
    report_id = int(cfg.get("report_id", 0))
    fields = cfg.get("fields", {})
    dev = hid.device()
    dev.open(vid, pid)
    dev.set_nonblocking(1)
    print(f"[bridge] HID {vid:04x}:{pid:04x} 已连接 → UDP {addr[0]}:{addr[1]} @ {hz}Hz（Ctrl+C 结束）")
    period = 1.0 / max(1.0, hz)
    try:
        while True:
            data = dev.read(report_len, timeout_ms=max(1, int(period * 1000)))
            if data:
                steer_left = _read_field(data, fields.get("steer_left", {"byte": 0}))
                steer_right = _read_field(data, fields.get("steer_right", {"byte": 0}))
                throttle = _read_field(data, fields.get("throttle", {"byte": 0}))
                brake = _read_field(data, fields.get("brake", {"byte": 0}))
                send_packet(sock, addr, steer_right - steer_left, throttle, brake)
            time.sleep(period)
    except KeyboardInterrupt:
        print("\n[bridge] 结束")
    finally:
        send_packet(sock, addr, 0.0, 0.0)
        dev.close()


def main():
    ap = argparse.ArgumentParser(description="模拟输入桥：按键深度 → 本机 UDP → 游戏")
    ap.add_argument("--host", default=DEFAULT_HOST)
    ap.add_argument("--port", type=int, default=DEFAULT_PORT)
    ap.add_argument("--hz", type=float, default=120.0)
    ap.add_argument("--test", action="store_true", help="正弦/锯齿测试信号")
    ap.add_argument("--stdin", action="store_true", help="从标准输入读 steer,throttle")
    ap.add_argument("--hid", metavar="CONFIG.json", help="磁轴键盘 HID 直读配置")
    args = ap.parse_args()
    addr = (args.host, args.port)
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        if args.hid:
            mode_hid(sock, addr, args.hz, args.hid)
        elif args.stdin:
            mode_stdin(sock, addr, args.hz)
        else:
            mode_test(sock, addr, args.hz)
    finally:
        try:
            send_packet(sock, addr, 0.0, 0.0)
        except Exception:
            pass
        sock.close()


if __name__ == "__main__":
    main()
