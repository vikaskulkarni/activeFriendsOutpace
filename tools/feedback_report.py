#!/usr/bin/env python3
"""Generate a local HTML report of all in-app feedback from Supabase.

Reads credentials from the repo `.env` (SUPABASE_URL + SUPABASE_SERVICE_ROLE_KEY),
fetches every `feedback` row (service_role bypasses RLS so you see everyone's,
not just your own), joins the submitter's display name, and writes
`feedback_report.html` next to this script with a table and inline screenshots.

Why service_role? The feedback table's RLS only lets a user read their OWN rows,
and the publishable/anon key has no read policy at all. Admin viewing is
service-role only (same as the Supabase dashboard).

Setup (one time):
    1. Supabase Dashboard -> Project Settings -> API -> "service_role" secret -> copy.
    2. Add this line to the repo .env (it's gitignored, so it stays local):
         SUPABASE_SERVICE_ROLE_KEY=eyJhbGci...
       Keep this key secret: it is full admin access to the database.

Usage:
    python3 tools/feedback_report.py             # fetch, write, open in browser
    python3 tools/feedback_report.py --no-open   # just write the file
    python3 tools/feedback_report.py --from-file rows.json   # render from a saved
                                                             # PostgREST JSON response
"""
from __future__ import annotations

import argparse
import html
import json
import sys
import urllib.error
import urllib.request
import webbrowser
from datetime import datetime, timezone
from pathlib import Path

try:
    from zoneinfo import ZoneInfo

    IST = ZoneInfo("Asia/Kolkata")
except Exception:  # pragma: no cover - zoneinfo always present on 3.9+
    IST = None

REPO_ROOT = Path(__file__).resolve().parent.parent
ENV_PATH = REPO_ROOT / ".env"
OUT_PATH = Path(__file__).resolve().parent / "feedback_report.html"

# PostgREST embeds the related profile via the feedback.user_id -> profiles.id FK.
SELECT = (
    "created_at,category,screen,status,description,screenshot_urls,"
    "app_version,platform,os_version,profiles(display_name)"
)

CATEGORY_EMOJI = {"bug": "🐛", "feature": "💡", "ui_ux": "🎨", "general": "💬"}
STATUS_STYLE = {
    "submitted": ("🔵", "#2563eb"),
    "reviewing": ("🟡", "#ca8a04"),
    "fixed": ("✅", "#16a34a"),
    "noted": ("⚪", "#6b7280"),
}


def die(msg: str) -> "None":
    print(f"error: {msg}", file=sys.stderr)
    sys.exit(1)


def load_env(path: Path) -> dict:
    env: dict = {}
    if not path.exists():
        return env
    for line in path.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, _, value = line.partition("=")
        env[key.strip()] = value.strip().strip('"').strip("'")
    return env


def fetch_rows(base_url: str, key: str) -> list:
    endpoint = (
        f"{base_url.rstrip('/')}/rest/v1/feedback"
        f"?select={SELECT}&order=created_at.desc"
    )
    req = urllib.request.Request(
        endpoint,
        headers={
            "apikey": key,
            "Authorization": f"Bearer {key}",
            "Accept": "application/json",
        },
    )
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            return json.loads(resp.read().decode())
    except urllib.error.HTTPError as exc:
        body = exc.read().decode(errors="replace")
        die(f"HTTP {exc.code} from Supabase -> {body}")
    except urllib.error.URLError as exc:
        die(f"could not reach Supabase: {exc.reason}")
    return []  # unreachable; keeps type checkers happy


def fmt_time(raw: str) -> str:
    try:
        dt = datetime.fromisoformat(str(raw).replace("Z", "+00:00"))
    except ValueError:
        return html.escape(str(raw))
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=timezone.utc)
    if IST is not None:
        return dt.astimezone(IST).strftime("%d %b %Y · %H:%M IST")
    return dt.astimezone(timezone.utc).strftime("%d %b %Y · %H:%M UTC")


def submitter_name(row: dict) -> str:
    profile = row.get("profiles")
    if isinstance(profile, dict) and profile.get("display_name"):
        return str(profile["display_name"])
    return "(unknown)"


def render_screens(urls) -> str:
    if not isinstance(urls, list) or not urls:
        return '<span class="muted">—</span>'
    thumbs = []
    for url in urls:
        safe = html.escape(str(url), quote=True)
        thumbs.append(
            f'<a href="{safe}" target="_blank" rel="noopener">'
            f'<img class="shot" src="{safe}" loading="lazy" alt="screenshot"></a>'
        )
    return '<div class="shots">' + "".join(thumbs) + "</div>"


def render_html(rows: list) -> str:
    generated = (
        datetime.now(IST).strftime("%d %b %Y · %H:%M IST")
        if IST is not None
        else datetime.now(timezone.utc).strftime("%d %b %Y · %H:%M UTC")
    )

    body_rows = []
    for row in rows:
        cat = str(row.get("category", ""))
        status = str(row.get("status", ""))
        emoji = CATEGORY_EMOJI.get(cat, "")
        badge, color = STATUS_STYLE.get(status, ("", "#6b7280"))
        build = " · ".join(
            str(v)
            for v in (row.get("app_version"), row.get("platform"), row.get("os_version"))
            if v
        )
        body_rows.append(
            "<tr>"
            f'<td class="when">{fmt_time(row.get("created_at", ""))}</td>'
            f'<td>{html.escape(submitter_name(row))}</td>'
            f'<td>{emoji} {html.escape(cat)}</td>'
            f'<td>{html.escape(str(row.get("screen", "")))}</td>'
            f'<td><span class="status" style="color:{color}">{badge} {html.escape(status)}</span></td>'
            f'<td class="desc">{html.escape(str(row.get("description", "")))}</td>'
            f'<td>{render_screens(row.get("screenshot_urls"))}</td>'
            f'<td class="build">{html.escape(build)}</td>'
            "</tr>"
        )

    rows_html = "\n".join(body_rows) or (
        '<tr><td colspan="8" class="muted" style="padding:32px;text-align:center">'
        "No feedback rows returned.</td></tr>"
    )

    return f"""<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Outpace · Feedback</title>
<style>
  :root {{ color-scheme: light dark; }}
  body {{ font: 15px/1.5 -apple-system, system-ui, sans-serif; margin: 0; padding: 24px;
         background: Canvas; color: CanvasText; }}
  h1 {{ font-size: 20px; margin: 0 0 2px; }}
  .meta {{ color: #888; font-size: 13px; margin-bottom: 20px; }}
  table {{ border-collapse: collapse; width: 100%; }}
  th, td {{ text-align: left; padding: 10px 12px; vertical-align: top;
           border-bottom: 1px solid color-mix(in srgb, CanvasText 12%, transparent); }}
  th {{ font-size: 12px; text-transform: uppercase; letter-spacing: .04em; color: #888; }}
  tr:hover td {{ background: color-mix(in srgb, CanvasText 4%, transparent); }}
  .when {{ white-space: nowrap; color: #888; font-size: 13px; }}
  .desc {{ min-width: 180px; max-width: 320px; }}
  .status {{ font-weight: 600; white-space: nowrap; }}
  .build {{ color: #888; font-size: 12px; max-width: 160px; }}
  .muted {{ color: #999; }}
  .shots {{ display: flex; gap: 6px; flex-wrap: wrap; }}
  .shot {{ height: 96px; width: auto; border-radius: 8px; object-fit: cover;
          border: 1px solid color-mix(in srgb, CanvasText 15%, transparent); }}
</style>
</head>
<body>
  <h1>Outpace · In-app feedback</h1>
  <div class="meta">{len(rows)} row(s) · generated {generated}</div>
  <table>
    <thead>
      <tr><th>When</th><th>Who</th><th>Category</th><th>Screen</th><th>Status</th>
          <th>Description</th><th>Screenshots</th><th>Build</th></tr>
    </thead>
    <tbody>
{rows_html}
    </tbody>
  </table>
</body>
</html>
"""


def main() -> None:
    parser = argparse.ArgumentParser(description="Generate an HTML feedback report.")
    parser.add_argument("--no-open", action="store_true", help="do not open the browser")
    parser.add_argument(
        "--from-file",
        metavar="PATH",
        help="render from a saved PostgREST JSON array instead of calling Supabase",
    )
    args = parser.parse_args()

    if args.from_file:
        rows = json.loads(Path(args.from_file).read_text())
    else:
        env = load_env(ENV_PATH)
        base_url = env.get("SUPABASE_URL")
        key = env.get("SUPABASE_SERVICE_ROLE_KEY")
        if not base_url:
            die(f"SUPABASE_URL not found in {ENV_PATH}")
        if not key:
            die(
                "SUPABASE_SERVICE_ROLE_KEY not found in .env.\n"
                "  The publishable key can't read all feedback (RLS). Add the service_role key:\n"
                "  Supabase Dashboard -> Project Settings -> API -> 'service_role' secret, then put\n"
                "    SUPABASE_SERVICE_ROLE_KEY=<key>\n"
                f"  in {ENV_PATH} (it's gitignored). Keep it secret — it's full DB admin access."
            )
        rows = fetch_rows(base_url, key)

    OUT_PATH.write_text(render_html(rows))
    print(f"wrote {len(rows)} row(s) -> {OUT_PATH}")
    if not args.no_open:
        webbrowser.open(OUT_PATH.as_uri())


if __name__ == "__main__":
    main()
