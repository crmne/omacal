#!/usr/bin/env python3
"""Composes preview.png, the marketplace card, from the rendered screenshots.

Run tools/render-screenshots first. Everything on the card is sample data."""
import subprocess
from pathlib import Path
from PIL import Image, ImageDraw, ImageFont, ImageFilter

repo = Path(__file__).resolve().parent.parent
shots = repo / "screenshots"
W, H = 3200, 1800  # 1600x900 at 2x


def font(pattern, size):
    path = subprocess.run(["fc-match", "-f", "%{file}", pattern], capture_output=True, text=True).stdout
    return ImageFont.truetype(path, size)


mono = lambda s: font("JetBrainsMono Nerd Font", s)
bold = font("Inter:bold", 144)

# Warm radial glow from the lower left, like OmaTasks' card.
card = Image.new("RGB", (W, H), "#100c0b")
glow = Image.new("L", (W, H), 0)
ImageDraw.Draw(glow).ellipse((-1300, H - 1300, 1300, H + 1300), fill=255)
glow = glow.filter(ImageFilter.GaussianBlur(420))
card = Image.composite(Image.new("RGB", (W, H), "#4a2a1f"), card, glow)
draw = ImageDraw.Draw(card)

draw.text((160, 170), "OMACAL / CRMNE", font=mono(36), fill="#fcb55b", spacing=8)
draw.multiline_text((152, 300), "Your calendar,\nright in your bar.", font=bold, fill="#eee7e5", spacing=24)
draw.multiline_text((160, 690), "Omarchy's own calendar, with your days in it.\nHEY first, more calendars to come.",
                    font=mono(40), fill="#b4a6a1", spacing=22)
features = [
    "Per-calendar chips on every day",
    "Click a day to see it, HEY style",
    "Your next event in the bar",
    "Quick add with Alt + Shift + Space",
    "Reminders, time tracking, live sync",
]
for i, text in enumerate(features):
    y = 930 + i * 104
    draw.text((160, y), "•", font=mono(44), fill="#fcb55b")
    draw.text((210, y + 4), text, font=mono(38), fill="#d0c4bf")
draw.line((160, 1560, 1860, 1560), fill="#544038", width=2)
draw.text((160, 1600), "OmaCal. Native to Omarchy.", font=mono(34), fill="#947f75")

# The rendered panel, scaled to the card's height, with a soft shadow.
panel = Image.open(shots / "panel.png").convert("RGBA")
scale = 1640 / panel.height
panel = panel.resize((round(panel.width * scale), round(panel.height * scale)), Image.LANCZOS)
px, py = W - panel.width - 170, 80
shadow = Image.new("RGBA", (W, H), (0, 0, 0, 0))
ImageDraw.Draw(shadow).rounded_rectangle((px + 20, py + 40, px + panel.width + 20, py + panel.height + 40), 40, fill=(0, 0, 0, 170))
shadow = shadow.filter(ImageFilter.GaussianBlur(40))
card = Image.alpha_composite(card.convert("RGBA"), shadow)
card.alpha_composite(panel, (px, py))

card.convert("RGB").save(repo / "preview.png", optimize=True)
print("wrote", repo / "preview.png", card.size)
