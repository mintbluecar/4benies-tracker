# 4benies Tracker

Keeps a history of changes to public Spotify playlists and shows it on a small website. A GitHub Actions job checks each playlist every hour and commits a snapshot only when something changed.

No API keys or authentication required. Tracks come from Spotify's public embed page, and the description from the public playlist page.

## What counts as a change

A new snapshot is written when any of these differ from the latest snapshot:

- the track list, including order and each track's name, artists and duration
- the playlist name
- the description, including it being removed
- the cover image, compared by image ID, so Spotify moving the same image to another CDN host doesn't count

Two safety rules:

- If the description page can't be read, the previous description is kept rather than recorded as removed.
- If a playlist that had tracks suddenly scrapes as empty, the run skips it and shows a warning, since that's almost always a bad scrape. To record a playlist that really was emptied, run with `ALLOW_EMPTY=1`.

## Setup

1. Fork or clone this repo.
2. Go to **Settings > Actions > General** and make sure Actions are enabled.
3. The workflow runs every hour at :13 past (UTC). You can also start it from the **Actions** tab.

If one playlist fails to fetch, the others are still recorded and the run is marked as failed so you notice.

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

- `id`: the string after `/playlist/` in a Spotify URL.
- `owner_url`: optional. If set, the owner name on the site links to this URL.

The playlist's display name is scraped from Spotify at snapshot time, so there's no need to put it in the config.

## Website

`index.html` is a static page (no build step) that reads `snapshots/`. It's deployed on Vercel; `vercel.json` only sets the permissions the embedded Spotify player needs.

On the page you can pick a day on the calendar, step through days with changes using **Jump to previous change** / **Jump to next change**, and turn on **diff** to highlight tracks that were added, removed or moved.

To view it locally:

```bash
python3 -m http.server 8091
# then open http://localhost:8091
```

## Snapshot Format

Snapshots are stored in `snapshots/<playlist-id>/YYYY-MM-DDTHHMMSSZ.json` (UTC). `snapshots/index.json` lists them for the website.

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
      "artists": ["Artist A, Artist B"],
      "spotify_url": "https://open.spotify.com/track/...",
      "duration_ms": 210000
    }
  ]
}
```

`artists` is a list with a single string. Spotify's embed page only gives the artists as one comma-separated line, and it's stored as-is so old and new snapshots stay comparable.

## Running Locally

```bash
bash scripts/snapshot.sh
```

## Tests

```bash
bash tests/snapshot.test.sh   # scraper, against fixture pages (needs jq, python3)
node --test tests/            # diff logic used by the website
```
