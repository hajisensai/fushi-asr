import { test } from 'node:test';
import assert from 'node:assert/strict';
import { fileError } from './files.ts';
const file = (name: string, size = 100, type = '') => ({ name, size, type });
test('EPUB accepts case-insensitive extension and rejects wrong, empty, multiple, oversize', () => {
  assert.equal(fileError([file('book.EPUB')], 'epub'), null);
  for (const input of [[file('audio.wav')], [file('book.epub', 0)], [file('book.epub'), file('other.epub')], [file('book.epub', 64 * 1024 ** 2 + 1)]]) assert.ok(fileError(input, 'epub'));
});
test('audio accepts common audiobook extensions without MIME, rejects epub or oversized', () => {
  for (const name of ['book.m4b', 'clip.WAV', 'clip.opus', 'clip.flac']) assert.equal(fileError([file(name)], 'audio'), null);
  assert.equal(fileError([file('clip', 100, 'audio/mpeg')], 'audio'), null);
  assert.ok(fileError([file('book.epub')], 'audio'));
  assert.ok(fileError([file('huge.m4b', 4 * 1024 ** 3 + 1)], 'audio'));
});
test('retiming accepts SRT and WebVTT, rejecting wrong, empty, multiple, and oversized files', () => {
  for (const name of ['old.SRT', 'subtitle.vtt']) assert.equal(fileError([file(name)], 'subtitle'), null);
  assert.equal(fileError([file('subtitle.srt', 8 * 1024 ** 2)], 'subtitle'), null);
  for (const input of [[file('subtitle.ass')], [file('video.mp4')], [file('subtitle.srt', 0)], [file('subtitle.srt'), file('other.vtt')], [file('subtitle.vtt', 8 * 1024 ** 2 + 1)]]) assert.ok(fileError(input, 'subtitle'));
});
