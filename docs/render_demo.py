#!/usr/bin/env python3
"""Render docs/demo.gif — a three-beat walkthrough of a Pluckr query.

Drawn at 2× then downsampled to 1440×810 so type stays sharp on a retina README.
"""

from __future__ import annotations

from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter, ImageFont

ROOT = Path(__file__).resolve().parent
OUT_GIF = ROOT / "demo.gif"

# Logical layout is 960×540. Draw at 2×, export at 1.5× (1440×810).
LW, LH = 960, 540
DRAW = 2
OUT = 1.5
W, H = int(LW * DRAW), int(LH * DRAW)
OUT_SIZE = (int(LW * OUT), int(LH * OUT))
FPS = 20

BG = (11, 15, 20)
CARD = (22, 27, 34)
CARD_INNER = (15, 19, 25)
BORDER = (52, 59, 68)
HAIR = (36, 42, 50)
TEXT = (233, 238, 244)
MUTED = (148, 157, 168)
DIM = (90, 99, 111)
ACCENT = (57, 196, 138)
AMBER = (224, 176, 90)
RUBY_KW = (255, 128, 118)
RUBY_NAME = (210, 168, 255)
RUBY_SYM = (121, 192, 255)
SQL_KW = (121, 192, 255)
SQL_FN = (210, 168, 255)
STR = (163, 217, 140)
NUM = (224, 176, 90)

RUBY_KEYWORDS = {
    "class", "source", "schema", "do", "end", "field", "one", "exists", "count"
}
SQL_KEYWORDS = {
    "SELECT", "FROM", "LEFT", "OUTER", "JOIN", "ON", "AS", "WHERE", "AND",
    "EXISTS", "LIMIT", "OFFSET",
}
SQL_FUNCS = {"COUNT"}

CODE = """class UserSummary < Pluckr::Query
  source User

  schema do
    field :id
    field :email
    one :subscription do
      field :name
    end
    exists :photos
    count :videos
  end
end

user = UserSummary.find(1)"""

SQL = '''SELECT users.id,
       users.email,
       sub.name              AS "subscription.name",
       EXISTS (
         SELECT 1 FROM photos
          WHERE photos.user_id = users.id
          LIMIT 1 OFFSET 0
       )                     AS photos_exists,
       (SELECT COUNT(*) FROM videos
         WHERE videos.user_id = users.id) AS videos_count
  FROM users
  LEFT OUTER JOIN subscriptions sub
    ON sub.user_id = users.id'''

RESULT = """{
  id: 1,
  email: "user@example.com",
  subscription: { name: "Pro" },
  photos_exists: true,
  videos_count: 2
}"""

STEPS = [
    ("1", "Query", "You declare the shape"),
    ("2", "SQL", "Pluckr compiles one statement"),
    ("3", "Result", "A frozen object, no ActiveRecord"),
]


def px(v: float) -> int:
    return int(round(v * DRAW))


def font(path: str, size: float, index: int = 0) -> ImageFont.FreeTypeFont:
    return ImageFont.truetype(path, px(size), index=index)


FONT_UI = font("/System/Library/Fonts/SFNS.ttf", 15)
FONT_UI_SM = font("/System/Library/Fonts/SFNS.ttf", 13.5)
FONT_TITLE = font("/System/Library/Fonts/SFNS.ttf", 20)
FONT_CODE = font("/System/Library/Fonts/SFNSMono.ttf", 15.5)
FONT_BADGE = font("/System/Library/Fonts/SFNS.ttf", 12.5)


def mix(c1, c2, t):
    t = max(0.0, min(1.0, t))
    return tuple(int(a + (b - a) * t) for a, b in zip(c1, c2))


def box(x0, y0, x1, y1):
    return (px(x0), px(y0), px(x1), px(y1))


def rounded(draw, coords, radius, fill, outline=None, width=1.0):
    draw.rounded_rectangle(
        box(*coords) if len(coords) == 4 and not isinstance(coords[0], tuple) else coords,
        radius=px(radius),
        fill=fill,
        outline=outline,
        width=max(1, px(width)),
    )


def tokenize_ruby(line: str):
    tokens, i, n = [], 0, len(line)
    while i < n:
        ch = line[i]
        if ch in " \t":
            j = i
            while j < n and line[j] in " \t":
                j += 1
            tokens.append((line[i:j], None))
            i = j
        elif ch == "#":
            tokens.append((line[i:], MUTED))
            break
        elif ch == ":":
            j = i + 1
            while j < n and (line[j].isalnum() or line[j] == "_"):
                j += 1
            tokens.append((line[i:j], RUBY_SYM))
            i = j
        elif ch in "\"'":
            j = i + 1
            while j < n and line[j] != ch:
                j += 1
            j = min(n, j + 1)
            tokens.append((line[i:j], STR))
            i = j
        elif ch.isalnum() or ch == "_":
            j = i
            while j < n and (line[j].isalnum() or line[j] in "_:"):
                j += 1
            word = line[i:j]
            if word in RUBY_KEYWORDS:
                color = RUBY_KW
            elif word in {"UserSummary", "Pluckr", "Query", "User"}:
                color = RUBY_NAME
            elif word in {"true", "false", "nil"}:
                color = AMBER
            else:
                color = TEXT
            tokens.append((word, color))
            i = j
        else:
            tokens.append((ch, DIM))
            i += 1
    return tokens


def tokenize_sql(line: str):
    tokens, i, n = [], 0, len(line)
    while i < n:
        ch = line[i]
        if ch in " \t":
            j = i
            while j < n and line[j] in " \t":
                j += 1
            tokens.append((line[i:j], None))
            i = j
        elif ch == '"':
            j = i + 1
            while j < n and line[j] != '"':
                j += 1
            j = min(n, j + 1)
            tokens.append((line[i:j], STR))
            i = j
        elif ch.isalnum() or ch == "_":
            j = i
            while j < n and (line[j].isalnum() or line[j] in "_.*"):
                j += 1
            word = line[i:j]
            upper = word.upper()
            if upper in SQL_KEYWORDS:
                color = SQL_KW
            elif upper in SQL_FUNCS:
                color = SQL_FN
            else:
                color = TEXT
            tokens.append((word, color))
            i = j
        else:
            tokens.append((ch, DIM))
            i += 1
    return tokens


def tokenize_result(line: str):
    tokens, i, n = [], 0, len(line)
    while i < n:
        ch = line[i]
        if ch in " \t":
            j = i
            while j < n and line[j] in " \t":
                j += 1
            tokens.append((line[i:j], None))
            i = j
        elif ch == '"':
            j = i + 1
            while j < n and line[j] != '"':
                j += 1
            j = min(n, j + 1)
            tokens.append((line[i:j], STR))
            i = j
        elif ch.isdigit():
            j = i
            while j < n and (line[j].isdigit() or line[j] == "."):
                j += 1
            tokens.append((line[i:j], NUM))
            i = j
        elif ch.isalpha() or ch == "_":
            j = i
            while j < n and (line[j].isalnum() or line[j] == "_"):
                j += 1
            word = line[i:j]
            nxt = line[j] if j < n else ""
            if word in {"true", "false", "nil"}:
                color = AMBER
            elif nxt == ":":
                color = RUBY_SYM
            else:
                color = TEXT
            tokens.append((word, color))
            i = j
        else:
            tokens.append((ch, DIM))
            i += 1
    return tokens


def draw_tokens(draw, x, y, tokens, font_, alpha=255):
    x, y = px(x), px(y)
    for text, color in tokens:
        fill = TEXT if color is None else color
        if alpha < 255:
            fill = mix(CARD_INNER, fill, alpha / 255)
        draw.text((x, y), text, font=font_, fill=fill)
        x += draw.textlength(text, font=font_)
    return x / DRAW


def shadow_window(base: Image.Image):
    """Soft drop shadow so the window lifts off the page."""
    mask = Image.new("L", (W, H), 0)
    mdraw = ImageDraw.Draw(mask)
    mdraw.rounded_rectangle(box(32, 28, LW - 28, LH - 20), radius=px(16), fill=140)
    mask = mask.filter(ImageFilter.GaussianBlur(radius=px(7)))
    shade = Image.new("RGB", (W, H), (0, 0, 0))
    return Image.composite(shade, base, mask)


def draw_chrome(draw: ImageDraw.ImageDraw, active: int, caption: str, badge: str | None = None):
    rounded(draw, (28, 22, LW - 28, LH - 22), 16, CARD, BORDER, 1.25)

    # Accent bar under the title, marks the active step.
    draw.text((52, 38), "Pluckr", font=FONT_TITLE, fill=TEXT)
    draw.text((140, 43), "one statement   ·   frozen result", font=FONT_UI_SM, fill=MUTED)

    x, y = 52, 78
    for i, (num, label, _) in enumerate(STEPS):
        on = i == active
        pill_w = 100 if i == 1 else 94
        fill = mix(CARD, ACCENT, 0.22) if on else mix(CARD, CARD_INNER, 0.6)
        outline = ACCENT if on else HAIR
        rounded(draw, (x, y, x + pill_w, y + 30), 15, fill, outline, 1.25)
        draw.text((x + 14, y + 6), num, font=FONT_BADGE, fill=ACCENT if on else DIM)
        draw.text((x + 30, y + 5), label, font=FONT_UI_SM, fill=TEXT if on else MUTED)
        x += pill_w + 12
        if i < 2:
            draw.text((px(x - 6), px(y + 5)), "→", font=FONT_UI, fill=DIM)
            x += 10

    draw.text((52, 120), caption, font=FONT_UI, fill=MUTED)

    if badge:
        bw = 124
        bx1 = LW - 52 - bw
        rounded(draw, (bx1, 116, bx1 + bw, 140), 9, mix(CARD, ACCENT, 0.18), ACCENT, 1.25)
        draw.text((bx1 + 12, 120), badge, font=FONT_BADGE, fill=ACCENT)

    rounded(draw, (48, 152, LW - 48, LH - 48), 12, CARD_INNER, HAIR, 1.15)
    # hairline under the editor top, like a tab bar
    draw.line([px(60), px(152), px(LW - 60), px(152)], fill=mix(HAIR, ACCENT, 0.35 if active == 1 else 0), width=px(1.5))


def draw_scene(active: int, visible_lines: int, extra_badge: str | None = None, caret=False):
    img = Image.new("RGB", (W, H), BG)
    img = shadow_window(img)
    draw = ImageDraw.Draw(img)
    _, _, caption = STEPS[active]
    draw_chrome(draw, active, caption, badge=extra_badge)

    body = (CODE, SQL, RESULT)[active]
    tokenizer = (tokenize_ruby, tokenize_sql, tokenize_result)[active]
    lines = body.split("\n")
    shown = lines[:visible_lines]

    x0, y0 = 94, 172
    gutter = 64
    lh = 22.5
    for i, line in enumerate(shown):
        yy = y0 + i * lh
        draw.text((px(gutter), px(yy)), f"{i + 1}", font=FONT_BADGE, fill=mix(CARD_INNER, DIM, 0.7))
        end_x = draw_tokens(draw, x0, yy, tokenizer(line), FONT_CODE)
        if caret and i == visible_lines - 1:
            cx, cy = px(end_x + 1), px(yy + 2)
            draw.rectangle((cx, cy, cx + px(2), cy + px(16)), fill=ACCENT)

    if active == 2 and visible_lines >= len(lines):
        draw.text(
            (px(86), px(LH - 78)),
            "user.email     user.subscription.name     user.videos_count",
            font=FONT_UI_SM,
            fill=DIM,
        )

    return img


def downsample(im: Image.Image) -> Image.Image:
    return im.resize(OUT_SIZE, Image.Resampling.LANCZOS)


def hold(frames, durations, img, seconds):
    frames.append(img)
    durations.append(max(1, int(seconds * 1000)))


def fade(frames, durations, a: Image.Image, b: Image.Image, seconds=0.28):
    n = max(3, int(seconds * FPS))
    step = int(seconds * 1000 / n)
    for i in range(1, n + 1):
        t = i / n
        t = t * t * (3 - 2 * t)
        frames.append(Image.blend(a, b, t))
        durations.append(step)


def reveal(frames, durations, active: int, text: str, extra_badge=None, hold_end=1.7):
    lines = text.split("\n")
    prev = None
    for n in range(1, len(lines) + 1):
        img = draw_scene(active, n, extra_badge=extra_badge, caret=n < len(lines))
        frames.append(img)
        durations.append(70 if n < len(lines) else 120)
        prev = img
    # settle without caret
    prev = draw_scene(active, len(lines), extra_badge=extra_badge, caret=False)
    hold(frames, durations, prev, hold_end)
    return prev


def encode(frames, durations):
    small = [downsample(im) for im in frames]
    palette_src = small[len(small) // 2].quantize(colors=256, method=Image.Quantize.MEDIANCUT)
    converted = [im.quantize(palette=palette_src, dither=Image.Dither.NONE) for im in small]
    converted[0].save(
        OUT_GIF,
        save_all=True,
        append_images=converted[1:],
        duration=durations,
        loop=0,
        optimize=False,
        disposal=2,
    )


def main():
    frames: list[Image.Image] = []
    durations: list[int] = []

    last = reveal(frames, durations, 0, CODE, hold_end=1.65)

    empty2 = draw_scene(1, 0, extra_badge="1 statement")
    fade(frames, durations, last, empty2, 0.30)
    last = reveal(frames, durations, 1, SQL, extra_badge="1 statement", hold_end=2.05)

    empty3 = draw_scene(2, 0)
    fade(frames, durations, last, empty3, 0.30)
    last = reveal(frames, durations, 2, RESULT, hold_end=2.15)

    empty1 = draw_scene(0, 0)
    fade(frames, durations, last, empty1, 0.34)

    encode(frames, durations)
    gifsicle = Path("/opt/homebrew/bin/gifsicle")
    if gifsicle.exists():
        import subprocess

        subprocess.check_call(
            [str(gifsicle), "-O3", "--no-warnings", str(OUT_GIF), "-o", str(OUT_GIF)]
        )

    # Full-res PNG of the three beats, no GIF palette, for visual QA.
    qa = Path("/tmp/pluckr-demo-qa")
    qa.mkdir(exist_ok=True)
    downsample(draw_scene(0, len(CODE.split("\n")))).save(qa / "1-query.png")
    downsample(draw_scene(1, len(SQL.split("\n")), extra_badge="1 statement")).save(qa / "2-sql.png")
    downsample(draw_scene(2, len(RESULT.split("\n")))).save(qa / "3-result.png")

    size_kb = OUT_GIF.stat().st_size / 1024
    print(f"wrote {OUT_GIF}  {len(frames)} frames  {OUT_SIZE[0]}×{OUT_SIZE[1]}  {size_kb:.0f} KB")


if __name__ == "__main__":
    main()
