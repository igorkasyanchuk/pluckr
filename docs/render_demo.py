#!/usr/bin/env python3
"""Render docs/demo.gif — a three-beat walkthrough of a Pluckr query.

Drawn at 2× then downsampled to 1440×810 so type stays sharp on a retina README.
"""

from __future__ import annotations

import subprocess
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
       sub.name AS "subscription.name",
       EXISTS (
         SELECT 1 FROM photos
          WHERE photos.user_id = users.id
          LIMIT 1 OFFSET 0
       ) AS photos_exists,
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

# Layout — logical px. Title / pills / caption share CONTENT as the left ink edge.
MARGIN = 32
INSET = 28
WIN = (MARGIN, 28, LW - MARGIN, LH - 22)
CONTENT = MARGIN + INSET  # 60
PILL_H = 32
TITLE_CY = WIN[1] + 28
PILL_Y = TITLE_CY + 24
CAP_CY = PILL_Y + PILL_H + 22
EDITOR = (CONTENT, CAP_CY + 28, LW - CONTENT, WIN[3] - 22)
GUTTER_LEFT = 28
GUTTER_W = 40
CODE_GAP = 20
CODE_PAD_Y = 34
LINE_H = 19


def px(v: float) -> int:
    return int(round(v * DRAW))


def font(path: str, size: float, index: int = 0) -> ImageFont.FreeTypeFont:
    return ImageFont.truetype(path, px(size), index=index)


FONT_UI = font("/System/Library/Fonts/SFNS.ttf", 15)
FONT_UI_SM = font("/System/Library/Fonts/SFNS.ttf", 13)
FONT_TITLE = font("/System/Library/Fonts/SFNS.ttf", 20)
FONT_CODE = font("/System/Library/Fonts/SFNSMono.ttf", 15)
FONT_BADGE = font("/System/Library/Fonts/SFNS.ttf", 12)


def mix(c1, c2, t):
    t = max(0.0, min(1.0, t))
    return tuple(int(a + (b - a) * t) for a, b in zip(c1, c2))


def box(x0, y0, x1, y1):
    return (px(x0), px(y0), px(x1), px(y1))


def rounded(draw, coords, radius, fill, outline=None, width=1.0):
    draw.rounded_rectangle(
        box(*coords),
        radius=px(radius),
        fill=fill,
        outline=outline,
        width=max(1, px(width)),
    )


_RASTER_INK = {}


def raster_ink(s, font_, thresh=48):
    """Painted-pixel bbox relative to a top-left draw at (0, 0).

    Pillow's textbbox follows the em-box; SFNS ink sits off-center inside it.
    """
    key = (s, id(font_), thresh)
    hit = _RASTER_INK.get(key)
    if hit is not None:
        return hit
    pad = 80
    im = Image.new("L", (pad * 2 + 1000, pad * 2 + 160), 0)
    ImageDraw.Draw(im).text((pad, pad), s, font=font_, fill=255)
    mask = im.point(lambda p: 255 if p >= thresh else 0)
    bb = mask.getbbox()
    if bb is None:
        hit = (0, 0, 0, 0)
    else:
        hit = (bb[0] - pad, bb[1] - pad, bb[2] - pad, bb[3] - pad)
    _RASTER_INK[key] = hit
    return hit


def t_ink_center(draw, cx, cy, s, font_, fill):
    """Place s so its painted ink is centered on logical (cx, cy)."""
    l, t0, r, b = raster_ink(s, font_)
    draw.text((px(cx) - (l + r) / 2, px(cy) - (t0 + b) / 2), s, font=font_, fill=fill)


def t_ink_left_mid(draw, x, cy, s, font_, fill):
    """Leftmost painted ink at x, vertical ink center at cy."""
    l, t0, r, b = raster_ink(s, font_)
    draw.text((px(x) - l, px(cy) - (t0 + b) / 2), s, font=font_, fill=fill)


def t_ink_left_base(draw, x, baseline, s, font_, fill):
    """Leftmost painted ink at x, alphabetic baseline at baseline."""
    l, _, _, _ = draw.textbbox((0, 0), s, font=font_, anchor="ls")
    draw.text((px(x) - l, px(baseline)), s, font=font_, fill=fill, anchor="ls")


def t_ink_right_base(draw, x, baseline, s, font_, fill):
    """Rightmost painted ink at x, alphabetic baseline at baseline."""
    _, _, r, _ = draw.textbbox((0, 0), s, font=font_, anchor="ls")
    draw.text((px(x) - r, px(baseline)), s, font=font_, fill=fill, anchor="ls")


def ink_w(_draw, s, font_) -> float:
    l, _, r, _ = raster_ink(s, font_)
    return (r - l) / DRAW


def cap_h(_draw, font_) -> float:
    _, t0, _, b = raster_ink("H", font_)
    return (b - t0) / DRAW


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


def draw_tokens(draw, x, y, tokens, font_):
    """Draw a tokenized line. (x, y) is logical left + alphabetic baseline."""
    cursor = px(x)
    by = px(y)
    for text, color in tokens:
        fill = TEXT if color is None else color
        draw.text((cursor, by), text, font=font_, fill=fill, anchor="ls")
        cursor += draw.textlength(text, font=font_)
    return cursor / DRAW


def shadow_window(base: Image.Image):
    mask = Image.new("L", (W, H), 0)
    mdraw = ImageDraw.Draw(mask)
    mdraw.rounded_rectangle(
        box(WIN[0] + 2, WIN[1] + 6, WIN[2] + 6, WIN[3] + 10),
        radius=px(16),
        fill=120,
    )
    mask = mask.filter(ImageFilter.GaussianBlur(radius=px(8)))
    shade = Image.new("RGB", (W, H), (0, 0, 0))
    return Image.composite(shade, base, mask)


def draw_chrome(draw: ImageDraw.ImageDraw, active: int, caption: str, badge: str | None = None):
    rounded(draw, WIN, 16, CARD, BORDER, 1.2)

    # Title + tagline share an ink vertical center so mixed sizes sit on one line.
    t_ink_left_mid(draw, CONTENT, TITLE_CY, "Pluckr", FONT_TITLE, TEXT)
    t_ink_left_mid(
        draw,
        CONTENT + ink_w(draw, "Pluckr", FONT_TITLE) + 16,
        TITLE_CY,
        "one statement  ·  frozen result",
        FONT_UI_SM,
        MUTED,
    )

    pill_cy = PILL_Y + PILL_H / 2
    x = CONTENT
    for i, (num, label, _) in enumerate(STEPS):
        on = i == active
        label_s = f"{num}  {label}"
        pill_w = ink_w(draw, label_s, FONT_UI_SM) + 40
        fill = mix(CARD, ACCENT, 0.20) if on else CARD_INNER
        outline = ACCENT if on else HAIR
        rounded(draw, (x, PILL_Y, x + pill_w, PILL_Y + PILL_H), 16, fill, outline, 1.15)
        t_ink_center(draw, x + pill_w / 2, pill_cy, label_s, FONT_UI_SM, TEXT if on else MUTED)
        x += pill_w + 12
        if i < 2:
            t_ink_center(draw, x + 8, pill_cy, "→", FONT_UI_SM, DIM)
            x += 16 + 12

    t_ink_left_mid(draw, CONTENT, CAP_CY, caption, FONT_UI, MUTED)
    if badge:
        bw = ink_w(draw, badge, FONT_BADGE)
        pad_x = 12
        badge_w = bw + pad_x * 2
        badge_h = 26
        bx1 = EDITOR[2] - badge_w
        rounded(
            draw,
            (bx1, CAP_CY - badge_h / 2, bx1 + badge_w, CAP_CY + badge_h / 2),
            8,
            mix(CARD, ACCENT, 0.16),
            ACCENT,
            1.15,
        )
        t_ink_center(draw, bx1 + badge_w / 2, CAP_CY, badge, FONT_BADGE, ACCENT)

    rounded(draw, EDITOR, 12, CARD_INNER, HAIR, 1.1)


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

    ex0, ey0, ex1, ey1 = EDITOR
    gutter_right = ex0 + GUTTER_LEFT + GUTTER_W
    code_x = gutter_right + CODE_GAP
    first_baseline = ey0 + CODE_PAD_Y + cap_h(draw, FONT_CODE)

    for i, line in enumerate(shown):
        by = first_baseline + i * LINE_H
        t_ink_right_base(draw, gutter_right, by, str(i + 1), FONT_BADGE, mix(CARD_INNER, MUTED, 0.55))
        end_x = draw_tokens(draw, code_x, by, tokenizer(line), FONT_CODE)
        if caret and i == visible_lines - 1:
            cap = cap_h(draw, FONT_CODE)
            cx, cy = px(end_x + 3), px(by - cap)
            draw.rectangle((cx, cy, cx + px(2), px(by + 2)), fill=ACCENT)

    if active == 2 and visible_lines >= len(lines):
        note = "user.email    ·    user.subscription.name    ·    user.videos_count"
        rule_y = ey1 - 52
        draw.line(
            [px(code_x), px(rule_y), px(ex1 - 28), px(rule_y)],
            fill=HAIR,
            width=px(1),
        )
        t_ink_left_base(draw, code_x, ey1 - 28, note, FONT_UI_SM, MUTED)

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
    for n in range(1, len(lines) + 1):
        img = draw_scene(active, n, extra_badge=extra_badge, caret=n < len(lines))
        frames.append(img)
        durations.append(70 if n < len(lines) else 120)
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
        subprocess.check_call([str(gifsicle), "-O3", "--no-warnings", str(OUT_GIF), "-o", str(OUT_GIF)])

    qa = Path("/tmp/pluckr-demo-qa")
    qa.mkdir(exist_ok=True)
    downsample(draw_scene(0, len(CODE.split("\n")))).save(qa / "1-query.png")
    downsample(draw_scene(1, len(SQL.split("\n")), extra_badge="1 statement")).save(qa / "2-sql.png")
    downsample(draw_scene(2, len(RESULT.split("\n")))).save(qa / "3-result.png")

    size_kb = OUT_GIF.stat().st_size / 1024
    print(f"wrote {OUT_GIF}  {len(frames)} frames  {OUT_SIZE[0]}×{OUT_SIZE[1]}  {size_kb:.0f} KB")


if __name__ == "__main__":
    main()
