"""Makes the installer's pictures from assets/icon/icon.png (run again after
the icon changes): the small one at the top right of every page and the
large one on the finish page, at 100% and 200%."""
from pathlib import Path

from PIL import Image

here = Path(__file__).parent
icon = Image.open(here / '../../assets/icon/icon.png').convert('RGBA')
# The round one, as on the taskbar: on the wizard's white page header.
badge = Image.open(here / '../runner/resources/app_icon.ico').convert('RGBA')
dark = (0x10, 0x15, 0x1C)


def picture(w, h, size, name, art=icon, bg=dark):
    out = Image.new('RGB', (w, h), bg)
    i = art.resize((size, size), Image.LANCZOS)
    out.paste(i, ((w - size) // 2, (h - size) // 2), i)
    out.save(here / name)


for scale in (1, 2):
    picture(58 * scale, 58 * scale, 52 * scale, f'small{scale * 100}.bmp', badge, (255, 255, 255))
    picture(164 * scale, 314 * scale, 120 * scale, f'large{scale * 100}.bmp')
