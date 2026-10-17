#!/usr/bin/env python3
"""Composes preview.png, the marketplace card, from the rendered screenshots.

Run tools/render-screenshots first. Like hyprmoncfg's, the card is the
plugin itself rather than words about it: the panel and the quick-add
form, real renders with sample data, over Omarchy's ristretto wallpaper.

The marketplace card shows only a strip from the middle, about 2.7 times as
wide as it is tall, and the websites crop to 16:9. So the windows are shown
large and run off the edges, with the panel's date and month grid in the
middle, where every crop keeps them."""
from pathlib import Path
from PIL import Image, ImageDraw, ImageEnhance, ImageFilter

repo = Path(__file__).resolve().parent.parent
shots = repo / "screenshots"
wallpaper = Path("/usr/share/omarchy/themes/ristretto/backgrounds/1-color-curves.jpg")
W, H = 2560, 1600


def cover(image, width, height):
    scale = max(width / image.width, height / image.height)
    image = image.resize((round(image.width * scale), round(image.height * scale)), Image.LANCZOS)
    left, top = (image.width - width) // 2, (image.height - height) // 2
    return image.crop((left, top, left + width, top + height))


def scaled(path, height):
    image = Image.open(path).convert("RGBA")
    return image.resize((round(image.width * height / image.height), height), Image.LANCZOS)


# The wallpaper, softened and dimmed so the windows read first.
back = cover(Image.open(wallpaper).convert("RGB"), W, H).filter(ImageFilter.GaussianBlur(28))
card = ImageEnhance.Brightness(back).enhance(0.45).convert("RGBA")


def place(image, x, y):
    global card
    shadow = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    ImageDraw.Draw(shadow).rounded_rectangle((x + 16, y + 36, x + image.width + 16, y + image.height + 36), 36, fill=(0, 0, 0, 190))
    card = Image.alpha_composite(card, shadow.filter(ImageFilter.GaussianBlur(36)))
    card.alpha_composite(image, (x, y))


panel = scaled(shots / "panel.png", round(Image.open(shots / "panel.png").height * 1.1))
form = scaled(shots / "quick-add.png", round(Image.open(shots / "quick-add.png").height * 1.1))
place(panel, 150, 300)
place(form, 150 + panel.width - 140, 470)

card.convert("RGB").save(repo / "preview.png", optimize=True)
print("wrote", repo / "preview.png", card.size)
