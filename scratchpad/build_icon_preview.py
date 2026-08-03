"""Build a self-contained HTML preview of the app icon with the PNG inlined
as a data URI (Artifact CSP blocks external hosts)."""
import base64, pathlib

png = pathlib.Path("FreeTypeRecorder/FreeTypeRecorder/Assets.xcassets/"
                   "AppIcon.appiconset/icon-1024.png").read_bytes()
uri = "data:image/png;base64," + base64.b64encode(png).decode()

html = f"""<title>FreeTypeRecorder — App Icon</title>
<style>
  :root {{
    --bg:#eef0f6; --panel:#ffffff; --ink:#1f2430; --muted:#5c6470;
    --line:#e2e5ee; --indigo:#4a56e2; --red:#ef4444;
    --shadow:0 1px 2px rgba(20,25,45,.05), 0 18px 40px rgba(20,25,45,.14);
  }}
  @media (prefers-color-scheme: dark) {{
    :root {{ --bg:#0f1117; --panel:#181b23; --ink:#e8ebf2; --muted:#9aa2b1;
      --line:#282c37; --shadow:0 1px 2px rgba(0,0,0,.4), 0 18px 44px rgba(0,0,0,.5); }}
  }}
  :root[data-theme="light"] {{ --bg:#eef0f6; --panel:#fff; --ink:#1f2430; --muted:#5c6470; --line:#e2e5ee;
    --shadow:0 1px 2px rgba(20,25,45,.05), 0 18px 40px rgba(20,25,45,.14); }}
  :root[data-theme="dark"] {{ --bg:#0f1117; --panel:#181b23; --ink:#e8ebf2; --muted:#9aa2b1; --line:#282c37;
    --shadow:0 1px 2px rgba(0,0,0,.4), 0 18px 44px rgba(0,0,0,.5); }}

  * {{ box-sizing:border-box; }}
  body {{ margin:0; background:var(--bg); color:var(--ink);
    font-family:-apple-system,BlinkMacSystemFont,"SF Pro Text","Segoe UI",system-ui,sans-serif;
    -webkit-font-smoothing:antialiased; line-height:1.5; }}
  .wrap {{ max-width:760px; margin:0 auto; padding:48px 24px 72px; }}
  .eyebrow {{ font-size:12px; font-weight:600; letter-spacing:.14em; text-transform:uppercase;
    color:var(--indigo); margin:0 0 8px; }}
  h1 {{ font-size:clamp(24px,4vw,32px); font-weight:700; letter-spacing:-.02em; margin:0 0 6px; }}
  .lede {{ color:var(--muted); margin:0 0 36px; }}

  .card {{ background:var(--panel); border:1px solid var(--line); border-radius:20px;
    box-shadow:var(--shadow); padding:36px; margin-bottom:20px; }}
  .hero {{ display:flex; justify-content:center; }}
  .icon {{ display:block; width:100%; height:100%; object-fit:cover; }}
  .rounded {{ border-radius:22.5%; overflow:hidden;
    box-shadow:0 1px 1px rgba(0,0,0,.06), 0 10px 24px rgba(20,25,45,.18); }}
  .hero .rounded {{ width:220px; height:220px; }}

  h2 {{ font-size:12px; font-weight:700; letter-spacing:.1em; text-transform:uppercase;
    color:var(--muted); margin:0 0 18px; }}
  .sizes {{ display:flex; flex-wrap:wrap; gap:28px; align-items:flex-end; }}
  .size {{ display:flex; flex-direction:column; align-items:center; gap:10px; }}
  .size span {{ font-size:12px; color:var(--muted); font-variant-numeric:tabular-nums; }}

  .home {{ border-radius:16px; padding:34px; display:flex; justify-content:center;
    background:linear-gradient(160deg,#5563e6,#8a5cf6 60%,#b06ab3); }}
  .appslot {{ display:flex; flex-direction:column; align-items:center; gap:9px; }}
  .appslot .rounded {{ width:96px; height:96px; }}
  .appslot .label {{ color:#fff; font-size:13px; font-weight:500;
    text-shadow:0 1px 3px rgba(0,0,0,.35); }}

  .specs {{ display:flex; flex-wrap:wrap; gap:18px 28px; align-items:center; }}
  .swatch {{ display:flex; align-items:center; gap:10px; font-size:14px; }}
  .chip {{ width:22px; height:22px; border-radius:6px; border:1px solid rgba(0,0,0,.12); }}
  .mono {{ font-family:ui-monospace,SFMono-Regular,Menlo,monospace; font-size:13px; color:var(--muted); }}
</style>

<div class="wrap">
  <p class="eyebrow">FreeTypeRecorder</p>
  <h1>App icon</h1>
  <p class="lede">A white keyboard on indigo, with one red key for “record”. Corners shown rounded the way iOS masks them on the Home Screen.</p>

  <div class="card hero">
    <div class="rounded"><img class="icon" alt="FreeTypeRecorder app icon" src="{uri}"></div>
  </div>

  <div class="card">
    <h2>At Home Screen sizes</h2>
    <div class="sizes">
      <div class="size"><div class="rounded" style="width:120px;height:120px"><img class="icon" alt="" src="{uri}"></div><span>120 px</span></div>
      <div class="size"><div class="rounded" style="width:87px;height:87px"><img class="icon" alt="" src="{uri}"></div><span>87 px</span></div>
      <div class="size"><div class="rounded" style="width:60px;height:60px"><img class="icon" alt="" src="{uri}"></div><span>60 px</span></div>
      <div class="size"><div class="rounded" style="width:40px;height:40px"><img class="icon" alt="" src="{uri}"></div><span>40 px</span></div>
    </div>
  </div>

  <div class="card">
    <h2>On a Home Screen</h2>
    <div class="home">
      <div class="appslot">
        <div class="rounded"><img class="icon" alt="" src="{uri}"></div>
        <div class="label">FreeType</div>
      </div>
    </div>
  </div>

  <div class="card">
    <h2>Specs</h2>
    <div class="specs">
      <div class="swatch"><span class="chip" style="background:#4a56e2"></span> Indigo <span class="mono">#4A56E2</span></div>
      <div class="swatch"><span class="chip" style="background:#ef4444"></span> Record key <span class="mono">#EF4444</span></div>
      <div class="swatch">Master <span class="mono">1024 × 1024 PNG</span></div>
    </div>
  </div>
</div>
"""

out = "scratchpad/app-icon-preview.html"
pathlib.Path(out).write_text(html)
print("wrote", out, len(html), "bytes")
