#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SNAPSHOTS_DIR="$ROOT_DIR/snapshots"
PLAYLISTS_FILE="$ROOT_DIR/playlists.json"
NOW_DATE="$(date -u +%Y-%m-%d)"
NOW_FILE_TS="$(date -u +%Y-%m-%dT%H%M%SZ)"
NOW_ISO="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# --- Fetch playlist description from the public page (embed doesn't expose it) ---

# Exit status separates "couldn't read the page" (1, caller keeps the previous
# description) from "page read fine" (0, empty output means no description).
fetch_description() {
  local playlist_id="$1"
  local html
  if ! html=$(curl -sfL "https://open.spotify.com/playlist/${playlist_id}" \
    -H "User-Agent: Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)"); then
    echo "  Warning: description fetch failed for $playlist_id" >&2
    return 1
  fi
  # A 200 can still be an error or consent page; a real playlist page has og:title.
  if ! grep -q '<meta property="og:title"' <<< "$html"; then
    echo "  Warning: playlist page for $playlist_id has no og:title; not trusting it" >&2
    return 1
  fi
  local raw
  raw=$(echo "$html" \
    | grep -oE '<meta property="og:description" content="[^"]*"' \
    | head -1 \
    | sed -E 's/.*content="([^"]*)".*/\1/')
  [ -z "$raw" ] && return 0
  # Full HTML-entity decode via Python's html.unescape — handles named refs
  # (&nbsp;, &apos;, ...) and numeric refs (&#8217;, &#x2019;) that a hand-
  # rolled sed chain misses.
  printf '%s' "$raw" | python3 -c 'import sys, html; sys.stdout.write(html.unescape(sys.stdin.read()))'
}

# --- Fetch tracks from Spotify embed page (no auth needed) ---

fetch_tracks() {
  local playlist_id="$1"
  local html
  html=$(curl -sfL "https://open.spotify.com/embed/playlist/${playlist_id}" \
    -H "User-Agent: Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)")

  # Extract __NEXT_DATA__ JSON from the embed page
  local json
  json=$(echo "$html" | sed -n 's/.*<script id="__NEXT_DATA__" type="application\/json">\(.*\)<\/script>.*/\1/p')

  if [ -z "$json" ]; then
    echo "Error: Could not extract track data for playlist $playlist_id" >&2
    return 1
  fi

  # Preserve the playlist's authored track order — do NOT sort. Track order
  # is a meaningful, user-facing property (curator can rearrange), and a
  # reorder should trigger a new snapshot just like an add/remove would.
  echo "$json" | jq '{
    playlist_name: (.props.pageProps.state.data.entity.title // null),
    cover_art: (.props.pageProps.state.data.entity.coverArt.sources[0].url // null),
    owner: (.props.pageProps.state.data.entity.subtitle // null),
    tracks: [.props.pageProps.state.data.entity.trackList[] | {
      name: .title,
      artists: [.subtitle],
      spotify_url: ("https://open.spotify.com/track/" + (.uri | split(":") | last)),
      duration_ms: .duration
    }]
  }'
}

# Reduces a Spotify image URL to a stable identifier by extracting the last
# 24 hex chars of the /image/... path. This strips the CDN host prefix (which
# Spotify rotates: -ak, -fa, -fx, ...) and the leading 16-char size variant
# (ab67706c0000da84, ab67706c0000d72c, ...), leaving just the underlying
# image ID so a CDN rotation doesn't count as a real change.
normalize_cover_id() {
  local url="$1"
  [ "$url" = "null" ] || [ -z "$url" ] && { echo "null"; return; }
  local id
  id=$(echo "$url" | sed -E 's|.*/image/||')
  # last 24 chars, if we got a hex-like string; else pass through
  if echo "$id" | grep -qE '^[a-f0-9]+$'; then
    echo "${id: -24}"
  else
    echo "$id"
  fi
}

# Builds the "signature" JSON we compare across snapshots to decide if
# anything meaningful changed. Reads from an on-disk snapshot file.
# Order matches build_signature_from_new so the comparison is symmetric.
build_signature_from_file() {
  local file="$1"
  local cover_id
  cover_id=$(normalize_cover_id "$(jq -r '.cover_art // "null"' "$file")")
  jq --arg cover_id "$cover_id" '{
    playlist_name: (.playlist_name // null),
    description: (.description // null),
    cover_art_id: (if $cover_id == "null" then null else $cover_id end),
    tracks: .tracks
  }' "$file"
}

# --- Snapshot introspection ---

# Echoes the path of the newest snapshot in a playlist dir, or empty string.
# Uses the body's snapshot_time field (not the filename) as source of truth,
# since a migrated or clock-skewed file may not sort correctly by name.
latest_snapshot_file() {
  local playlist_dir="$1"
  local latest="" latest_time="" f t
  for f in "$playlist_dir"/*.json; do
    [ -f "$f" ] || continue
    [ "$(basename "$f")" = "index.json" ] && continue
    t=$(jq -r '.snapshot_time // (.snapshot_date + "T12:00:00Z")' "$f" 2>/dev/null || echo "")
    if [ -z "$latest_time" ] || [[ "$t" > "$latest_time" ]]; then
      latest_time="$t"
      latest="$f"
    fi
  done
  echo "$latest"
}

has_changed() {
  local playlist_dir="$1"
  local new_signature="$2"

  local latest
  latest=$(latest_snapshot_file "$playlist_dir")
  if [ -z "$latest" ]; then
    return 0  # no previous snapshot — treat as changed
  fi

  local old_signature
  old_signature=$(build_signature_from_file "$latest")

  if echo "$old_signature" "$new_signature" | jq -se '.[0] == .[1]' > /dev/null 2>&1; then
    return 1  # identical
  fi

  return 0  # changed
}

# Returns the value of a top-level field from the newest snapshot, or empty.
# Used to preserve cover_art/owner/description when a Spotify fetch returns
# empty for them — better a stale-but-real value than a null.
previous_field() {
  local playlist_dir="$1"
  local field="$2"
  local latest
  latest=$(latest_snapshot_file "$playlist_dir")
  [ -z "$latest" ] && return 0
  jq -r --arg f "$field" '.[$f] // empty' "$latest"
}

# --- Generate index.json ---

generate_index() {
  local index="[]"

  for playlist_dir in "$SNAPSHOTS_DIR"/*/; do
    [ -d "$playlist_dir" ] || continue
    local id
    id=$(basename "$playlist_dir")

    local name="" owner_url=""
    # Name comes from the newest snapshot's scraped playlist_name (not config).
    # Falls back to id if the playlist has no snapshots yet.
    local latest_file
    latest_file=$(latest_snapshot_file "$playlist_dir")
    [ -n "$latest_file" ] && name=$(jq -r '.playlist_name // empty' "$latest_file")
    [ -z "$name" ] && name="$id"
    owner_url=$(jq -r --arg id "$id" '.[] | select(.id == $id) | .owner_url // ""' "$PLAYLISTS_FILE")

    # Collect one entry per snapshot file, sorted ascending by filename
    # (filenames are lexically sortable because YYYY-MM-DDTHHMMSSZ is ISO-like)
    local entries="[]"
    for f in $(ls -1 "$playlist_dir"*.json 2>/dev/null | grep -v index.json | sort); do
      local file_base
      file_base=$(basename "$f")
      # Prefer snapshot_time from the file body; fall back to date-only for safety
      local snap_time snap_date
      snap_time=$(jq -r '.snapshot_time // empty' "$f")
      snap_date=$(jq -r '.snapshot_date // empty' "$f")
      if [ -z "$snap_time" ]; then
        snap_time="${snap_date}T12:00:00Z"
      fi
      entries=$(echo "$entries" | jq \
        --arg date "$snap_date" \
        --arg time "$snap_time" \
        --arg file "$file_base" \
        '. + [{date: $date, time: $time, file: $file}]')
    done

    # Field order here matches the on-disk file so a re-run doesn't churn the
    # diff. Do not reorder without also rewriting the committed index.json.
    index=$(echo "$index" | jq --arg id "$id" --arg name "$name" --arg owner_url "$owner_url" --argjson entries "$entries" \
      '. + [{"id": $id, "name": $name, "snapshots": $entries, "owner_url": (if $owner_url == "" then null else $owner_url end)}]')
  done

  echo "$index" | jq '{"playlists": .}' > "$SNAPSHOTS_DIR/index.json"
}

# --- Main ---

main() {
  local any_changed=false
  local playlist_count
  playlist_count=$(jq length "$PLAYLISTS_FILE")

  for i in $(seq 0 $((playlist_count - 1))); do
    local id
    id=$(jq -r ".[$i].id" "$PLAYLISTS_FILE")

    echo "Fetching playlist: $id..."
    local playlist_dir="$SNAPSHOTS_DIR/$id"
    mkdir -p "$playlist_dir"

    local result description
    result=$(fetch_tracks "$id")
    if ! description=$(fetch_description "$id"); then
      description=$(previous_field "$playlist_dir" description)
    fi
    local tracks cover_art owner scraped_name track_count
    tracks=$(echo "$result" | jq '.tracks')
    cover_art=$(echo "$result" | jq -r '.cover_art // empty')
    owner=$(echo "$result" | jq -r '.owner // empty')
    scraped_name=$(echo "$result" | jq -r '.playlist_name // empty')
    track_count=$(echo "$tracks" | jq length)

    # An empty list right after a non-empty one is far more likely a bad scrape
    # than a curator deleting everything; skip it rather than write fake history.
    local prev_count
    prev_count=$(previous_field "$playlist_dir" track_count)
    if [ "$track_count" -eq 0 ] && [ "${prev_count:-0}" -gt 0 ] && [ "${ALLOW_EMPTY:-0}" != "1" ]; then
      echo "::warning::$id scraped 0 tracks (previous snapshot had $prev_count). Skipping; rerun with ALLOW_EMPTY=1 if the playlist really is empty."
      continue
    fi

    # Prefer the previous snapshot's value over null when Spotify returns
    # nothing for a field. Prevents transient scrape hiccups from erasing
    # good metadata.
    [ -z "$cover_art" ]    && cover_art=$(previous_field "$playlist_dir" cover_art)
    [ -z "$owner" ]        && owner=$(previous_field "$playlist_dir" owner)
    [ -z "$scraped_name" ] && scraped_name=$(previous_field "$playlist_dir" playlist_name)
    # Ultimate fallback if we've never scraped a name for this playlist: the id.
    [ -z "$scraped_name" ] && scraped_name="$id"

    # Build the change-detection signature: {playlist_name, description,
    # cover_art_id (normalized), tracks}. Signature covers everything the
    # user perceives as "the playlist changed" without firing on CDN churn.
    local cover_id new_signature
    cover_id=$(normalize_cover_id "$cover_art")
    new_signature=$(jq -n \
      --arg pname "$scraped_name" \
      --arg desc "$description" \
      --arg cover_id "$cover_id" \
      --argjson tracks "$tracks" \
      '{
        playlist_name: (if $pname == "" then null else $pname end),
        description: (if $desc == "" then null else $desc end),
        cover_art_id: (if $cover_id == "null" then null else $cover_id end),
        tracks: $tracks
      }')

    if has_changed "$playlist_dir" "$new_signature"; then
      echo "  Changes detected ($track_count tracks). Writing snapshot."
      jq -n \
        --arg pid "$id" \
        --arg pname "$scraped_name" \
        --arg date "$NOW_DATE" \
        --arg time "$NOW_ISO" \
        --argjson count "$track_count" \
        --argjson tracks "$tracks" \
        --arg cover_art "$cover_art" \
        --arg owner "$owner" \
        --arg description "$description" \
        '{
          playlist_id: $pid,
          playlist_name: $pname,
          snapshot_date: $date,
          snapshot_time: $time,
          track_count: $count,
          cover_art: (if $cover_art == "" then null else $cover_art end),
          owner: (if $owner == "" then null else $owner end),
          description: (if $description == "" then null else $description end),
          tracks: $tracks
        }' > "$playlist_dir/$NOW_FILE_TS.json"
      any_changed=true
    else
      echo "  No changes detected. Skipping."
    fi
  done

  if [ "$any_changed" = true ]; then
    echo "Generating index..."
    generate_index
  fi

  echo "Done."
}

main
