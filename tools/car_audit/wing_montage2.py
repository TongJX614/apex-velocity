#!/usr/bin/env python3
"""把特写批渲染结果拼成每车一张的 9 宫格（w0 原厂 + w1..w8 供体翼），
供逐车目视验收尾翼连接。v2：适配特写镜头（crop 保留中心偏上区域）。
输出到 /tmp/wing_audit/montage2/<car>.png"""
import os, sys
from PIL import Image, ImageDraw

SRC = '/tmp/wing_audit/batch2'
OUT = '/tmp/wing_audit/montage2'
LABELS = ['stock', 'e46_gtr', 'm4_gts', 'x6m', 'm4_gt4', 'm5_f90', 'adro_g82', 'u7', 'sealion']

def montage(car):
    crops = []
    for w in range(9):
        p = f'{SRC}/{car}_w{w}.png'
        if not os.path.exists(p):
            crops.append((f'w{w}:{LABELS[w]} MISSING', None))
            continue
        im = Image.open(p).convert('RGB')
        wd, h = im.size
        crop = im.crop((int(wd*0.12), int(h*0.06), int(wd*0.92), int(h*0.78)))
        crops.append((f'w{w}:{LABELS[w]}', crop))
    ok = [c for _, c in crops if c is not None]
    if not ok:
        return False
    cw = max(c.width for c in ok); ch = max(c.height for c in ok)
    cols, rows = 3, 3
    canvas = Image.new('RGB', (cw*cols+40, (ch+34)*rows), (40, 40, 44))
    d = ImageDraw.Draw(canvas)
    for i, (nm, c) in enumerate(crops):
        r, col = divmod(i, cols)
        x = col*(cw+30)+10; y = r*(ch+34)+10
        if c is not None:
            canvas.paste(c, (x, y+20))
        d.text((x, y+4), nm, fill=(255, 255, 0) if c is not None else (255, 80, 80))
    canvas = canvas.resize((int(canvas.width*0.62), int(canvas.height*0.62)))
    os.makedirs(OUT, exist_ok=True)
    canvas.save(f'{OUT}/{car}.png')
    return True

def main():
    cars = sys.argv[1:] or [l.strip() for l in open('/tmp/wing_audit/car_list.txt') if l.strip()]
    done = 0
    for car in cars:
        if montage(car):
            done += 1
        else:
            print('skip (no renders):', car)
    print(f'montages: {done}/{len(cars)}')

if __name__ == '__main__':
    main()
