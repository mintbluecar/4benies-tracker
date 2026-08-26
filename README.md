# 4benies Tracker

Tracks daily changes to public Spotify playlists. A GitHub Actions cron job snapshots each playlist's tracks and commits a JSON file only when the track list changes.

## Setup

### 1. Create a Spotify App

1. Go to [Spotify Developer Dashboard](https://developer.spotify.com/dashboard)
2. Click **Create App**
3. Set the **Redirect URI** to `https://127.0.0.1` (required by Spotify but unused by this app)
4. Save the app and copy the **Client ID** and **Client Secret**

### 2. Add GitHub Secrets

In your repo: **Settings > Secrets and variables > Actions > New repository secret**

- `SPOTIFY_CLIENT_ID` — your Spotify app's Client ID
- `SPOTIFY_CLIENT_SECRET` — your Spotify app's Client Secret

### 3. Enable Actions

Go to **Settings > Actions > General** and ensure Actions are enabled.

The workflow runs daily at noon UTC. You can also trigger it manually from the **Actions** tab.

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
  "track_count": 42,
  "tracks": [
    {
      "name": "Song Title",
      "artists": ["Artist"],
      "album": "Album",
      "added_at": "2026-07-15T12:00:00Z",
      "spotify_url": "https://open.spotify.com/track/...",
      "duration_ms": 210000
    }
  ]
}
```

## Running Locally

```bash
export SPOTIFY_CLIENT_ID="your_client_id"
export SPOTIFY_CLIENT_SECRET="your_client_secret"
bash scripts/snapshot.sh
```
