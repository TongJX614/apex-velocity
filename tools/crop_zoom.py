import sys
from PIL import Image

src = sys.argv[1]
dst = sys.argv[2]
box = tuple(int(v) for v in sys.argv[3:7])   # l t r b
scale = float(sys.argv[7]) if len(sys.argv) > 7 else 1.0
im = Image.open(src)
w, h = im.size
l, t, r, b = box
l = max(0, min(l, w - 1)); r = max(l + 1, min(r, w))
t = max(0, min(t, h - 1)); b = max(t + 1, min(b, h))
crop = im.crop((l, t, r, b)).convert("RGB")
if scale != 1.0:
    crop = crop.resize((int(crop.width * scale), int(crop.height * scale)), Image.LANCZOS)
crop.save(dst)
print("%s %dx%d -> %s %dx%d" % (src, w, h, dst, crop.width, crop.height))
