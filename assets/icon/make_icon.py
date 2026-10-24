"""Draws OuOPlayer's icon from shapes (no AI picture, so no noise) and writes
every file flutter_launcher_icons needs, plus an SVG of the same drawing.

    python -I assets/icon/make_icon.py

Each diamond is a rounded square turned 45 degrees with a linear gradient.
Change the numbers in DIAMONDS and run again; nothing else moves.
"""
import math
import os

from PIL import Image, ImageChops, ImageDraw, ImageFilter

HERE = os.path.dirname(os.path.abspath(__file__))
BG = '#10151C'
CORNER = 0.16      # corner radius, as a share of a diamond's side
SCALE = 0.72       # drawing size inside the adaptive icon (keeps the safe zone)
SS = 4             # supersampling
# Narrower and taller (width, height): the diamonds become tall rhombi.
STRETCH = (0.85, 1.15)
# Shadow under the front diamonds: colour and strength.
SHADOW = ('#000000', 0.45)
N = 1024

# Back to front. tip = centre-to-corner distance (1024 grid); stops run along
# `angle` (degrees, 90 = top to bottom, 135 = top-right to bottom-left).
DIAMONDS = [
    dict(name='back', cx=512, cy=512, tip=282, angle=90, stops=[(0, '#237096'), (1, '#163A58')], front=False),
    dict(name='right_back', cx=683, cy=511, tip=180, angle=90, stops=[(0, '#1C4A64'), (1, '#183F58')], front=False),
    dict(name='middle', cx=510, cy=511, tip=147, angle=90, stops=[(0, '#2C86AE'), (1, '#277AA0')], front=False),
    dict(name='right', cx=785, cy=510, tip=95, angle=90, stops=[(0, '#2E88B2'), (1, '#2A80AA')], front=False),
    dict(name='big', cx=354, cy=511, tip=207, angle=135,
         stops=[(0, '#8AD5F7'), (0.5, '#67C6F4'), (1, '#44778F')], front=True),
    dict(name='small', cx=671, cy=511, tip=98, angle=90,
         stops=[(0, '#78C9EC'), (0.5, '#54BAEA'), (1, '#4693BD')], front=True),
]


# The light icon (設定 → 關於與更新 → App 圖示): pale background, the back
# diamonds a clear step darker than the front ones, a faint blue shadow.
LIGHT = dict(
    bg='#EEF3F8',
    shadow=('#1D5B85', 0.30),
    stops={
        'back': [(0, '#3A86BA'), (1, '#1F5E90')],
        'right_back': [(0, '#2C6E9E'), (1, '#245F8D')],
        'middle': [(0, '#3F96C8'), (1, '#3482B5')],
        'right': [(0, '#4AA3D5'), (1, '#3F94C8')],
        'big': [(0, '#8AD5F7'), (0.5, '#67C6F4'), (1, '#4B95C4')],
        'small': [(0, '#7FCDEF'), (0.5, '#5CC0EE'), (1, '#4FA3D2')],
    },
)

RES = os.path.join(HERE, '..', '..', 'android', 'app', 'src', 'main', 'res')
DENSITIES = {'mdpi': 1, 'hdpi': 1.5, 'xhdpi': 2, 'xxhdpi': 3, 'xxxhdpi': 4}


def use_light():
    global BG, SHADOW
    BG, SHADOW = LIGHT['bg'], LIGHT['shadow']
    for d in DIAMONDS:
        d['stops'] = LIGHT['stops'][d['name']]


def android_light(icon, foreground):
    """The light icon as Android resources beside flutter_launcher_icons' dark
    ones (ic_launcher_light*), used by the .LightIcon activity-alias."""
    for name, k in DENSITIES.items():
        mip = os.path.join(RES, f'mipmap-{name}')
        os.makedirs(mip, exist_ok=True)
        icon.resize((round(48 * k), round(48 * k)), Image.LANCZOS).save(os.path.join(mip, 'ic_launcher_light.png'))
        dr = os.path.join(RES, f'drawable-{name}')
        os.makedirs(dr, exist_ok=True)
        foreground.resize((round(108 * k), round(108 * k)), Image.LANCZOS).save(os.path.join(dr, 'ic_launcher_light_foreground.png'))
    os.makedirs(os.path.join(RES, 'mipmap-anydpi-v26'), exist_ok=True)
    with open(os.path.join(RES, 'mipmap-anydpi-v26', 'ic_launcher_light.xml'), 'w', encoding='utf-8') as f:
        f.write('''<?xml version="1.0" encoding="utf-8"?>
<!-- Made by assets/icon/make_icon.py: the light app icon. -->
<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">
  <background android:drawable="@color/ic_launcher_light_background"/>
  <foreground android:drawable="@drawable/ic_launcher_light_foreground"/>
  <monochrome android:drawable="@drawable/ic_launcher_monochrome"/>
</adaptive-icon>
''')
    with open(os.path.join(RES, 'values', 'ic_launcher_light.xml'), 'w', encoding='utf-8') as f:
        f.write(f'''<?xml version="1.0" encoding="utf-8"?>
<resources>
    <color name="ic_launcher_light_background">{LIGHT['bg']}</color>
</resources>
''')


def preview(foreground):
    """The part launchers show, small, for the choice in the app."""
    c = round(N * (1 - 72 / 108) / 2)
    return foreground.crop((c, c, N - c, N - c)).resize((192, 192), Image.LANCZOS)


def hex_rgb(h):
    return tuple(int(h[i:i + 2], 16) for i in (1, 3, 5))


def side_of(tip):
    # tip distance of a rounded square: s/sqrt2 - r(sqrt2 - 1), with r = CORNER*s
    return tip / (1 / math.sqrt(2) - CORNER * (math.sqrt(2) - 1))


def diamond_mask(d, size):
    """The diamond's shape on a size x size canvas (1024 grid scaled up)."""
    k = size / N
    s = side_of(d['tip']) * k
    box = round(s * 1.5)
    sq = Image.new('L', (box, box), 0)
    o = (box - s) / 2
    ImageDraw.Draw(sq).rounded_rectangle((o, o, o + s, o + s), radius=CORNER * s, fill=255)
    sq = sq.rotate(45, resample=Image.BICUBIC, expand=True)
    m = Image.new('L', (size, size), 0)
    m.paste(sq, (round(d['cx'] * k - sq.width / 2), round(d['cy'] * k - sq.height / 2)))
    return m


def gradient(d, size):
    """The diamond's colours across its own extent, filling a size x size canvas."""
    k = size / N
    reach = d['tip'] * k * 2
    ramp = Image.linear_gradient('L').resize((round(reach), round(reach)))  # black at top → white at bottom
    ramp = ramp.rotate(90 - d['angle'], resample=Image.BICUBIC, expand=True)
    full = Image.new('L', (size, size), 0)
    full.paste(ramp, (round(d['cx'] * k - ramp.width / 2), round(d['cy'] * k - ramp.height / 2)))
    stops = d['stops']
    out = Image.new('RGB', (size, size), hex_rgb(stops[0][1]))
    for (p0, c0), (p1, c1) in zip(stops, stops[1:]):
        lo, hi = round(p0 * 255), round(p1 * 255)
        seg = full.point(lambda v: 0 if v <= lo else 255 if v >= hi else round((v - lo) * 255 / (hi - lo)))
        layer = Image.composite(Image.new('RGB', (size, size), hex_rgb(c1)), Image.new('RGB', (size, size), hex_rgb(c0)), seg)
        out = Image.composite(layer, out, full.point(lambda v: 255 if v >= lo else 0))
    return out


def stretch(img):
    return img.resize((round(img.width * STRETCH[0]), round(img.height * STRETCH[1])), Image.LANCZOS)


def draw(size, scale=1.0, background=True):
    """The icon at size x size; the drawing shrunk to `scale` around the centre."""
    inner = round(size * scale)
    art = Image.new('RGB', (inner, inner), hex_rgb(BG))
    alpha = Image.new('L', (inner, inner), 0)
    for d in DIAMONDS:
        m = diamond_mask(d, inner)
        if d['front']:
            # A soft shadow on what is behind.
            shadow = m.filter(ImageFilter.GaussianBlur(inner * 0.012)).point(lambda v: round(v * SHADOW[1]))
            art = Image.composite(Image.new('RGB', art.size, hex_rgb(SHADOW[0])), art, shadow)
        art = Image.composite(gradient(d, inner), art, m)
        alpha = ImageChops.lighter(alpha, m)
    art, alpha = stretch(art), stretch(alpha)
    canvas = Image.new('RGB', (size, size), hex_rgb(BG))
    canvas.paste(art, ((size - art.width) // 2, (size - art.height) // 2))
    if background:
        return canvas
    full_alpha = Image.new('L', (size, size), 0)
    full_alpha.paste(alpha, ((size - alpha.width) // 2, (size - alpha.height) // 2))
    canvas.putalpha(full_alpha)
    return canvas


def monochrome(size, scale):
    """Themed icon: front diamonds solid, the ones behind at half strength."""
    inner = round(size * scale)
    a = Image.new('L', (inner, inner), 0)
    for d in DIAMONDS:
        m = diamond_mask(d, inner)
        a = Image.composite(Image.new('L', a.size, 255 if d['front'] else 120), a, m)
        if d['front']:
            # A thin gap so the front shapes stay readable on the back ones.
            ring = m.filter(ImageFilter.MaxFilter(9))
            a = Image.composite(Image.new('L', a.size, 0), a, ImageChops.subtract(ring, m))
            a = Image.composite(Image.new('L', a.size, 255), a, m)
    a = stretch(a)
    out = Image.new('RGBA', (size, size), (255, 255, 255, 0))
    white = Image.new('RGBA', a.size, (255, 255, 255, 255))
    out.paste(white, ((size - a.width) // 2, (size - a.height) // 2), a)
    return out


def svg():
    parts = [f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {N} {N}">', '<defs>']
    for d in DIAMONDS:
        a = math.radians(d['angle'])
        dx, dy = math.cos(a) / 2, math.sin(a) / 2
        parts.append(f'<linearGradient id="{d["name"]}" x1="{0.5 - dx:.3f}" y1="{0.5 - dy:.3f}" x2="{0.5 + dx:.3f}" y2="{0.5 + dy:.3f}">')
        parts += [f'<stop offset="{p}" stop-color="{c}"/>' for p, c in d['stops']]
        parts.append('</linearGradient>')
    sx, sy = STRETCH
    parts += ['</defs>', f'<rect width="{N}" height="{N}" fill="{BG}"/>',
              f'<g transform="translate({N / 2} {N / 2}) scale({sx} {sy}) translate({-N / 2} {-N / 2})">']
    for d in DIAMONDS:
        s = side_of(d['tip'])
        parts.append(f'<rect x="{d["cx"] - s / 2:.1f}" y="{d["cy"] - s / 2:.1f}" width="{s:.1f}" height="{s:.1f}" rx="{CORNER * s:.1f}" '
                     f'fill="url(#{d["name"]})" transform="rotate(45 {d["cx"]} {d["cy"]})"/>')
    parts += ['</g>', '</svg>']
    return '\n'.join(parts)


def down(img):
    return img.resize((N, N), Image.LANCZOS)


if __name__ == '__main__':
    full = down(draw(N * SS))
    full.save(os.path.join(HERE, 'artwork.png'))
    fg = down(draw(N * SS, SCALE))
    fg.save(os.path.join(HERE, 'foreground.png'))
    fg.save(os.path.join(HERE, 'icon.png'))
    down(monochrome(N * SS, SCALE)).save(os.path.join(HERE, 'monochrome.png'))
    with open(os.path.join(HERE, 'icon.svg'), 'w', encoding='utf-8') as f:
        f.write(svg())
    preview(fg).save(os.path.join(HERE, 'app_icon_dark.png'))

    use_light()
    down(draw(N * SS)).save(os.path.join(HERE, 'artwork_light.png'))
    light = down(draw(N * SS, SCALE))
    light.save(os.path.join(HERE, 'foreground_light.png'))
    preview(light).save(os.path.join(HERE, 'app_icon_light.png'))
    android_light(light, light)
    print('ok')
