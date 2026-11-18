"""Draw the launch screen's green glow.

The launch screen is bg/base with a faint green glow along the bottom edge, which the
loading screen's aurora then rises out of (docs/decisions.md, 2026-11-05). The same image
is drawn by the launch storyboard and, for the first moments of the app, by
`AuroraSkyView`, so the hand-over has no jump.

The glow is the aurora's green from `AuroraSky.metal` in an ellipse centred on the bottom
edge, with a light dither so the low alphas don't band. Output: a 1206 x 720 px PNG
(402 x 240 pt at @3x), stretched to the screen's width in both places.

    python3 tools/make_launch_glow.py
"""

from pathlib import Path
import random

from PIL import Image

WIDTH, HEIGHT = 1206, 720
GREEN = (56, 255, 133)  # float3(0.22, 1.0, 0.52) in AuroraSky.metal
PEAK_ALPHA = 0.16
OUT = Path(__file__).resolve().parent.parent / "ios/Zorja/Assets.xcassets/Launch/LaunchGlow.imageset/LaunchGlow.png"


def main() -> None:
    rng = random.Random(13)
    image = Image.new("RGBA", (WIDTH, HEIGHT))
    pixels = image.load()
    for y in range(HEIGHT):
        dy = (HEIGHT - y) / HEIGHT  # 0 at the bottom edge, 1 at the top
        for x in range(WIDTH):
            dx = (x - WIDTH / 2) / (WIDTH * 0.75)
            r2 = dx * dx + dy * dy
            falloff = max(0.0, 1.0 - r2) ** 2
            alpha = PEAK_ALPHA * falloff * 255 + rng.uniform(-0.5, 0.5)
            pixels[x, y] = (*GREEN, max(0, min(255, round(alpha))))
    OUT.parent.mkdir(parents=True, exist_ok=True)
    image.save(OUT, optimize=True)
    print(OUT)


if __name__ == "__main__":
    main()
