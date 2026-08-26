#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SNAPSHOTS_DIR="$ROOT_DIR/snapshots"
PLAYLISTS_FILE="$ROOT_DIR/playlists.json"
TODAY="$(date -u +%Y-%m-%d)"

# --- Auth ---

get_token() {
  local response
  response=$(curl -sf -X POST https://accounts.spotify.com/api/token \
    -H "Content-Type: application/x-www-form-urlencoded" \
    -d "grant_type=client_credentials&client_id=${SPOTIFY_CLIENT_ID}&client_secret=${SPOTIFY_CLIENT_SECRET}")
  echo "$response" | jq -r '.access_token'
}

# --- Fetch all tracks (handles pagination) ---

fetch_tracks() {
  local playlist_id="$1"
  local token="$2"
  local url="https://api.spotify.com/v1/playlists/${playlist_id}/tracks?fields=items(added_at,track(name,artists(name),album(name),external_urls(spotify),duration_ms)),next&limit=100"
  local all_items="[]"

  while [ "$url" != "null" ] && [ -n "$url" ]; do
    local response
    response=$(curl -sf "$url" -H "Authorization: Bearer $token")

    local items
    items=$(echo "$response" | jq '[.items[] | select(.track != null) | {
      name: .track.name,
      artists: [.track.artists[].name],
      album: .track.album.name,
      added_at: .added_at,
      spotify_url: .track.external_urls.spotify,
      duration_ms: .track.duration_ms
    }]')

    all_items=$(echo "$all_items" "$items" | jq -s '.[0] + .[1]')

    url=$(echo "$response" | jq -r '.next')
  done

  echo "$all_items" | jq 'sort_by(.spotify_url)'
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
  if [ -z "${SPOTIFY_CLIENT_ID:-}" ] || [ -z "${SPOTIFY_CLIENT_SECRET:-}" ]; then
    echo "Error: SPOTIFY_CLIENT_ID and SPOTIFY_CLIENT_SECRET must be set" >&2
    exit 1
  fi

  echo "Authenticating with Spotify..."
  local token
  token=$(get_token)

  if [ -z "$token" ] || [ "$token" = "null" ]; then
    echo "Error: Failed to get access token" >&2
    exit 1
  fi

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

    local tracks
    tracks=$(fetch_tracks "$id" "$token")
    local track_count
    track_count=$(echo "$tracks" | jq length)

    if has_changed "$playlist_dir" "$tracks"; then
      echo "  Changes detected ($track_count tracks). Writing snapshot."
      jq -n \
        --arg pid "$id" \
        --arg pname "$name" \
        --arg date "$TODAY" \
        --argjson count "$track_count" \
        --argjson tracks "$tracks" \
        '{
          playlist_id: $pid,
          playlist_name: $pname,
          snapshot_date: $date,
          track_count: $count,
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
