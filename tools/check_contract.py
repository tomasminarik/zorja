"""Check the proposed contract and synthetic examples without dependencies.

This checks the JSON Schema subset used in this contract, not full OpenAPI
conformance. It also checks interval, provenance, and guidance invariants.
"""
import json
from datetime import date, datetime
from pathlib import Path
from urllib.parse import urlparse
from zoneinfo import ZoneInfo

ROOT = Path(__file__).resolve().parents[1]
SPEC = json.loads((ROOT / 'api/openapi.json').read_text())


def resolve(pointer):
    assert pointer.startswith('#/'), pointer
    result = SPEC
    for part in pointer[2:].split('/'):
        result = result[part.replace('~1', '/').replace('~0', '~')]
    return result


def validate(value, schema):
    if '$ref' in schema:
        return validate(value, resolve(schema['$ref']))
    if 'anyOf' in schema:
        for candidate in schema['anyOf']:
            try:
                validate(value, candidate)
                return
            except (AssertionError, ValueError, TypeError):
                pass
        raise AssertionError(f'No nullable branch matches: {value!r}')
    if 'const' in schema:
        assert value == schema['const']
    if 'enum' in schema:
        assert value in schema['enum']
    kind = schema.get('type')
    if kind == 'object':
        assert isinstance(value, dict)
        assert set(schema.get('required', [])) <= value.keys()
        props = schema['properties']
        if schema.get('additionalProperties') is False:
            assert value.keys() <= props.keys()
        for key, item in value.items():
            if key in props:
                validate(item, props[key])
    elif kind == 'array':
        assert isinstance(value, list)
        assert len(value) >= schema.get('minItems', 0)
        assert len(value) <= schema.get('maxItems', float('inf'))
        if schema.get('uniqueItems'):
            assert len({json.dumps(v, sort_keys=True) for v in value}) == len(value)
        for item in value:
            validate(item, schema['items'])
    elif kind == 'string':
        assert isinstance(value, str)
        assert len(value) >= schema.get('minLength', 0)
        if schema.get('format') == 'date-time':
            assert value.endswith('Z')
            datetime.fromisoformat(value.replace('Z', '+00:00'))
        elif schema.get('format') == 'date':
            date.fromisoformat(value)
        elif schema.get('format') == 'uri':
            assert urlparse(value).scheme
    elif kind == 'integer':
        assert isinstance(value, int) and not isinstance(value, bool)
        assert schema.get('minimum', -float('inf')) <= value <= schema.get('maximum', float('inf'))
    elif kind == 'number':
        assert isinstance(value, (int, float)) and not isinstance(value, bool)
        assert schema.get('minimum', -float('inf')) <= value <= schema.get('maximum', float('inf'))
    elif kind == 'boolean':
        assert isinstance(value, bool)
    elif kind == 'null':
        assert value is None


def visit_schema(value):
    if isinstance(value, dict):
        if '$ref' in value:
            resolve(value['$ref'])
        for item in value.values():
            visit_schema(item)
    elif isinstance(value, list):
        for item in value:
            visit_schema(item)


def time(value):
    return datetime.fromisoformat(value.replace('Z', '+00:00'))


def bounds(interval):
    start, end = time(interval['start']), time(interval['end'])
    assert start < end, interval
    return start, end


def check_forecast(f):
    ZoneInfo(f['location']['timezone'])
    assert time(f['generatedAt']) <= time(f['refreshAfter'])
    assert f['now']['interval']['start'] == f['generatedAt']
    assert (f['upcoming'] is not None) == (f['upcomingStatus'] == 'window_available')
    if 'minimumRevalidationIntervalSeconds' in f:
        assert f['minimumRevalidationIntervalSeconds'] >= 60
    sources = {s['id']: s for s in f['sources']}
    assert len(sources) == len(f['sources'])
    instant = f.get('upcomingActivityInstant')
    if instant is not None:
        assert time(instant['forecastAt']) > time(f['generatedAt'])
        assert instant['sourceId'] in sources
        assert sources[instant['sourceId']]['role'] == 'aurora_short_term'
        assert instant['temporalPolicy'] == 'exact-forecast-instant-v1'
        assert sources[instant['sourceId']]['validFrom'] == instant['forecastAt']
        assert sources[instant['sourceId']]['validUntil'] == instant['forecastAt']
        if instant['activity'] == 'supported':
            assert sources[instant['sourceId']]['status'] == 'fresh'
            assert instant['overheadSignal'] is not None
    for s in sources.values():
        if s['fetchedAt']:
            assert time(s['fetchedAt']) <= time(f['generatedAt'])
        if s['validFrom'] and s['validUntil']:
            assert time(s['validFrom']) <= time(s['validUntil'])

    def assessment(a, current=False):
        bounds(a['interval'])
        if 'activityEvidence' in a:
            evidence = a['activityEvidence']
            assert set(evidence['sourceIds']) <= sources.keys()
            if evidence['supportedInterval'] is not None:
                es, ee = bounds(evidence['supportedInterval'])
                assert evidence['sourceIds']
                if evidence['temporalPolicy'] == 'retained-bracket-min-v1':
                    assert len(evidence['forecastInstants']) == len(evidence['sourceIds']) == 2
                    assert [es, ee] == [time(t) for t in evidence['forecastInstants']]
                    assert (ee - es).total_seconds() <= 20 * 60
                    for key, target in zip(evidence['sourceIds'], evidence['forecastInstants']):
                        assert sources[key]['validFrom'] == sources[key]['validUntil'] == target
                if current:
                    assert es <= time(f['generatedAt']) < ee
                    assert time(f['refreshAfter']) <= ee
            if current and a['action'] == 'try_now' and time(f['refreshAfter']) > time(f['generatedAt']):
                assert evidence['supportedInterval'] is not None
        assert all(r.get('sourceId') in sources for r in a['reasons'] if 'sourceId' in r)
        if a['rating'] == 'limited':
            assert a['factors']['activity'] == 'supported'
            assert a['factors']['weather'] == 'mixed'
            assert a['cloudCoverPercent'] is not None and 30 <= a['cloudCoverPercent'] <= 70
            assert not any(r['effect'] == 'blocker' for r in a['reasons'])
        assert set(a['sourceIds']) <= sources.keys()
        if a['action'] == 'try_now':
            assert current and a['rating'] == 'promising' and a['basis'] == 'short_term'
        if a['rating'] == 'promising':
            assert a['cloudCoverPercent'] is not None
            assert a['solarAltitudeDegrees'] is not None and a['solarAltitudeDegrees'] <= -12
            assert a['cloudCoverPercent'] < 30
            assert a['factors']['activity'] == 'supported'
            assert a['factors']['weather'] == 'favorable'
            assert a['factors']['darkness'] in {'astronomical_twilight', 'astronomical_night'}
            assert a['basis'] != 'unavailable'
            assert any(sources[k]['provider'] == 'noaa_swpc' for k in a['sourceIds'])
            assert any(sources[k]['provider'] == 'met_norway' for k in a['sourceIds'])
            assert all(sources[k]['status'] == 'fresh' for k in a['sourceIds'])
            assert not any(r['effect'] == 'blocker' for r in a['reasons'])

    def window(w):
        start, end = bounds(w['interval'])
        cursor = start
        for a in w['segments']:
            seg_start, seg_end = bounds(a['interval'])
            assert seg_start == cursor and seg_end <= end
            assessment(a, seg_start <= time(f['generatedAt']) < seg_end)
            cursor = seg_end
        assert cursor == end

    assessment(f['now'], True)
    if f['upcoming']:
        window(f['upcoming'])
    dates = []
    previous_end = None
    for p in f['planning']:
        start, end = bounds(p['period'])
        local_start = start.astimezone(ZoneInfo(f['location']['timezone']))
        local_end = end.astimezone(ZoneInfo(f['location']['timezone']))
        assert local_start.hour == local_end.hour == 12
        assert p['localDate'] == local_start.date().isoformat()
        if previous_end:
            assert previous_end == start
        previous_end = end
        dates.append(p['localDate'])
        assert p['assessment']['interval'] == p['period']
        if 'globalKpContext' in p:
            context = p['globalKpContext']
            assert context['sourceId'] in sources
            assert sources[context['sourceId']].get('role', 'aurora_planning') == 'aurora_planning'
            if context['status'] == 'unavailable':
                assert not context['bins']
            if context['status'] in {'available', 'partial', 'not_covered'}:
                assert sources[context['sourceId']]['status'] == 'fresh'
            cursor = max(start, time(f['generatedAt']))
            relevant_start = cursor
            for item in context['bins']:
                bs, be = bounds(item['interval'])
                assert 0 <= item['kp'] <= 9
                assert (be - bs).total_seconds() == 3 * 3600
                assert bs < end and be > relevant_start
                if bs <= cursor:
                    cursor = max(cursor, be)
            if context['status'] == 'available':
                assert cursor >= end
            elif context['status'] == 'partial':
                assert context['bins'] and cursor < end
            elif context['status'] == 'not_covered':
                assert not context['bins']
        assert p['assessment']['action'] != 'try_now'
        assessment(p['assessment'])
        assert bool(p['windows']) == (p['darknessStatus'] == 'windows_available')
        window_end = None
        for item in p['windows']:
            window(item)
            ws, we = bounds(item['interval'])
            assert start <= ws < we <= end
            assert ws >= time(f['generatedAt'])
            if window_end is not None:
                assert window_end < ws
            window_end = we
    assert dates == sorted(set(dates))


if __name__ == '__main__':
    visit_schema(SPEC)
    assert SPEC['openapi'] == '3.1.0'
    assert SPEC['info']['version'] == '1.0.0'
    files = sorted((ROOT / 'api/examples').glob('*.json'))
    for path in files:
        try:
            value = json.loads(path.read_text())
            name = 'Error' if path.name.startswith('error-') else 'Forecast'
            validate(value, SPEC['components']['schemas'][name])
            if name == 'Forecast':
                check_forecast(value)
        except Exception as error:
            raise AssertionError(f'{path.name}: {error}') from error
    print(f'Checked internal schema references and {len(files)} forecast fixtures.')
