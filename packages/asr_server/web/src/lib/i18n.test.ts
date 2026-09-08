import { test } from 'node:test';
import assert from 'node:assert/strict';
import { LANGS, SOURCE, detect, initialLanguage, isRtl, matchTag, t } from './i18n.ts';
import { dictionaries, source } from '../i18n/index.ts';

const placeholders = (value: string) => [...value.matchAll(/\{(\w+)\}/g)].map(m => m[1]).sort();

test('browser tags map to site languages, splitting Chinese by script and folding Portuguese', () => {
  assert.equal(matchTag('zh-TW'), 'zh-HK');
  assert.equal(matchTag('zh-Hant-HK'), 'zh-HK');
  assert.equal(matchTag('zh'), 'zh-CN');
  assert.equal(matchTag('zh-Hans-SG'), 'zh-CN');
  assert.equal(matchTag('pt-PT'), 'pt-BR');
  assert.equal(matchTag('en-GB'), 'en');
  assert.equal(matchTag('EN'), 'en');
  for (const tag of ['', null, undefined, 'sw', 'x-klingon']) assert.equal(matchTag(tag), null);
});

test('detection takes the first supported Accept-Language entry and falls back to English', () => {
  assert.equal(detect(['sw', 'ja-JP', 'en']), 'ja');
  assert.equal(detect(['sw', 'x-klingon']), 'en');
  assert.equal(detect([]), 'en');
});

test('an explicit ?lang= beats the remembered choice, which beats the browser', () => {
  assert.equal(initialLanguage('?lang=ko', 'de', ['fr']), 'ko');
  assert.equal(initialLanguage('', 'de', ['fr']), 'de');
  assert.equal(initialLanguage('', null, ['fr-CA']), 'fr');
  // Junk in either place must not win over the next source, and never produces an unsupported code.
  assert.equal(initialLanguage('?lang=x-klingon', 'sw', ['ru']), 'ru');
});

test('every listed language has a dictionary, and no dictionary is unlisted', () => {
  assert.deepEqual(LANGS.map(([code]) => code).sort(), Object.keys(dictionaries).sort());
  assert.ok(LANGS.some(([code]) => code === SOURCE));
  assert.equal(new Set(LANGS.map(([, name]) => name)).size, LANGS.length);
});

test('translations keep the source key set and the same placeholders', () => {
  const keys = Object.keys(source).sort();
  for (const [code, dict] of Object.entries(dictionaries)) {
    assert.deepEqual(Object.keys(dict).sort(), keys, code + ' key set');
    for (const key of keys as (keyof typeof source)[]) {
      assert.ok(dict[key].trim(), `${code}: ${key} is empty`);
      assert.deepEqual(placeholders(dict[key]), placeholders(source[key]), `${code}: ${key} placeholders`);
    }
  }
});

test('Arabic is the only right-to-left language', () => {
  assert.deepEqual(LANGS.map(([code]) => code).filter(isRtl), ['ar']);
});

test('an untouched store answers in the source language and fills placeholders', () => {
  assert.equal(t('nav.brand'), 'Fushi');
  assert.equal(t('result.seconds', { value: '1.25' }), '1.25 秒');
  // An unsupplied placeholder stays visible rather than turning into "undefined".
  assert.equal(t('status.phase', { name: 'Apple' }), 'Apple：{phase}');
});
