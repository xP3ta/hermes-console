#!/usr/bin/env python3
"""Build the Play listing images from the reviewed screenshots (no new capture).

  aurora_store_assets.py feature-graphic
      docs/store/feature-graphic.png (1024x500): the README banner look, the
      real mark (assets/branding/console_mark.png) and the Inter wordmark.
  aurora_store_assets.py phone
      docs/store/play/phone/*.png: the phone screenshots padded to 9:16
      (1350x2400) with the page colour, never stretched or cropped.
  aurora_store_assets.py contact SHEET.png
      a contact sheet of docs/screenshots/1.2.15 + docs/store/play.

Needs Pillow only. Run from the repository root.
"""
import pathlib
import sys

from PIL import Image, ImageDraw, ImageFilter, ImageFont

ROOT = pathlib.Path(__file__).resolve().parents[2]
SHOTS = ROOT / 'docs/screenshots/1.2.15'
PAGE = (37, 37, 41)  # the banner / dark page colour
PLAY_PHONE = ['home', 'chat-live', 'voice', 'bots', 'tasks-board', 'models', 'terminal', 'chat']


def inter(size, weight):
    font = ImageFont.truetype(str(ROOT / 'assets/fonts/Inter.ttf'), size)
    try:
        font.set_variation_by_axes([weight])
    except Exception:
        pass
    return font


def feature_graphic():
    w, h = 1024, 500
    img = Image.new('RGB', (w, h), PAGE)
    glow = Image.new('RGB', (w, h), PAGE)
    d = ImageDraw.Draw(glow)
    d.ellipse((60, 60, 520, 440), fill=(92, 52, 40))
    glow = glow.filter(ImageFilter.GaussianBlur(90))
    img = Image.blend(img, glow, 0.55)
    mark = Image.open(ROOT / 'assets/branding/console_mark.png').convert('RGBA')
    bbox = mark.getbbox()
    mark = mark.crop(bbox)
    scale = 200 / mark.height
    mark = mark.resize((round(mark.width * scale), 200), Image.LANCZOS)
    word_font = inter(112, 600)
    tag_font = inter(32, 400)
    text = 'Console'
    tw = d.textlength(text, font=word_font)
    gap = 44
    total = mark.width + gap + tw
    x0 = (w - total) / 2
    y_mark = (h - mark.height) / 2 - 6
    img.paste(mark, (round(x0), round(y_mark)), mark)
    draw = ImageDraw.Draw(img)
    tx = x0 + mark.width + gap
    draw.text((tx, y_mark - 4), text, font=word_font, fill=(244, 243, 238))
    draw.text((tx + 4, y_mark + 138), 'native app for Hermes', font=tag_font, fill=(150, 150, 158))
    out = ROOT / 'docs/store/feature-graphic.png'
    out.parent.mkdir(parents=True, exist_ok=True)
    img.save(out)
    print(out, img.size)


def phone():
    out_dir = ROOT / 'docs/store/play/phone'
    out_dir.mkdir(parents=True, exist_ok=True)
    for name in PLAY_PHONE:
        shot = Image.open(SHOTS / f'{name}.png').convert('RGB')
        # Page colour of this screen: the left edge at mid height.
        bg = shot.getpixel((2, shot.height // 2))
        canvas = Image.new('RGB', (1350, 2400), bg)
        canvas.paste(shot, ((1350 - shot.width) // 2, 0))
        canvas.save(out_dir / f'{name}.png')
        print(out_dir / f'{name}.png', canvas.size)


def contact(sheet):
    files = sorted(SHOTS.glob('*.png'))
    cols, cell_w = 7, 240
    cell_h = 540
    rows = (len(files) + cols - 1) // cols
    img = Image.new('RGB', (cols * (cell_w + 12) + 12, rows * (cell_h + 36) + 12), (20, 20, 22))
    d = ImageDraw.Draw(img)
    font = inter(16, 400)
    for i, f in enumerate(files):
        im = Image.open(f).convert('RGB')
        im.thumbnail((cell_w, cell_h))
        x = 12 + (i % cols) * (cell_w + 12)
        y = 12 + (i // cols) * (cell_h + 36)
        img.paste(im, (x, y))
        d.text((x, y + im.height + 6), f.stem, font=font, fill=(200, 200, 205))
    pathlib.Path(sheet).parent.mkdir(parents=True, exist_ok=True)
    img.save(sheet)
    print(sheet, img.size)


if __name__ == '__main__':
    cmd = sys.argv[1] if len(sys.argv) > 1 else ''
    if cmd == 'feature-graphic':
        feature_graphic()
    elif cmd == 'phone':
        phone()
    elif cmd == 'contact':
        contact(sys.argv[2])
    else:
        raise SystemExit(__doc__)
