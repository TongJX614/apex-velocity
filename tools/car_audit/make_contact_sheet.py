#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""生成车库截图 contact sheet（缩略图网格，便于快速扫 45 台车的玻璃/破面/材质异常）。

用法（带 PIL 的 python）:
  /Users/tong/.dsh/dsh-runtimes/dsh-primary-runtime/dependencies/python/bin/python3 \
    tools/car_audit/make_contact_sheet.py \
      --dir /tmp/car_after --pattern 'garage_*.png' --out /tmp/car_after/contact_garage.png \
      [--cols 5] [--thumb 320]
"""
import argparse
import glob
import os
import re
import sys

try:
    from PIL import Image, ImageDraw, ImageFont
except ImportError:
    sys.exit('需要 PIL：请用带 PIL 的 python3 运行')


def load_font(size):
    for p in ['/System/Library/Fonts/PingFang.ttc',
              '/System/Library/Fonts/Supplemental/Arial.ttf']:
        if os.path.exists(p):
            try:
                return ImageFont.truetype(p, size)
            except OSError:
                pass
    return ImageFont.load_default()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--dir', required=True)
    ap.add_argument('--pattern', default='garage_*.png')
    ap.add_argument('--out', required=True)
    ap.add_argument('--cols', type=int, default=5)
    ap.add_argument('--thumb', type=int, default=320)
    args = ap.parse_args()

    files = sorted(glob.glob(os.path.join(args.dir, args.pattern)))
    if not files:
        sys.exit(f'没有匹配文件: {args.dir}/{args.pattern}')
    font = load_font(max(11, args.thumb // 22))
    label_h = max(18, args.thumb // 16)
    cell_h = args.thumb + label_h
    rows = (len(files) + args.cols - 1) // args.cols
    canvas = Image.new('RGB', (args.cols * args.thumb, rows * cell_h), (14, 16, 20))
    d = ImageDraw.Draw(canvas)
    for idx, path in enumerate(files):
        name = os.path.basename(path)
        cid = re.sub(r'^(garage|menu|race)_', '', os.path.splitext(name)[0])
        img = Image.open(path).convert('RGB')
        h = int(args.thumb * img.height / img.width)
        img = img.resize((args.thumb, h), Image.LANCZOS)
        x = (idx % args.cols) * args.thumb
        y = (idx // args.cols) * cell_h
        canvas.paste(img, (x, y))
        d.rectangle([x, y, x + args.thumb - 1, y + h - 1], outline=(40, 44, 52))
        d.text((x + 4, y + h + 3), cid, font=font, fill=(225, 232, 240))
    canvas.save(args.out)
    print(f'[sheet] {args.out} ({canvas.width}x{canvas.height}, {len(files)} images)')


if __name__ == '__main__':
    main()
