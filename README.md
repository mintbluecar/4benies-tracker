# 4benies Tracker

Tracks daily changes to public Spotify playlists. A GitHub Actions cron job snapshots each playlist's tracks and commits a JSON file only when the track list changes.

No API keys or authentication required — uses Spotify's public embed endpoint.

## Setup

1. Fork or clone this repo
2. Go to **Settings > Actions > General** and ensure Actions are enabled
3. The workflow runs daily at noon UTC. Trigger it manually from the **Actions** tab.

## Adding Playlists

Edit `playlists.json`:

```json
[
  { "id": "1FvNFiqtjKeUTMvE0eIFNf", "name": "4benies" },
  { "id": "ANOTHER_PLAYLIST_ID", "name": "another playlist" }
]
```

The playlist ID is the string after `/playlist/` in a Spotify URL.

## Snapshot Format

Snapshots are stored in `snapshots/<playlist-id>/YYYY-MM-DD.json`. A new file is only written when the track list differs from the previous snapshot.

Each snapshot contains:

```json
{
  "playlist_id": "...",
  "playlist_name": "...",
  "snapshot_date": "2026-08-26",
  "track_count": 3,
  "tracks": [
    {
      "name": "Song Title",
      "artists": ["Artist"],
      "spotify_url": "https://open.spotify.com/track/...",
      "duration_ms": 210000
    }
  ]
}
```

## Running Locally

```bash
bash scripts/snapshot.sh
```
