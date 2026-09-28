"""Generates Resources/AppIcon.iconset from the Roberts Macros logo.

The RM monogram is cut from Resources/RobertsMacros.png (the tagline is left
out: it is unreadable at Dock sizes), recoloured in the logo's own blue and
placed on a white rounded-square tile on Apple's 1024-point icon grid.
The build turns the iconset into AppIcon.icns with iconutil on the Mac.
Needs Pillow; only rerun when the logo changes: python3 script/make_icon.py
"""
from pathlib import Path
from PIL import Image, ImageChops, ImageDraw, ImageFilter

root = Path(__file__).resolve().parent.parent
logo = Image.open(root / 'Resources/RobertsMacros.png').convert('RGBA')
iconset = root / 'Resources/AppIcon.iconset'
iconset.mkdir(exist_ok=True)

# The monogram occupies rows 11-222; the tagline starts at row 251.
mark_alpha = logo.split()[3].crop((0, 0, logo.width, 235))
mark_alpha = mark_alpha.crop(mark_alpha.getbbox())
# The logo's own blue, measured from its most common opaque pixels.
brand = (63, 91, 116)

scale = 4  # draw large, then reduce, for smooth edges
canvas = 1024 * scale
body, inset, radius = 824 * scale, 100 * scale, 185 * scale

icon = Image.new('RGBA', (canvas, canvas), (0, 0, 0, 0))
# Soft drop shadow under the tile, as in Apple's icon template.
shadow = Image.new('L', (canvas, canvas), 0)
ImageDraw.Draw(shadow).rounded_rectangle((inset, inset + 12 * scale, inset + body, inset + body + 12 * scale), radius, fill=80)
shadow = shadow.filter(ImageFilter.GaussianBlur(14 * scale))
icon.paste((0, 0, 0, 255), (0, 0), shadow)

tile = Image.new('L', (canvas, canvas), 0)
ImageDraw.Draw(tile).rounded_rectangle((inset, inset, inset + body, inset + body), radius, fill=255)
# White tile with a very light neutral shade towards the bottom.
top, bottom = (255, 255, 255), (238, 240, 243)
gradient = Image.linear_gradient('L').resize((canvas, canvas))
face = Image.composite(Image.new('RGBA', (canvas, canvas), bottom + (255,)), Image.new('RGBA', (canvas, canvas), top + (255,)), gradient)
icon.paste(face, (0, 0), tile)
# Hairline edge so the tile holds its shape on light Dock backgrounds.
edge = ImageChops.subtract(tile, tile.filter(ImageFilter.MinFilter(2 * scale + 1)))
icon.paste((0, 0, 0, 255), (0, 0), edge.point(lambda v: v * 30 // 255))

width = int(body * 0.74)
height = round(mark_alpha.height * width / mark_alpha.width)
mark = mark_alpha.resize((width, height), Image.LANCZOS)
x = (canvas - width) // 2
y = (canvas - height) // 2
icon.paste(brand + (255,), (x, y), mark)

master = icon.resize((1024, 1024), Image.LANCZOS)
for points in [16, 32, 128, 256, 512]:
    for factor in [1, 2]:
        pixels = points * factor
        name = f'icon_{points}x{points}' + ('@2x' if factor == 2 else '') + '.png'
        master.resize((pixels, pixels), Image.LANCZOS).save(iconset / name, optimize=True)
print('Wrote', iconset)
