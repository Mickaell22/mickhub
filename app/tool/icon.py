# Dibuja el ícono de MickHub: una "M" hecha con un grafo de commits.
import sys
from PIL import Image, ImageDraw

S = 1024
out = sys.argv[1]
img = Image.new('RGBA', (S * 4, S * 4), (0, 0, 0, 0))  # 4x para suavizar bordes
d = ImageDraw.Draw(img)
k = 4
d.rounded_rectangle([0, 0, S * k - 1, S * k - 1], radius=220 * k, fill=(36, 41, 46, 255))  # #24292e

pts = [(250, 760), (250, 270), (512, 560), (774, 270), (774, 760)]
pts = [(x * k, y * k) for x, y in pts]
d.line(pts, fill=(46, 143, 255, 255), width=78 * k, joint='curve')  # #2e8fff
r = 62 * k
colors = [(52, 208, 88), (46, 143, 255), (255, 171, 112), (46, 143, 255), (52, 208, 88)]
for (x, y), c in zip(pts, colors):
    d.ellipse([x - r - 22 * k, y - r - 22 * k, x + r + 22 * k, y + r + 22 * k], fill=(36, 41, 46, 255))
    d.ellipse([x - r, y - r, x + r, y + r], fill=c + (255,))
img.resize((S, S), Image.LANCZOS).save(out)
