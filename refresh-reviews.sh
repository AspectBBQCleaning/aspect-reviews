#!/bin/bash
# ──────────────────────────────────────────────
# refresh-reviews.sh
# Fetches your Google reviews and injects them
# into google-reviews-widget.html
#
# ACCUMULATES reviews over time — each run keeps
# existing reviews and adds any new ones it finds.
#
# Usage:
#   cd /path/to/folder
#   bash refresh-reviews.sh
#
# Schedule daily (optional):
#   crontab -e
#   0 6 * * * cd /path/to/folder && bash refresh-reviews.sh
# ──────────────────────────────────────────────

# Uses env vars if set (for GitHub Actions), otherwise falls back to defaults
API_KEY="${GOOGLE_API_KEY:-AIzaSyAyznTjMMCkTjxrd6kDAO_lKLv66L15L8U}"
PLACE_ID="${GOOGLE_PLACE_ID:-ChIJfbFf_7K2aUwRNH0xcWaMrD0}"
MIN_STARS=4
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HTML_FILE="$SCRIPT_DIR/google-reviews-widget.html"
TEMP_FILE="$SCRIPT_DIR/.reviews_temp.json"
ARCHIVE_FILE="$SCRIPT_DIR/.reviews_archive.json"

echo "Fetching reviews from Google Places API (New)..."

# Fetch place details using the NEW Places API
curl -s -X GET \
  "https://places.googleapis.com/v1/places/${PLACE_ID}?fields=reviews,rating,userRatingCount&key=${API_KEY}" \
  -H "Content-Type: application/json" \
  -o "$TEMP_FILE"

# Check for errors
HAS_ERROR=$(python3 -c "
import json
d=json.load(open('$TEMP_FILE'))
print('yes' if 'error' in d else 'no')
" 2>/dev/null)

if [ "$HAS_ERROR" = "yes" ]; then
  ERROR_MSG=$(python3 -c "
import json
d=json.load(open('$TEMP_FILE'))
e=d.get('error',{})
print(f\"{e.get('status','UNKNOWN')} — {e.get('message','Unknown error')}\")
" 2>/dev/null)
  echo "Error: $ERROR_MSG"
  rm -f "$TEMP_FILE"
  exit 1
fi

# Use Python3 to process, accumulate, and inject
export MIN_STARS TEMP_FILE HTML_FILE ARCHIVE_FILE
python3 << 'PYEOF'
import json, sys, re, os
from datetime import datetime

min_stars = int(os.environ.get("MIN_STARS", 4))
temp_file = os.environ["TEMP_FILE"]
html_file = os.environ["HTML_FILE"]
archive_file = os.environ["ARCHIVE_FILE"]

with open(temp_file) as f:
    data = json.load(f)

# ── Parse new API response ──
all_reviews = data.get("reviews", [])
overall_rating = data.get("rating")
total_ratings = data.get("userRatingCount")

# Map from new API format
def map_review(r):
    author = r.get("authorAttribution", {})
    text_obj = r.get("text", {})
    return {
        "author_name": author.get("displayName", "Google User"),
        "rating": r.get("rating", 5),
        "text": text_obj.get("text", "") if isinstance(text_obj, dict) else str(text_obj),
        "relative_time_description": r.get("relativePublishTimeDescription", ""),
        "profile_photo_url": author.get("photoUri", ""),
    }

new_reviews = [map_review(r) for r in all_reviews if r.get("rating", 0) >= min_stars]
print(f"Fetched {len(all_reviews)} reviews from API, {len(new_reviews)} with {min_stars}+ stars.")

# ── Load existing archive ──
existing = []
if os.path.exists(archive_file):
    try:
        with open(archive_file) as f:
            archive = json.load(f)
            existing = archive.get("reviews", [])
        print(f"Loaded {len(existing)} existing reviews from archive.")
    except:
        print("Could not read archive, starting fresh.")

# ── Merge: deduplicate by author_name + first 80 chars of text ──
def review_key(r):
    text_snippet = (r.get("text", "") or "")[:80].strip().lower()
    name = (r.get("author_name", "") or "").strip().lower()
    return name + "|" + text_snippet

seen = {}
merged = []

# Existing reviews first (preserve order)
for r in existing:
    k = review_key(r)
    if k not in seen:
        seen[k] = True
        merged.append(r)

# Add any new reviews not already in archive
added = 0
for r in new_reviews:
    k = review_key(r)
    if k not in seen:
        seen[k] = True
        merged.append(r)
        added += 1
    else:
        # Update the relative_time_description for existing reviews
        for m in merged:
            if review_key(m) == k and r.get("relative_time_description"):
                m["relative_time_description"] = r["relative_time_description"]
                if r.get("profile_photo_url"):
                    m["profile_photo_url"] = r["profile_photo_url"]
                break

print(f"New reviews added: {added}")
print(f"Total accumulated reviews: {len(merged)}")

if not merged:
    print("No reviews available. Widget not updated.")
    sys.exit(1)

# ── Save archive ──
archive_data = {
    "reviews": merged,
    "overall_rating": overall_rating,
    "total_ratings": total_ratings,
    "fetched_at": datetime.now().isoformat(),
}

with open(archive_file, "w") as f:
    json.dump(archive_data, f, indent=2, ensure_ascii=False)

# ── Inject into HTML ──
cached_json = json.dumps(archive_data, indent=2, ensure_ascii=False)

with open(html_file, "r") as f:
    html = f.read()

marker = "// __CACHED_REVIEWS_DATA__"
replacement = f"{marker}\n  const CACHED_DATA = {cached_json};"

# Remove any previous cached data
html = re.sub(
    r'// __CACHED_REVIEWS_DATA__\n\s*const CACHED_DATA = [\s\S]*?;\n',
    marker + '\n',
    html,
    count=1
)

# Inject fresh data
html = html.replace(marker, replacement, 1)

with open(html_file, "w") as f:
    f.write(html)

print(f"\nWidget updated successfully!")
print(f"  Total reviews:  {len(merged)}")
print(f"  Overall rating: {overall_rating}")
print(f"  Last fetched:   {archive_data['fetched_at']}")
print(f"  File: {html_file}")
PYEOF

# Clean up temp
rm -f "$TEMP_FILE"
