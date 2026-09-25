#!/usr/bin/env python3
"""Render short, illustrative TROP operator sessions as terminal GIFs.

Requires Pillow. The storyboards contain example output, not captured host output.
No real token, password, DSN, or production hostname belongs in this file.
"""

from pathlib import Path
from PIL import Image, ImageDraw, ImageFont


ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "docs" / "media"
FONT_PATHS = (
    "/System/Library/Fonts/Menlo.ttc",
    "/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf",
)
FONT_PATH = next((p for p in FONT_PATHS if Path(p).exists()), None)
if not FONT_PATH:
    raise SystemExit("Install Menlo or DejaVu Sans Mono to render the demos")

FONT = ImageFont.truetype(FONT_PATH, 22)
SMALL = ImageFont.truetype(FONT_PATH, 15)
TITLE = ImageFont.truetype(FONT_PATH, 20)
COLORS = {
    "bg": "#101722", "surface": "#182231", "border": "#354356",
    "text": "#e2e9f1", "muted": "#91a2b8", "prompt": "#68d5c2",
    "command": "#f0f5fb", "success": "#a5db88", "accent": "#86afff",
    "warning": "#f2ca7d",
}
WIDTH, HEIGHT = 1120, 650
LINE_HEIGHT = 31
MAX_LINES = 13

# Each tuple is (style, terminal text). The illustration label is always visible.
STORIES = {
    "install": (
        "01 / INSTALL + SETUP",
        [
            ("prompt", "operator@trop:~/trop-bootstrap $"),
            ("command", "./trop-bootstrap"),
            ("text", "=== TROP Standalone Guided Installer ==="),
            ("muted", "TROP token: [hidden input]"),
            ("text", "Available stable releases for amd64: ..."),
            ("text", "TROP release tag [latest stable]: [Enter]"),
            ("text", "Verified release-assets directory [/opt/trop/releases/<release>]:"),
            ("text", "Choose an option [1]: 1  # verify, configure, install"),
            ("accent", "Installation profile: 3  # Platform + TOC"),
            ("accent", "Setup mode: 1  # Standard"),
            ("accent", "TROP Server hostname: trop.example.com"),
            ("accent", "LAN address for TROP: 192.168.20.10"),
            ("success", "[OK] Signed release verified; setup and deploy complete"),
        ],
    ),
    "upgrade": (
        "02 / UPGRADE",
        [
            ("prompt", "operator@trop:~ $"),
            ("command", "trop health"),
            ("success", "[OK] TROP is healthy"),
            ("prompt", "operator@trop:~ $"),
            ("command", "trop upgrade"),
            ("text", "=== Update TROP Standalone ==="),
            ("text", "Downloading the TROP upgrade launcher..."),
            ("muted", "TROP token: [hidden input]"),
            ("text", "TROP release tag [latest stable]: [Enter]"),
            ("text", "Release assets: /opt/trop/releases/<release>"),
            ("text", "Configuration: import /etc/trop/zarf-config.yaml"),
            ("text", "Continue? [Y/n]: y"),
            ("success", "[OK] Signed update and health gate complete"),
        ],
    ),
    "config-apply": (
        "03 / APPLY CONFIG",
        [
            ("prompt", "operator@trop:~ $"),
            ("command", "sudoedit /etc/trop/zarf-config.yaml"),
            ("muted", "package:"),
            ("muted", "  deploy:"),
            ("muted", "    set:"),
            ("accent", "      ENABLE_GLITCHTIP: \"true\""),
            ("accent", "      SENTRY_ENVIRONMENT: \"example\""),
            ("accent", "      TROP_TOC_SENTRY_DSN: \"<TOC project DSN>\""),
            ("prompt", "operator@trop:~ $"),
            ("command", "trop config apply"),
            ("text", "Applying active release configuration..."),
            ("success", "[OK] Configuration applied"),
            ("command", "trop health"),
            ("success", "[OK] TROP is healthy"),
        ],
    ),
    "restart": (
        "04 / RESTART TROP",
        [
            ("prompt", "operator@trop:~ $"),
            ("command", "trop restart-all"),
            ("text", "Restarting local k3s..."),
            ("text", "Waiting for TROP workloads..."),
            ("success", "[OK] TROP workloads are ready"),
            ("prompt", "operator@trop:~ $"),
            ("command", "trop health"),
            ("success", "[OK] TROP is healthy"),
        ],
    ),
}


def frame(title, lines, cursor=False):
    image = Image.new("RGB", (WIDTH, HEIGHT), COLORS["bg"])
    draw = ImageDraw.Draw(image)
    draw.rounded_rectangle((24, 22, WIDTH - 24, HEIGHT - 22), radius=19,
                           fill=COLORS["surface"], outline=COLORS["border"], width=2)
    draw.rounded_rectangle((24, 22, WIDTH - 24, 88), radius=19,
                           fill="#202d3f")
    draw.rectangle((24, 68, WIDTH - 24, 88), fill="#202d3f")
    for x, color in ((55, "#ff6962"), (78, "#f9c953"), (101, "#5dcf88")):
        draw.ellipse((x - 7, 48, x + 7, 62), fill=color)
    draw.text((143, 43), "trop  /  operator session", font=TITLE, fill=COLORS["text"])
    draw.rounded_rectangle((704, 38, 1063, 73), radius=9, fill="#32445b")
    draw.text((719, 47), "ILLUSTRATIVE SESSION", font=SMALL, fill="#d5e4f4")
    draw.text((61, 112), title, font=TITLE, fill=COLORS["accent"])
    draw.line((61, 150, 1058, 150), fill=COLORS["border"], width=1)
    visible = lines[-MAX_LINES:]
    for i, (style, value) in enumerate(visible):
        draw.text((62, 177 + i * LINE_HEIGHT), value, font=FONT,
                  fill=COLORS.get(style, COLORS["text"]))
    if cursor and visible:
        last = visible[-1][1]
        x = 62 + draw.textlength(last, font=FONT) + 2
        y = 177 + (len(visible) - 1) * LINE_HEIGHT
        draw.rectangle((x, y + 4, x + 11, y + 25), fill=COLORS["prompt"])
    draw.line((61, 596, 1058, 596), fill=COLORS["border"], width=1)
    draw.text((62, 610), "docs / trop-bootstrap", font=SMALL, fill=COLORS["muted"])
    draw.text((866, 610), "EXAMPLE OUTPUT", font=SMALL, fill=COLORS["muted"])
    return image


def render(name, title, lines):
    frames, durations, shown = [], [], []
    for style, value in lines:
        if style == "command":
            for n in (max(1, len(value) // 3), max(2, len(value) * 2 // 3)):
                frames.append(frame(title, shown + [(style, value[:n])], cursor=True))
                durations.append(95)
        shown.append((style, value))
        frames.append(frame(title, shown, cursor=style == "command"))
        durations.append(650 if style in ("command", "success") else 390)
    durations[-1] = 2400
    # GIF palettes remain stable across frames, avoiding color flashes.
    palette = frames[0].quantize(colors=48)
    indexed = [f.quantize(palette=palette) for f in frames]
    target = OUT / f"{name}.gif"
    indexed[0].save(target, save_all=True, append_images=indexed[1:],
                    duration=durations, loop=0, optimize=True, disposal=2)
    print(f"{target.relative_to(ROOT)}: {len(indexed)} frames")


if __name__ == "__main__":
    OUT.mkdir(parents=True, exist_ok=True)
    for story_name, (story_title, story_lines) in STORIES.items():
        render(story_name, story_title, story_lines)
