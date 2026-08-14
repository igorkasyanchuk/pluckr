#!/usr/bin/env python3
"""Render docs/demo.gif — a three-beat walkthrough of a Pluckr query."""

from __future__ import annotations

from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

ROOT = Path(__file__).resolve().parent
OUT_GIF = ROOT / "demo.gif"
PREVIEW = ROOT / "demo-preview.png"

W, H = 960, 540
FPS = 12

# GitHub-dark adjacent, a bit warmer so it doesn't look like a screenshot dump.
BG = (13, 17, 23)
CARD = (22, 27, 34)
CARD_INNER = (16, 20, 26)
BORDER = (48, 54, 61)
TEXT = (230, 237, 243)
MUTED = (139, 148, 158)
DIM = (88, 96, 108)
ACCENT = (63, 185, 132)
AMBER = (210, 168, 92)
RUBY_KW = (255, 123, 114)
RUBY_NAME = (210, 168, 255)
RUBY_SYM = (121, 192, 255)
RUBY_STR = (165, 214, 132)
SQL_KW = (121, 192, 255)
SQL_FN = (210, 168, 255)
SQL_STR = (165, 214, 132)
RESULT_KEY = (121, 192, 255)
RESULT_STR = (165, 214, 132)
RESULT_NUM = (210, 168, 92)

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


def font(path: str, size: int, index: int = 0) -> ImageFont.FreeTypeFont:
    try:
        return ImageFont.truetype(path, size, index=index)
    except OSError:
        return ImageFont.truetype(path, size)


FONT_UI = font("/System/Library/Fonts/SFNS.ttf", 15)
FONT_UI_SM = font("/System/Library/Fonts/SFNS.ttf", 13)
FONT_TITLE = font("/System/Library/Fonts/SFNS.ttf", 18)
FONT_CODE = font("/System/Library/Fonts/SFNSMono.ttf", 15)
FONT_CODE_SM = font("/System/Library/Fonts/SFNSMono.ttf", 13)
FONT_BADGE = font("/System/Library/Fonts/SFNS.ttf", 12)


def rounded(draw: ImageDraw.ImageDraw, box, radius, fill, outline=None, width=1):
    draw.rounded_rectangle(box, radius=radius, fill=fill, outline=outline, width=width)


def lerp(a, b, t):
    t = max(0.0, min(1.0, t))
    t = t * t * (3 - 2 * t)
    return a + (b - a) * t


def mix(c1, c2, t):
    t = max(0.0, min(1.0, t))
    return tuple(int(a + (b - a) * t) for a, b in zip(c1, c2))


def tokenize_ruby(line: str):
    tokens = []
    i = 0
    n = len(line)
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
            tokens.append((line[i:j], RUBY_STR))
            i = j
        elif ch.isalnum() or ch == "_":
            j = i
            while j < n and (line[j].isalnum() or line[j] in "_:"):
                j += 1
            word = line[i:j]
            if word in RUBY_KEYWORDS:
                tokens.append((word, RUBY_KW))
            elif word in {"UserSummary", "Pluckr", "Query", "User"}:
                tokens.append((word, RUBY_NAME))
            elif word in {"true", "false", "nil"}:
                tokens.append((word, AMBER))
            else:
                tokens.append((word, TEXT))
            i = j
        else:
            tokens.append((ch, DIM))
            i += 1
    return tokens


def tokenize_sql(line: str):
    tokens = []
    i = 0
    n = len(line)
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
            tokens.append((line[i:j], SQL_STR))
            i = j
        elif ch.isalnum() or ch == "_":
            j = i
            while j < n and (line[j].isalnum() or line[j] in "_.*"):
                j += 1
            word = line[i:j]
            upper = word.upper()
            if upper in SQL_KEYWORDS:
                tokens.append((word, SQL_KW))
            elif upper in SQL_FUNCS:
                tokens.append((word, SQL_FN))
            else:
                tokens.append((word, TEXT))
            i = j
        else:
            tokens.append((ch, DIM))
            i += 1
    return tokens


def tokenize_result(line: str):
    tokens = []
    i = 0
    n = len(line)
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
            tokens.append((line[i:j], RESULT_STR))
            i = j
        elif ch.isdigit():
            j = i
            while j < n and (line[j].isdigit() or line[j] == "."):
                j += 1
            tokens.append((line[i:j], RESULT_NUM))
            i = j
        elif ch.isalpha() or ch == "_":
            j = i
            while j < n and (line[j].isalnum() or line[j] == "_"):
                j += 1
            word = line[i:j]
            nxt = line[j] if j < n else ""
            if word in {"true", "false", "nil"}:
                tokens.append((word, AMBER))
            elif nxt == ":":
                tokens.append((word, RESULT_KEY))
            else:
                tokens.append((word, TEXT))
            i = j
        else:
            tokens.append((ch, DIM))
            i += 1
    return tokens


def draw_tokens(draw, x, y, tokens, font_, alpha=255):
    for text, color in tokens:
        fill = TEXT if color is None else color
        if alpha < 255:
            fill = mix(CARD_INNER, fill, alpha / 255)
        draw.text((x, y), text, font=font_, fill=fill)
        x += draw.textlength(text, font=font_)


def draw_chrome(draw: ImageDraw.ImageDraw, active: int, caption: str, caption_alpha=255, badge: str | None = None):
    draw.rectangle((0, 0, W, H), fill=BG)

    # Window
    rounded(draw, (28, 22, W - 28, H - 22), 16, CARD, BORDER, 1)

    # Title row
    draw.text((52, 40), "Pluckr", font=FONT_TITLE, fill=TEXT)
    draw.text((118, 43), "one statement  ·  frozen result", font=FONT_UI_SM, fill=MUTED)

    # Step pills
    x = 52
    y = 78
    for i, (num, label, _) in enumerate(STEPS):
        on = i == active
        pill_w = 92 if i == 1 else 86
        fill = mix(CARD, ACCENT, 0.18) if on else CARD_INNER
        outline = ACCENT if on else BORDER
        rounded(draw, (x, y, x + pill_w, y + 28), 14, fill, outline, 1)
        nfill = ACCENT if on else DIM
        lfill = TEXT if on else MUTED
        draw.text((x + 12, y + 6), num, font=FONT_BADGE, fill=nfill)
        draw.text((x + 28, y + 5), label, font=FONT_UI_SM, fill=lfill)
        x += pill_w + 10
        if i < 2:
            draw.text((x - 8, y + 4), "→", font=FONT_UI, fill=DIM)
            x += 8

    # Caption under pills
    cap = mix(BG, MUTED, caption_alpha / 255) if caption_alpha < 255 else MUTED
    draw.text((52, 118), caption, font=FONT_UI, fill=cap)

    if badge:
        bw = 112
        bx1 = W - 48 - bw
        rounded(draw, (bx1, 114, bx1 + bw, 136), 8, mix(CARD, ACCENT, 0.16), ACCENT, 1)
        draw.text((bx1 + 10, 117), badge, font=FONT_BADGE, fill=ACCENT)

    # Editor card
    rounded(draw, (48, 148, W - 48, H - 48), 12, CARD_INNER, BORDER, 1)


def draw_scene(active: int, visible_lines: int, extra_badge: str | None = None, line_alpha=255):
    img = Image.new("RGB", (W, H), BG)
    draw = ImageDraw.Draw(img)
    _, _, caption = STEPS[active]
    draw_chrome(draw, active, caption, badge=extra_badge)

    body = (CODE, SQL, RESULT)[active]
    tokenizer = (tokenize_ruby, tokenize_sql, tokenize_result)[active]
    code_font = FONT_CODE if active != 1 else FONT_CODE_SM
    lines = body.split("\n")
    shown = lines[:visible_lines]

    x0, y0 = 68, 168
    lh = 21 if active == 1 else 22
    for i, line in enumerate(shown):
        alpha = 255 if i < visible_lines - 1 else line_alpha
        draw_tokens(draw, x0, y0 + i * lh, tokenizer(line), code_font, alpha=alpha)

    if active == 2 and visible_lines >= len(body.split("\n")):
        note = "user.email    user.subscription.name    user.videos_count"
        draw.text((68, H - 76), note, font=FONT_UI_SM, fill=DIM)

    return img


def hold(frames, img, seconds):
    frames.extend([img] * max(1, int(seconds * FPS)))


def fade(frames, a: Image.Image, b: Image.Image, seconds=0.28):
    n = max(2, int(seconds * FPS))
    for i in range(1, n + 1):
        t = i / n
        frames.append(Image.blend(a, b, t * t * (3 - 2 * t)))


def reveal(frames, active: int, text: str, extra_badge=None, per_line=0.07, hold_end=1.8):
    lines = text.split("\n")
    prev = None
    for n in range(1, len(lines) + 1):
        img = draw_scene(active, n, extra_badge=extra_badge)
        frames.append(img)
        extra = 1 if n < len(lines) else 0
        frames.extend([img] * extra)
        prev = img
    hold(frames, prev, hold_end)
    return prev


def main():
    frames: list[Image.Image] = []

    # Scene 1 — query types in
    last = reveal(frames, 0, CODE, hold_end=1.7)

    empty2 = draw_scene(1, 0, extra_badge="1 statement")
    fade(frames, last, empty2, 0.32)
    last = reveal(frames, 1, SQL, extra_badge="1 statement", hold_end=2.1)

    # Scene 3 — result
    empty3 = draw_scene(2, 0)
    fade(frames, last, empty3, 0.32)
    last = reveal(frames, 2, RESULT, hold_end=2.2)

    # Return to query for a clean loop
    empty1 = draw_scene(0, 0)
    fade(frames, last, empty1, 0.36)

    # Quantize once from a representative frame so the palette is stable
    palette_src = frames[len(frames) // 2].quantize(colors=64, method=Image.Quantize.MEDIANCUT)
    converted = [im.quantize(palette=palette_src, dither=Image.Dither.NONE) for im in frames]

    duration = int(1000 / FPS)
    converted[0].save(
        OUT_GIF,
        save_all=True,
        append_images=converted[1:],
        duration=duration,
        loop=0,
        optimize=True,
        disposal=2,
    )

    # Static contact sheet for visual QA
    scenes = [
        draw_scene(0, len(CODE.split("\n"))),
        draw_scene(1, len(SQL.split("\n")), extra_badge="1 statement"),
        draw_scene(2, len(RESULT.split("\n"))),
    ]
    sheet = Image.new("RGB", (W, H * 3), BG)
    for i, sc in enumerate(scenes):
        sheet.paste(sc, (0, i * H))
    sheet.save(PREVIEW)

    size_kb = OUT_GIF.stat().st_size / 1024
    print(f"wrote {OUT_GIF}  {len(converted)} frames  {size_kb:.0f} KB")
    print(f"wrote {PREVIEW}")


if __name__ == "__main__":
    main()
