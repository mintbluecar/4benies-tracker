// Pure snapshot-comparison logic, shared by index.html and tests/diff.test.js.

// Mirrors normalize_cover_id in scripts/snapshot.sh so CDN host/size changes
// for the same image don't count as a new cover.
function coverId(url) {
  if (!url) return null;
  const id = url.replace(/.*\/image\//, '');
  return /^[a-f0-9]+$/.test(id) ? id.slice(-24) : id;
}

function computeDiff(snap, baseSnap) {
  if (!baseSnap) return { added: new Set(), removedTracks: [], moved: new Set(), hasDiff: false };
  const currentUrls = new Set(snap.tracks.map(t => t.spotify_url));
  const baseUrls = new Set(baseSnap.tracks.map(t => t.spotify_url));
  const added = new Set([...currentUrls].filter(u => !baseUrls.has(u)));
  const removedTracks = baseSnap.tracks.filter(t => !currentUrls.has(t.spotify_url));
  const moved = findMovedTracks(baseSnap.tracks, snap.tracks);
  return {
    added, removedTracks, moved,
    hasDiff: added.size > 0 || removedTracks.length > 0 || moved.size > 0,
  };
}

// Smallest set of tracks whose moves explain the new order: everything kept
// in the longest run that's still in the old relative order counts as unmoved.
function findMovedTracks(baseTracks, tracks) {
  const baseIndex = new Map();
  baseTracks.forEach((t, i) => { if (!baseIndex.has(t.spotify_url)) baseIndex.set(t.spotify_url, i); });
  const common = tracks.map(t => t.spotify_url).filter(u => baseIndex.has(u));
  const seq = common.map(u => baseIndex.get(u));

  const tails = [], tailIdx = [], prev = [];
  seq.forEach((v, i) => {
    let lo = 0, hi = tails.length;
    while (lo < hi) { const mid = (lo + hi) >> 1; if (tails[mid] < v) lo = mid + 1; else hi = mid; }
    prev[i] = lo > 0 ? tailIdx[lo - 1] : -1;
    tails[lo] = v;
    tailIdx[lo] = i;
  });
  const keep = new Set();
  for (let k = tails.length ? tailIdx[tails.length - 1] : -1; k >= 0; k = prev[k]) keep.add(k);
  return new Set(common.filter((_, i) => !keep.has(i)));
}

if (typeof module !== 'undefined') module.exports = { coverId, computeDiff, findMovedTracks };
