# X Post Notifications for Playlist Changes

**Date:** 2026-09-22
**Status:** Draft — awaiting review

## Goal

When the hourly snapshot detects a change in a tracked playlist, post a
raw, human-readable summary of the change to a public X account so
followers see the update in their feed. Snapshotting itself is
unchanged — this is a fanout side effect on top of the existing
pipeline.

## Non-goals

- No LLM-composed prose. Post copy is deterministic and templated.
- No link back to the tracker or Spotify. X charges $0.20 per post
  when a link is present vs. $0.015 without; keeping posts text-only
  keeps monthly cost in the single-digit dollars.
- No batching, digesting, or per-day cap. Every detected diff fires
  one post. At current volume (hourly cron × 1 playlist × the
  observed diff rate) the cost ceiling is trivially bounded.
- No retries. A network blip that drops a single fanout is acceptable.
- No thread splitting for very large diffs — a header + truncated
  list + "…and N more" is enough.

## Context

The existing snapshot pipeline
(`scripts/snapshot.sh` + `.github/workflows/snapshot.yml`) runs
hourly. For each playlist in `playlists.json`, it fetches the current
state from Spotify's embed page, computes a signature over
`{playlist_name, description, cover_art_id, tracks}`, compares to the
newest on-disk snapshot, and writes a new snapshot file only if the
signature differs. When any playlist writes a snapshot, the workflow
commits and pushes.

`scripts/snapshot.sh` already knows, at the "Changes detected" branch,
both the new signature and the previous snapshot file. That is the
point where a post can be composed and fired with no additional
fetching or state.

X API v2 as of 2026 is pay-per-use for new developers:
- $0.015 per text-only post
- $0.20 per post if the post body contains a link
- Legacy Basic/Pro tiers are being force-migrated to pay-per-use
- No free tier for new signups

## Design

### Trigger point

Inside `scripts/snapshot.sh`, in the branch entered when
`has_changed` returns true, immediately after writing the new snapshot
file. At this point in the code, these variables are already in
scope: `scraped_name`, the new snapshot JSON on disk, and the path to
the previous snapshot (obtainable via `latest_snapshot_file` called
before the write).

Insertion is a single call:
`post_change_to_x "$prev_snapshot_file" "$new_snapshot_file"`.
The function is fully responsible for: computing the diff, formatting
the post, and calling the X API. Errors are caught inside the
function; the caller does not branch on its exit status.

### Diff computation

New bash function `compute_diff(prev_file, new_file)` emits a JSON
object with the shape:

```json
{
  "playlist_name": "4 Benies",
  "name_changed": {"from": "...", "to": "..."} | null,
  "description_changed": true | false,
  "cover_changed": true | false,
  "added": [{"name": "...", "artist": "..."}, ...],
  "removed": [{"name": "...", "artist": "..."}, ...]
}
```

Track comparison keys off `spotify_url` — it's stable across the
scrape and identifies the track independent of position. Reorders
alone do not populate `added`/`removed` (a pure reorder still
triggers a snapshot via the signature, but the diff summary treats
it as no track change; see "Reorder handling" below).

If `prev_file` is empty (first snapshot ever for this playlist), the
function emits an object with all tracks in `added`. The formatter
below treats this as a normal add-heavy diff.

### Post formatting

New bash function `format_post(diff_json)` emits a single string
capped at 280 UTF-8 characters. Rules, applied in order:

1. **Header line**, always:
   - If `added` or `removed` is non-empty: `🎵 <playlist_name> updated`
   - Else if only `name_changed`: `🎵 <old_name> renamed to <new_name>`
   - Else if only `description_changed`: `🎵 <playlist_name> description updated`
   - Else if only `cover_changed`: `🎵 <playlist_name> cover art updated`
   - If multiple metadata-only flags with no track changes: fall back to
     `🎵 <playlist_name> updated` (rare; keeps the rule simple).

2. **Track lines**, when there are track changes:
   - Up to 3 additions, each: `+ <artist> — <name>`
   - Up to 3 removals, each: `− <artist> — <name>` (uses U+2212 minus, not hyphen)
   - Order: adds first, then removes.

3. **Overflow line**, when total changes (adds + removes) exceed the
   6 shown: `…and N more changes` where N is the untold count.

4. **Length guard**: if the assembled string exceeds 280 chars, drop
   track lines from the tail (last remove first, then last add, and so
   on) and replace with the overflow line recomputed. The header line
   is never dropped.

Empty diff (nothing changed) is impossible here — this function is
only called on the `has_changed` true branch — so no empty-string
return case is defined.

### Reorder handling

A pure reorder passes `has_changed` (signature includes track order)
but `compute_diff` produces empty `added` and `removed`, no
`*_changed` flags, and an unchanged `playlist_name`. `format_post`
would find nothing to put in the header. Rather than post a confusing
"updated with no shown change" tweet, `post_change_to_x` treats this
as no-op: it logs "reorder-only change; not posting" and returns
success. This is the one case where a detected snapshot change does
not produce a post.

### Posting

New bash function `post_to_x(text)`:

- Reads env vars: `X_API_KEY`, `X_API_SECRET`, `X_ACCESS_TOKEN`,
  `X_ACCESS_SECRET`. If any is empty, log "X credentials not set;
  skipping post" and return success (this makes local runs of
  `snapshot.sh` outside CI harmless).
- If `X_DRY_RUN=1`, echo the text prefixed with `[DRY RUN]` to stdout
  and return success. This is how we test formatting end-to-end
  without hitting the paid API.
- Otherwise, POST to `https://api.x.com/2/tweets` with
  `{"text": "<text>"}` as the JSON body, signed with OAuth 1.0a
  User Context using the 4 credentials.
- On non-2xx response, log the status code and response body as a
  warning; return success anyway. The snapshot commit has already
  happened; failing the workflow over a fanout error would cause
  legitimate snapshots to appear unpushed on the next run.

OAuth 1.0a signing in bash is implemented with `openssl` for HMAC-SHA1
and standard tooling for URL encoding. A reference implementation
lives in the plan as pseudocode; the real implementation belongs in
the plan document.

### Workflow wiring

`.github/workflows/snapshot.yml`, in the "Take snapshot" step, add:

```yaml
env:
  X_API_KEY: ${{ secrets.X_API_KEY }}
  X_API_SECRET: ${{ secrets.X_API_SECRET }}
  X_ACCESS_TOKEN: ${{ secrets.X_ACCESS_TOKEN }}
  X_ACCESS_SECRET: ${{ secrets.X_ACCESS_SECRET }}
```

No new step, no new job. If a repo variable `X_DRY_RUN` is set to
`1`, the workflow forwards it too — useful for a smoke test in CI.

### Error handling summary

| Failure | Behavior |
|---|---|
| Credentials env vars unset | Skip post; log; exit 0. Local dev safe. |
| `X_DRY_RUN=1` | Print `[DRY RUN] <text>`; exit 0. |
| Reorder-only diff | Skip post; log; exit 0. |
| Diff computation returns empty JSON | Impossible by construction; if it happens, log a warning and skip. |
| HTTP non-2xx from X | Log status + body as warning; exit 0. |
| Network timeout | curl exits non-zero; capture, log, exit 0. |

Every failure mode is non-fatal to the snapshot workflow.

## Testing

Two tests, both against `format_post` / `compute_diff` only. The X
POST path is not unit-tested — it's covered manually by one
`X_DRY_RUN=1` local run and one `workflow_dispatch` in CI once
credentials are set.

1. **Golden diff fixture**: check in `tests/fixtures/prev.json` and
   `tests/fixtures/new.json` representing every diff category (add,
   remove, name change, description change, cover change, overflow,
   metadata-only). Run `compute_diff` + `format_post` in a shell
   test script; assert exact string output against a
   `tests/fixtures/expected.txt` file. This locks the format.

2. **Reorder-only fixture**: same tracks, different order.
   `compute_diff` output must have empty `added` and `removed`.
   `format_post` is not called in this case; `post_change_to_x`
   returns early. Assert the log line.

Test runner is a new `scripts/test.sh` invoked manually and from a new
"Tests" CI workflow that runs on push to a branch. Not required to
pass before land — this is a personal tracker, not production — but
must be green before merging the notification change.

## Prerequisites (out of band)

Not code, but the plan cannot ship without these:

1. Create an X developer app on pay-per-use. Verify billing is
   attached — an unbilled account silently 401s.
2. Generate OAuth 1.0a User Context credentials (API key/secret,
   access token/secret) for the posting account.
3. Add all four as GitHub Actions secrets in this repo.
4. Do a `workflow_dispatch` with `X_DRY_RUN=1` first to confirm
   formatting; then a real run to confirm live posting.

## Files touched

- `scripts/snapshot.sh` — new functions (`compute_diff`,
  `format_post`, `post_to_x`, `post_change_to_x`); one call site
  inside the "Changes detected" branch.
- `.github/workflows/snapshot.yml` — 4 env vars on the snapshot step.
- `tests/fixtures/*.json`, `tests/fixtures/expected.txt` — new.
- `scripts/test.sh` — new.
- `.github/workflows/test.yml` — new, or extend snapshot.yml with
  a separate job. Plan will decide.

## Open questions

None blocking. Every choice above is made.
