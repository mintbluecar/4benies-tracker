// Run with: node --test tests/
const test = require('node:test');
const assert = require('node:assert/strict');
const { coverId, computeDiff, findMovedTracks } = require('../diff.js');

const tracks = (ids) => [...ids].map(id => ({ spotify_url: `https://open.spotify.com/track/${id}` }));
const moved = (from, to) => [...findMovedTracks(tracks(from), tracks(to))].map(u => u.split('/').pop()).sort().join('');

test('findMovedTracks: unchanged order moves nothing', () => {
  assert.equal(moved('abcde', 'abcde'), '');
});

test('findMovedTracks: one track moved to the top counts once', () => {
  assert.equal(moved('abcde', 'eabcd'), 'e');
});

test('findMovedTracks: a swap of two tracks counts both', () => {
  assert.equal(moved('abcde', 'adcbe').length, 2);
});

test('findMovedTracks: full reversal keeps one track in place', () => {
  assert.equal(moved('abcd', 'dcba').length, 3);
});

test('findMovedTracks: added and removed tracks are not counted as moved', () => {
  assert.equal(moved('abc', 'xacy'), '');
  assert.equal(moved('abc', ''), '');
});

test('computeDiff: reports added, removed and moved', () => {
  const d = computeDiff({ tracks: tracks('cbx') }, { tracks: tracks('abc') });
  assert.deepEqual([...d.added], ['https://open.spotify.com/track/x']);
  assert.deepEqual(d.removedTracks.map(t => t.spotify_url), ['https://open.spotify.com/track/a']);
  assert.equal(d.moved.size, 1);
  assert.equal(d.hasDiff, true);
});

test('computeDiff: reorder-only change still counts as a diff', () => {
  assert.equal(computeDiff({ tracks: tracks('ba') }, { tracks: tracks('ab') }).hasDiff, true);
});

test('computeDiff: identical lists and a missing base have no diff', () => {
  assert.equal(computeDiff({ tracks: tracks('ab') }, { tracks: tracks('ab') }).hasDiff, false);
  assert.equal(computeDiff({ tracks: tracks('ab') }, null).hasDiff, false);
});

test('coverId: ignores CDN host and size prefix, like the scraper', () => {
  const id = 'aaaaaaaaaaaaaaaaaaaaaaaa';
  assert.equal(
    coverId(`https://image-cdn-fa.spotifycdn.com/image/ab67706c0000da84${id}`),
    coverId(`https://image-cdn-ak.spotifycdn.com/image/ab67706c0000d72c${id}`),
  );
  assert.equal(coverId(`https://x/image/ab67706c0000da84${id}`), id);
  assert.equal(coverId(null), null);
});
