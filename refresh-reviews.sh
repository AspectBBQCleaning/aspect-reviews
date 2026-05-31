#!/bin/bash
# ──────────────────────────────────────────────
# refresh-reviews.sh
# Pulls ALL Google reviews via the Google Business Profile API (v4)
# and injects them (newest-first) into the widget HTML files.
#
# Why the Business Profile API and not the Places API:
#   The Places API returns only 5 reviews, ranked by relevance (not recency),
#   so genuinely recent reviews never reach the widget. The Business Profile
#   API returns the full review history with absolute publish dates.
#
# Auth (OAuth2 refresh-token flow) — set as GitHub Actions secrets:
#   GBP_CLIENT_ID, GBP_CLIENT_SECRET, GBP_REFRESH_TOKEN
# Non-secret config (defaults below; override via env if the profile moves):
#   GBP_ACCOUNT_ID, GBP_LOCATION_ID, GBP_QUOTA_PROJECT, MIN_STARS
# ──────────────────────────────────────────────

CLIENT_ID="${GBP_CLIENT_ID:?GBP_CLIENT_ID is required (set it as a GitHub Actions secret)}"
CLIENT_SECRET="${GBP_CLIENT_SECRET:?GBP_CLIENT_SECRET is required (set it as a GitHub Actions secret)}"
REFRESH_TOKEN="${GBP_REFRESH_TOKEN:?GBP_REFRESH_TOKEN is required (set it as a GitHub Actions secret)}"
ACCOUNT_ID="${GBP_ACCOUNT_ID:-106811548450724929062}"
LOCATION_ID="${GBP_LOCATION_ID:-4068395454767005433}"
QUOTA_PROJECT="${GBP_QUOTA_PROJECT:-aspect-admin-board}"
MIN_STARS="${MIN_STARS:-4}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HTML_FILE="$SCRIPT_DIR/google-reviews-widget.html"
ARCHIVE_FILE="$SCRIPT_DIR/.reviews_archive.json"
PAGE_DIR="$(mktemp -d)"
trap 'rm -rf "$PAGE_DIR"' EXIT

# ── 1. Mint an access token (review-only scope) from the refresh token ──
echo "Minting access token (business.manage)..."
ACCESS_TOKEN=$(curl -s https://oauth2.googleapis.com/token \
  -d client_id="$CLIENT_ID" \
  -d client_secret="$CLIENT_SECRET" \
  -d refresh_token="$REFRESH_TOKEN" \
  -d grant_type=refresh_token \
  -d scope="https://www.googleapis.com/auth/business.manage" \
  | python3 -c "import json,sys; print(json.load(sys.stdin).get('access_token',''))" 2>/dev/null)

if [ -z "$ACCESS_TOKEN" ]; then
  echo "ERROR: could not mint an access token. The refresh token may have been"
  echo "revoked or expired — re-run the one-time auth to generate a new one."
  exit 1
fi

# ── 2. Page through every review (newest first) ──
echo "Fetching reviews from Business Profile API..."
token=""
page=0
while :; do
  page=$((page + 1))
  url="https://mybusiness.googleapis.com/v4/accounts/${ACCOUNT_ID}/locations/${LOCATION_ID}/reviews?pageSize=50&orderBy=updateTime%20desc"
  [ -n "$token" ] && url="${url}&pageToken=${token}"
  curl -s "$url" \
    -H "Authorization: Bearer ${ACCESS_TOKEN}" \
    -H "x-goog-user-project: ${QUOTA_PROJECT}" \
    -o "${PAGE_DIR}/page_${page}.json"
  # bail out loudly on an API error rather than overwriting good data with junk
  ERR=$(python3 -c "import json;d=json.load(open('${PAGE_DIR}/page_${page}.json'));print(d.get('error',{}).get('message','')) if 'error' in d else print('')" 2>/dev/null)
  if [ -n "$ERR" ]; then echo "ERROR from API on page ${page}: ${ERR}"; exit 1; fi
  token=$(python3 -c "import json;print(json.load(open('${PAGE_DIR}/page_${page}.json')).get('nextPageToken',''))" 2>/dev/null)
  if [ -z "$token" ] || [ "$page" -ge 40 ]; then break; fi
done
echo "Fetched ${page} page(s)."

# ── 3. Process + inject ──
export PAGE_DIR HTML_FILE ARCHIVE_FILE MIN_STARS
python3 << 'PYEOF'
import json, os, re, glob, sys
from datetime import datetime, timezone

page_dir   = os.environ["PAGE_DIR"]
html_file  = os.environ["HTML_FILE"]
archive    = os.environ["ARCHIVE_FILE"]
min_stars  = int(os.environ.get("MIN_STARS", 4))

STAR = {"ONE": 1, "TWO": 2, "THREE": 3, "FOUR": 4, "FIVE": 5}

def clean_comment(c):
    if not c:
        return ""
    # Google bilingual format: "(Translated by Google) <en>\n\n(Original) <orig>"
    if "(Translated by Google)" in c:
        m = re.search(r"\(Translated by Google\)\s*(.*?)\s*\(Original\)", c, re.S)
        if m:
            return m.group(1).strip()
    return c.strip()

def rel_label(createtime):
    if not createtime:
        return ""
    dt = datetime.fromisoformat(createtime.replace("Z", "+00:00"))
    days = (datetime.now(timezone.utc) - dt).days
    if days <= 1:   return "a day ago"
    if days < 7:    return f"{days} days ago"
    if days < 14:   return "a week ago"
    if days < 31:   return f"{days // 7} weeks ago"
    if days < 60:   return "a month ago"
    if days < 365:  return f"{days // 30} months ago"
    if days < 730:  return "a year ago"
    return f"{days // 365} years ago"

# collect pages in order
pages = sorted(glob.glob(os.path.join(page_dir, "page_*.json")),
               key=lambda p: int(re.search(r"page_(\d+)\.json", p).group(1)))
raw, avg, total = [], None, None
for i, p in enumerate(pages):
    d = json.load(open(p))
    if i == 0:
        avg, total = d.get("averageRating"), d.get("totalReviewCount")
    raw.extend(d.get("reviews", []))
print(f"Pulled {len(raw)} reviews (averageRating={avg}, totalReviewCount={total}).")

reviews = []
for r in raw:
    rating = STAR.get(r.get("starRating"), 0)
    text = clean_comment(r.get("comment", ""))
    if rating < min_stars or not text:
        continue
    ct = r.get("createTime", "")
    reviews.append({
        "author_name": (r.get("reviewer") or {}).get("displayName", "Google User"),
        "rating": rating,
        "text": text,
        "relative_time_description": rel_label(ct),
        "publish_time": ct,
        "profile_photo_url": (r.get("reviewer") or {}).get("profilePhotoUrl", ""),
    })
reviews.sort(key=lambda r: r["publish_time"], reverse=True)
print(f"{len(reviews)} reviews with {min_stars}+ stars and text.")

# safety: never overwrite a healthy archive with a suspiciously small pull
prev = 0
if os.path.exists(archive):
    try:
        prev = len(json.load(open(archive)).get("reviews", []))
    except Exception:
        prev = 0
if not reviews:
    print("No reviews returned — leaving existing widget data untouched.")
    sys.exit(1)
if prev and len(reviews) < prev * 0.5:
    print(f"Pulled only {len(reviews)} vs {prev} archived — suspiciously low, aborting to protect data.")
    sys.exit(1)

data = {
    "reviews": reviews,
    "overall_rating": round(avg, 1) if isinstance(avg, (int, float)) else 4.9,
    "total_ratings": total,
    "fetched_at": datetime.now().isoformat(),
}
json.dump(data, open(archive, "w"), indent=2, ensure_ascii=False)

# inject into the widget(s)
marker = "// __CACHED_REVIEWS_DATA__"
replacement = f"{marker}\n  const CACHED_DATA = {json.dumps(data, indent=2, ensure_ascii=False)};"
targets = [html_file, os.path.join(os.path.dirname(html_file), "google-reviews-widget-mobile.html")]
for f in targets:
    if not os.path.exists(f):
        continue
    html = open(f).read()
    html = re.sub(r'// __CACHED_REVIEWS_DATA__\n\s*const CACHED_DATA = [\s\S]*?;\n', marker + '\n', html, count=1)
    html = html.replace(marker, replacement, 1)
    open(f, "w").write(html)
    print(f"Injected -> {os.path.basename(f)}")

print(f"Done. {len(reviews)} reviews, newest {reviews[0]['publish_time'][:10]}, rating {data['overall_rating']}.")
PYEOF
