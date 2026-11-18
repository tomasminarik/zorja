// The Now screen's words for a forecast: a port of the app's `ScreenWords.kind` and
// `ScreenWords.words(for:)` (ios/Zorja/Presentation/ScreenState.swift) and the place line
// from docs/copy.md ("What Zorja forecasts"). Keep in step with the app.

const HOUR = 3600 * 1000;

function clockFor(timeZone) {
  const time = new Intl.DateTimeFormat('en-GB', { hour: '2-digit', minute: '2-digit', hourCycle: 'h23', timeZone });
  const weekday = new Intl.DateTimeFormat('en-GB', { weekday: 'long', timeZone });
  return { time: (d) => time.format(d), weekday: (d) => weekday.format(d) };
}

const at = (s) => new Date(s);
const iv = (i) => ({ start: at(i.start), end: at(i.end) });
const phrase = (text, emphasis) => ({ text, emphasis });

export function nowWords(f, now = new Date()) {
  const clock = clockFor(f.location.timezone);
  const a = f.now;
  const blockers = a.reasons.filter((r) => r.effect === 'blocker').map((r) => r.code);
  const limitations = new Set(a.reasons.filter((r) => r.effect === 'limitation').map((r) => r.code));
  const tonight = f.planning?.[0] ?? null;
  const upcoming = f.upcoming ? { ...iv(f.upcoming.interval), searchLimited: f.upcoming.endIsSearchLimited } : null;

  const segments = (night) => (night?.windows ?? []).flatMap((w) => w.segments.map((s) => ({ s, w })));
  const clearRuns = (night) => {
    const runs = [];
    for (const { s, w } of segments(night)) {
      if (s.factors.weather !== 'favorable') continue;
      const si = iv(s.interval);
      const limited = w.endIsSearchLimited && si.end >= at(w.interval.end);
      const last = runs[runs.length - 1];
      if (last && +last.end === +si.start) { last.end = si.end; last.searchLimited = limited; }
      else runs.push({ start: si.start, end: si.end, searchLimited: limited });
    }
    return runs;
  };
  const bestRun = (night) => clearRuns(night).find((r) => r.end > now) ?? null;
  const windowText = (start, end, searchLimited) => {
    if (start <= now) return { text: `Until ${clock.time(end)}`, emphasis: clock.time(end) };
    if (searchLimited) return { text: `From ${clock.time(start)}`, emphasis: clock.time(start) };
    const r = `${clock.time(start)}–${clock.time(end)}`;
    return { text: r, emphasis: r };
  };
  const bestWindow = (night) => { const r = bestRun(night); return r ? windowText(r.start, r.end, r.searchLimited) : null; };
  const clearTime = (night) => segments(night).filter(({ s }) => s.factors.weather === 'favorable')
    .reduce((t, { s }) => t + (at(s.interval.end) - at(s.interval.start)), 0);
  const clearerNight = () => {
    const base = tonight ? clearTime(tonight) : 0;
    const n = (f.planning ?? []).slice(1).find((p) => clearTime(p) > base);
    return n ? clock.weekday(at(n.period.start)) : null;
  };
  const darkNight = () => {
    const n = (f.planning ?? []).slice(1).find((p) => p.darknessStatus === 'windows_available' && p.windows.length);
    return n ? clock.weekday(at(n.period.start)) : null;
  };
  const darkensTonight = () => {
    if (!upcoming) return false;
    if (!tonight) return true;
    return upcoming.start < at(tonight.period.end);
  };
  const isPolarNight = () => upcoming && upcoming.start <= now && now < upcoming.end && upcoming.searchLimited
    && upcoming.end - upcoming.start >= 24 * HOUR;
  const unknownActivity = new Set(['unknown', 'unavailable', 'not_covered', 'missing']);

  let kind;
  switch (a.action) {
    case 'try_now': kind = isPolarNight() ? 'polarNight' : 'go'; break;
    case 'wait':
      if (blockers[0] === 'cloud_obstruction') kind = 'wait';
      else if (blockers[0] === 'daylight') kind = darkensTonight() ? 'daytime' : 'tooBrightTonight';
      else if (blockers[0] === 'twilight_too_bright') kind = darkensTonight() ? 'twilight' : 'tooBrightTonight';
      else kind = 'cantCheck';
      break;
    case 'skip':
      if (blockers.includes('no_darkness_within_horizon') || f.upcomingStatus === 'no_darkness_within_horizon') kind = 'midnightSun';
      else if (blockers[0] === 'cloud_obstruction') kind = 'skip';
      else if (blockers[0] === 'low_activity') kind = 'quiet';
      else if (blockers[0] === 'daylight' || blockers[0] === 'twilight_too_bright') {
        kind = darkensTonight() && blockers.includes('cloud_obstruction') ? 'skip' : 'tooBrightTonight';
      } else kind = 'cantCheck';
      break;
    default:
      if (limitations.has('source_stale') || blockers.includes('source_stale')) kind = 'outOfDate';
      else if (limitations.has('weather_missing') || a.factors.weather === 'missing') kind = 'weatherUnknown';
      else if (limitations.has('activity_not_covered') || unknownActivity.has(a.factors.activity)) kind = 'auroraUnknown';
      else if (limitations.has('source_unavailable')) kind = 'cantCheck';
      else if (a.rating === 'limited') kind = 'partlyCloudy';
      else kind = 'cantCheck';
  }

  const group = f.auroraReach?.group ?? null;
  const tb = bestWindow(tonight);
  const tonightBest = tb ? phrase(`Tonight Best ${tb.text}.`, tb.emphasis) : null;
  const goLead = a.activeSince
    ? `Dark, clear and aurora active overhead since ${a.activeSinceIsBufferLimited ? 'at least ' : ''}${clock.time(at(a.activeSince))}.`
    : 'Dark, clear and aurora active overhead.';
  const lookUp = phrase('Look Up And Check.', 'Look Up');

  let w;
  switch (kind) {
    case 'go': w = [phrase('Go Out Right Now.', 'Right Now'), goLead, tonightBest]; break;
    case 'polarNight': {
      const run = clearRuns(tonight).find((r) => r.start <= now && now < r.end);
      const until = run ? clock.time(run.end) : null;
      w = [phrase('Go Out Right Now.', 'Right Now'),
        until ? `It’s polar night, dark all day. Clear until ${until}, aurora active.` : 'It’s polar night, dark all day. Aurora active.',
        until ? phrase(`Today Best Until ${until}.`, until) : null];
      break;
    }
    case 'wait': {
      const best = bestRun(tonight);
      const clears = best ? clock.time(best.start) : null;
      const dark = best ? tonight?.windows.find((x) => at(x.interval.start) <= best.start && best.start < at(x.interval.end)) : null;
      const isLast = dark && tonight.windows[tonight.windows.length - 1] === dark;
      const stays = dark && !isLast ? `and it stays dark until ${clock.time(at(dark.interval.end))}.` : 'and it stays dark all night.';
      w = [clears ? phrase(`Wait Until ${clears}.`, clears) : phrase('Wait.', 'Wait'),
        clears ? `Cloud clears around ${clears}, ${stays}` : 'Cloud clears later tonight.', tonightBest];
      break;
    }
    case 'daytime': {
      const dark = upcoming ? clock.time(upcoming.start) : null;
      w = [dark ? phrase(`Too Bright Until ${dark}.`, dark) : phrase('Too Bright Now.', 'Now'),
        f.upcomingActivityInstant?.activity === 'supported'
          ? 'Aurora is active, but daylight hides it. Tonight is checked on its own.'
          : 'Daylight hides any aurora. Tonight is checked on its own.', tonightBest];
      break;
    }
    case 'twilight': {
      const dark = upcoming ? clock.time(upcoming.start) : null;
      w = [dark ? phrase(`Dark Enough At ${dark}.`, dark) : phrase('Too Bright Now.', 'Now'),
        'It’s twilight now, still too bright for faint aurora.', tonightBest];
      break;
    }
    case 'skip': {
      const day = clearerNight();
      w = [phrase('Skip Tonight.', 'Skip'), 'Thick cloud all night, whatever the aurora does.',
        day ? phrase(`${day} Looks Clearer.`, day) : phrase('Next 3 Nights Look Cloudy.', 'Look Cloudy')];
      break;
    }
    case 'quiet': {
      let bottom = null;
      if (tb) bottom = phrase(`Tonight Clear ${tb.text}.`, tb.emphasis);
      else {
        const ended = clearRuns(tonight).filter((r) => r.end <= now).pop();
        if (ended) bottom = phrase(`Tonight Cloudy After ${clock.time(ended.end)}.`, clock.time(ended.end));
      }
      w = [phrase('Quiet Right Now.', 'Right Now'), group === 'under_zone' || group === 'edge'
        ? 'Dark and clear, but there’s little aurora overhead. It often picks up here.'
        : 'Dark and clear, but there’s little aurora overhead. It can pick up quickly.', bottom];
      break;
    }
    case 'midnightSun':
      w = [phrase('Too Bright All Night.', 'All Night'), 'The sun stays too high here for aurora to show.',
        phrase('Next 3 Nights No Darkness.', 'No Darkness')];
      break;
    case 'tooBrightTonight': {
      const day = darkNight();
      w = [phrase('Too Bright Tonight.', 'Tonight'), 'It doesn’t get dark enough here tonight.', day ? phrase(`${day} Gets Dark.`, day) : null];
      break;
    }
    case 'partlyCloudy': {
      const ws = tonight?.windows ?? [];
      const dw = ws.length ? windowText(at(ws[0].interval.start), at(ws[ws.length - 1].interval.end), ws[ws.length - 1].endIsSearchLimited) : null;
      w = [phrase('Partly Cloudy.', 'Cloudy'), 'It’s dark and aurora is active, but cloud comes and goes. Watch for gaps.',
        dw ? phrase(`Tonight Dark ${dw.text}.`, dw.emphasis) : null];
      break;
    }
    case 'weatherUnknown':
      w = [phrase('Clouds Not Known.', 'Not Known'), 'It’s dark and aurora is active, but there’s no cloud forecast right now.', lookUp];
      break;
    case 'auroraUnknown':
      w = [phrase('Aurora Not Known.', 'Not Known'), 'It’s dark and clear, but there’s no live aurora data for here right now.', lookUp];
      break;
    case 'outOfDate': {
      const ids = new Set(a.reasons.filter((r) => r.code === 'source_stale' && r.sourceId).map((r) => r.sourceId));
      const issued = f.sources.filter((s) => ids.has(s.id) && s.status === 'stale' && s.issuedAt).map((s) => at(s.issuedAt));
      const since = clock.time(issued.length ? new Date(Math.max(...issued)) : at(f.generatedAt));
      w = [phrase(`Out Of Date Since ${since}.`, since), 'Zorja can’t get fresh data right now. Don’t rely on the last forecast.', null];
      break;
    }
    default:
      w = [phrase('Can’t Check Right Now.', 'Right Now'), 'Some of the data Zorja needs isn’t available. It tries again soon.', null];
  }
  return { kind, headline: w[0], lead: w[1], bottom: w[2], updated: clock.time(at(f.generatedAt)) };
}

/** Tonight's place line (docs/copy.md, "What Zorja forecasts", approved 2026-11-12). */
export function placeLine(f, place) {
  const group = f.auroraReach?.group;
  const outlook = f.planning?.[0]?.auroraOutlook?.status;
  if (group === 'under_zone') return `In ${place}, aurora shows overhead on most clear, dark nights.`;
  if (group === 'edge') return `In ${place}, aurora often shows low in the northern sky, and overhead on active nights.`;
  if (group === 'south') {
    if (outlook === 'could_reach') return 'A storm forecast tonight could bring aurora this far south.';
    if (outlook === 'not_expected') return 'No storm is forecast to reach here tonight. Aurora can still come without warning.';
    return 'Tonight’s storm forecast isn’t known yet.';
  }
  return null;
}
