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
  {
    "id": "1FvNFiqtjKeUTMvE0eIFNf",
    "owner_url": "https://open.spotify.com/user/USERNAME"
  }
]
```

- `id` — the string after `/playlist/` in a Spotify URL.
- `owner_url` — optional. If set, the owner name in the header links to this URL.

The playlist's display name is scraped from Spotify (`.title`) at snapshot time, so no need to duplicate it in config.

## Snapshot Format

Snapshots are stored in `snapshots/<playlist-id>/YYYY-MM-DDTHHMMSSZ.json` (UTC timestamp). A new file is only written when the track list differs from the most recent snapshot for that playlist.

Each snapshot contains:

```json
{
  "playlist_id": "...",
  "playlist_name": "...",
  "snapshot_date": "2026-08-26",
  "snapshot_time": "2026-08-26T12:00:00Z",
  "track_count": 3,
  "cover_art": "https://image-cdn-fa.spotifycdn.com/image/...",
  "owner": "username",
  "description": "playlist description or null",
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
