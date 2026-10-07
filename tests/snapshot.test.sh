#!/usr/bin/env bash
# Runs scripts/snapshot.sh in a throwaway copy of the repo against fixture
# pages served by a fake curl. Usage: bash tests/snapshot.test.sh
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FIX="$ROOT/tests/fixtures"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
ID=testplaylist
FAILS=0

# Fake curl: serves $EMBED / $PAGE (fixture paths) or fails when set to "fail".
mkdir -p "$WORK/bin"
cat > "$WORK/bin/curl" <<'EOF'
#!/usr/bin/env bash
url=""; for a in "$@"; do case "$a" in https://*) url="$a";; esac; done
case "$url" in
  */embed/playlist/broken*) echo "<html>no data</html>" ;;
  */embed/playlist/*) [ "$EMBED" = fail ] && exit 22; cat "$EMBED" ;;
  */playlist/*)       [ "$PAGE" = fail ] && exit 22; cat "$PAGE" ;;
esac
EOF
chmod +x "$WORK/bin/curl"

# Derived fixtures for individual scenarios.
sed 's/ab67706c0000da84aaaa/ab67706c0000d72caaaa/; s/image-cdn-fa/image-cdn-ak/' "$FIX/embed.html" > "$WORK/embed-cdn.html"
python3 - "$FIX/embed.html" "$WORK" <<'EOF'
import json, re, sys
src, out = sys.argv[1], sys.argv[2]
html = open(src).read()
m = re.search(r'(<script id="__NEXT_DATA__" type="application/json">)(.*?)(</script>)', html, re.S)
def write(name, mutate):
    data = json.loads(m.group(2))
    mutate(data["props"]["pageProps"]["state"]["data"]["entity"])
    open(f"{out}/{name}", "w").write(html[:m.start(2)] + json.dumps(data) + html[m.end(2):])
write("embed-reordered.html", lambda e: e["trackList"].reverse())
write("embed-empty.html", lambda e: e.update(trackList=[]))
EOF
sed 's/<meta property="og:description"[^>]*>//' "$FIX/page.html" > "$WORK/page-nodesc.html"
sed 's/<meta property="og:title"[^>]*>//' "$FIX/page.html" > "$WORK/page-notitle.html"

new_repo() {  # new_repo DIR [playlist ids...]
  local dir="$1"; shift
  mkdir -p "$dir/scripts" "$dir/snapshots"
  cp "$ROOT/scripts/snapshot.sh" "$dir/scripts/"
  printf '%s\n' "$@" | jq -R '{id: .}' | jq -s '.' > "$dir/playlists.json"
}

run() {  # run DIR [VAR=value...] — sets OUT and STATUS
  local dir="$1"; shift
  OUT=$(env PATH="$WORK/bin:$PATH" EMBED="$FIX/embed.html" PAGE="$FIX/page.html" "$@" bash "$dir/scripts/snapshot.sh" 2>&1)
  STATUS=$?
}

count() { ls "$1/snapshots/$ID" | wc -l | tr -d ' '; }
newest() { ls "$1/snapshots/$ID" | sort | tail -1; }
field() { jq -c "$2" "$1/snapshots/$ID/$(newest "$1")"; }

check() {  # check NAME ACTUAL EXPECTED
  if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: expected $3, got $2"; FAILS=$((FAILS + 1)); fi
}

# Base repo with one snapshot under a fixed old filename, so later runs in the
# same second write a new file instead of overwriting it.
BASE="$WORK/base"
new_repo "$BASE" "$ID"
run "$BASE"
check "first run exits 0" "$STATUS" 0
mv "$BASE/snapshots/$ID/$(newest "$BASE")" "$BASE/snapshots/$ID/2000-01-01T000000Z.json"
check "parses tracks despite a later <script>" "$(field "$BASE" '[.tracks[].spotify_url]')" '["https://open.spotify.com/track/111","https://open.spotify.com/track/222"]'
check "artists kept as one joined string" "$(field "$BASE" '.tracks[1].artists')" '["Artist B, Artist C"]'
check "decodes HTML entities in description" "$(field "$BASE" '.description')" '"Fish & chips ’n stuff"'
check "records name and owner" "$(field "$BASE" '[.playlist_name, .owner]')" '["Test Mix","tester"]'

scenario() {  # scenario NAME — fresh copy of the base repo in $DIR
  DIR="$WORK/$1"; cp -R "$BASE" "$DIR"
}

scenario unchanged;   run "$DIR"
check "no change: no new snapshot" "$(count "$DIR")" 1

scenario cdn;         run "$DIR" EMBED="$WORK/embed-cdn.html"
check "cover CDN/size change only: no new snapshot" "$(count "$DIR")" 1

scenario reorder;     run "$DIR" EMBED="$WORK/embed-reordered.html"
check "reorder: new snapshot" "$(count "$DIR")" 2

scenario pagefail;    run "$DIR" PAGE=fail EMBED="$WORK/embed-reordered.html"
check "page fetch fails: description kept" "$(field "$DIR" '.description')" '"Fish & chips ’n stuff"'

scenario notitle;     run "$DIR" PAGE="$WORK/page-notitle.html" EMBED="$WORK/embed-reordered.html"
check "page without og:title: description kept" "$(field "$DIR" '.description')" '"Fish & chips ’n stuff"'

scenario nodesc;      run "$DIR" PAGE="$WORK/page-nodesc.html"
check "description removed: new snapshot" "$(count "$DIR")" 2
check "description removed: recorded as null" "$(field "$DIR" '.description')" null

scenario empty;       run "$DIR" EMBED="$WORK/embed-empty.html"
check "empty scrape: no new snapshot" "$(count "$DIR")" 1
check "empty scrape: exits 0" "$STATUS" 0
check "empty scrape: warns" "$(grep -c '::warning::' <<< "$OUT")" 1

scenario allowempty;  run "$DIR" EMBED="$WORK/embed-empty.html" ALLOW_EMPTY=1
check "ALLOW_EMPTY=1: empty snapshot written" "$(field "$DIR" '.track_count')" 0

MULTI="$WORK/multi"
new_repo "$MULTI" broken "$ID"
run "$MULTI"
check "one broken playlist: exits non-zero" "$([ "$STATUS" -ne 0 ] && echo yes)" yes
check "one broken playlist: reports an error" "$(grep -c '::error::' <<< "$OUT")" 1
check "one broken playlist: others still recorded" "$(count "$MULTI")" 1
check "one broken playlist: index lists the others" "$(jq -c '[.playlists[].id]' "$MULTI/snapshots/index.json")" "[\"$ID\"]"

echo
if [ "$FAILS" -eq 0 ]; then echo "All snapshot tests passed."; else echo "$FAILS snapshot test(s) failed."; exit 1; fi
