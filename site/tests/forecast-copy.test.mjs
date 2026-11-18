// The site's Now words must match the app's (ios/ZorjaTests/ScreenStateTests.swift).
// Run: node --test site/tests/*.test.mjs
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { nowWords, placeLine } from '../assets/js/forecast-copy.js';

const load = (name) => JSON.parse(readFileSync(new URL(`../../api/examples/${name}.json`, import.meta.url)));

const expected = [
  ['promising-now', 'Go Out Right Now.', 'Tonight Best Until 05:52.'],
  ['south-could-reach', 'Go Out Right Now.', 'Tonight Best Until 06:19.'],
  ['south-not-expected', 'Go Out Right Now.', 'Tonight Best Until 06:19.'],
  ['partial-third-night', 'Go Out Right Now.', 'Tonight Best Until 05:52.'],
  ['after-midnight-current-night', 'Go Out Right Now.', 'Tonight Best Until 05:52.'],
  ['disjoint-darkness', 'Go Out Right Now.', 'Tonight Best Until 07:45.'],
  ['polar-night', 'Go Out Right Now.', 'Today Best Until 12:00.'],
  ['daylight-next-window', 'Too Bright Until 19:17.', 'Tonight Best 19:17–05:52.'],
  ['morning-finished-night', 'Too Bright Until 19:14.', 'Tonight Best 19:14–05:54.'],
  ['cloud-blocked', 'Skip Tonight.', 'Next 3 Nights Look Cloudy.'],
  ['midnight-sun', 'Too Bright All Night.', 'Next 3 Nights No Darkness.'],
  ['too-bright-tonight', 'Too Bright Tonight.', 'Tuesday Gets Dark.'],
  ['limited-clouds', 'Partly Cloudy.', 'Tonight Dark Until 05:52.'],
  ['low-activity', 'Aurora Not Known.', 'Look Up And Check.'],
  ['weather-missing', 'Clouds Not Known.', 'Look Up And Check.'],
  ['stale-aurora', 'Out Of Date Since 22:10.', null],
  ['stale-weather', 'Out Of Date Since 16:00.', null],
  ['weather-unavailable', 'Can’t Check Right Now.', null],
];

for (const [name, headline, bottom] of expected) {
  test(`${name}: ${headline}`, () => {
    const f = load(name);
    const w = nowWords(f, new Date(f.generatedAt));
    assert.equal(w.headline.text, headline);
    assert.equal(w.bottom?.text ?? null, bottom);
    if (w.headline.emphasis) assert.ok(w.headline.text.includes(w.headline.emphasis));
  });
}

test('place lines follow the aurora group and tonight’s outlook', () => {
  assert.equal(placeLine(load('promising-now'), 'Stockholm'),
    'In Stockholm, aurora often shows low in the northern sky, and overhead on active nights.');
  assert.equal(placeLine(load('south-could-reach'), 'Edinburgh'), 'A storm forecast tonight could bring aurora this far south.');
  assert.equal(placeLine(load('south-not-expected'), 'Edinburgh'),
    'No storm is forecast to reach here tonight. Aurora can still come without warning.');
});
