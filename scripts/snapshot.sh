#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SNAPSHOTS_DIR="$ROOT_DIR/snapshots"
PLAYLISTS_FILE="$ROOT_DIR/playlists.json"
TODAY="$(date -u +%Y-%m-%d)"

# --- Fetch tracks from Spotify embed page (no auth needed) ---

fetch_tracks() {
  local playlist_id="$1"
  local html
  html=$(curl -sL "https://open.spotify.com/embed/playlist/${playlist_id}" \
    -H "User-Agent: Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)")

  # Extract __NEXT_DATA__ JSON from the embed page
  local json
  json=$(echo "$html" | sed -n 's/.*<script id="__NEXT_DATA__" type="application\/json">\(.*\)<\/script>.*/\1/p')

  if [ -z "$json" ]; then
    echo "Error: Could not extract track data for playlist $playlist_id" >&2
    return 1
  fi

  echo "$json" | jq '{
    cover_art: (.props.pageProps.state.data.entity.coverArt.sources[0].url // null),
    owner: (.props.pageProps.state.data.entity.subtitle // null),
    tracks: [.props.pageProps.state.data.entity.trackList[] | {
      name: .title,
      artists: [.subtitle],
      spotify_url: ("https://open.spotify.com/track/" + (.uri | split(":") | last)),
      duration_ms: .duration
    }] | sort_by(.spotify_url)
  }'
}

# --- Compare with latest snapshot ---

has_changed() {
  local playlist_dir="$1"
  local new_tracks="$2"

  local latest
  latest=$(ls -1 "$playlist_dir"/*.json 2>/dev/null | grep -v index.json | sort | tail -1 || true)

  if [ -z "$latest" ]; then
    return 0  # no previous snapshot — treat as changed
  fi

  local old_tracks
  old_tracks=$(jq '.tracks | sort_by(.spotify_url)' "$latest")

  if echo "$old_tracks" "$new_tracks" | jq -se '.[0] == .[1]' > /dev/null 2>&1; then
    return 1  # identical
  fi

  return 0  # changed
}

# --- Generate index.json ---

generate_index() {
  local index="[]"

  for playlist_dir in "$SNAPSHOTS_DIR"/*/; do
    [ -d "$playlist_dir" ] || continue
    local id
    id=$(basename "$playlist_dir")

    local name=""
    name=$(jq -r --arg id "$id" '.[] | select(.id == $id) | .name' "$PLAYLISTS_FILE")
    [ -z "$name" ] && name="$id"

    local dates="[]"
    dates=$(ls -1 "$playlist_dir"*.json 2>/dev/null | grep -v index.json | xargs -I{} basename {} .json | jq -R . | jq -s 'sort')

    index=$(echo "$index" | jq --arg id "$id" --arg name "$name" --argjson dates "$dates" \
      '. + [{"id": $id, "name": $name, "snapshots": $dates}]')
  done

  echo "$index" | jq '{"playlists": .}' > "$SNAPSHOTS_DIR/index.json"
}

# --- Main ---

main() {
  local any_changed=false
  local playlist_count
  playlist_count=$(jq length "$PLAYLISTS_FILE")

  for i in $(seq 0 $((playlist_count - 1))); do
    local id name
    id=$(jq -r ".[$i].id" "$PLAYLISTS_FILE")
    name=$(jq -r ".[$i].name" "$PLAYLISTS_FILE")

    echo "Fetching playlist: $name ($id)..."
    local playlist_dir="$SNAPSHOTS_DIR/$id"
    mkdir -p "$playlist_dir"

    local result
    result=$(fetch_tracks "$id")
    local tracks cover_art owner track_count
    tracks=$(echo "$result" | jq '.tracks')
    cover_art=$(echo "$result" | jq -r '.cover_art // empty')
    owner=$(echo "$result" | jq -r '.owner // empty')
    track_count=$(echo "$tracks" | jq length)

    if has_changed "$playlist_dir" "$tracks"; then
      echo "  Changes detected ($track_count tracks). Writing snapshot."
      jq -n \
        --arg pid "$id" \
        --arg pname "$name" \
        --arg date "$TODAY" \
        --argjson count "$track_count" \
        --argjson tracks "$tracks" \
        --arg cover_art "$cover_art" \
        --arg owner "$owner" \
        '{
          playlist_id: $pid,
          playlist_name: $pname,
          snapshot_date: $date,
          track_count: $count,
          cover_art: (if $cover_art == "" then null else $cover_art end),
          owner: (if $owner == "" then null else $owner end),
          tracks: $tracks
        }' > "$playlist_dir/$TODAY.json"
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
