"""Generate a simple FreeTypeRecorder app icon: a white keyboard on an indigo
ground, with one key in red to signal "record". Supersampled 2x for smooth
edges, output as a 1024x1024 PNG into the AppIcon set."""
from PIL import Image, ImageDraw

SS = 2                      # supersample factor
W = 1024 * SS
INDIGO = (74, 86, 226)
WHITE = (255, 255, 255)
RED = (239, 68, 68)

def s(v):                   # scale a 1024-space coordinate to the SS canvas
    return int(round(v * SS))

img = Image.new("RGB", (W, W), INDIGO)
d = ImageDraw.Draw(img)

# Keyboard body (white rounded rectangle, centered).
d.rounded_rectangle([s(182), s(322), s(842), s(702)], radius=s(56), fill=WHITE)

# Keys are drawn in the ground color so they read as cut-outs in the body;
# the top-right key of the first row is red = the "record" key.
key_r = s(16)
def key(x0, y0, x1, y1, fill=INDIGO):
    d.rounded_rectangle([s(x0), s(y0), s(x1), s(y1)], radius=key_r, fill=fill)

row_xs = [230, 347, 464, 581, 698]   # 5 keys, width 96, gap 21
key_w = 96
# Row 1 (top-right key red).
for i, x in enumerate(row_xs):
    key(x, 372, x + key_w, 432, fill=RED if i == len(row_xs) - 1 else INDIGO)
# Row 2.
for x in row_xs:
    key(x, 460, x + key_w, 520)
# Row 3: a wide spacebar.
key(332, 548, 692, 608)

img = img.resize((1024, 1024), Image.LANCZOS)
out = ("FreeTypeRecorder/FreeTypeRecorder/Assets.xcassets/"
       "AppIcon.appiconset/icon-1024.png")
img.save(out, "PNG")
print("wrote", out, img.size)
