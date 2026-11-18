"""Allow libm rounding noise only in serialized solar altitude values."""

import pytest


def assert_forecast_equal(actual, expected):
    if isinstance(expected, dict):
        assert isinstance(actual, dict) and actual.keys() == expected.keys()
        for key in expected:
            if key == "solarAltitudeDegrees" and isinstance(expected[key], float):
                assert type(actual[key]) is float
                assert actual[key] == pytest.approx(expected[key], rel=0, abs=1e-10)
            else:
                assert_forecast_equal(actual[key], expected[key])
    elif isinstance(expected, list):
        assert isinstance(actual, list) and len(actual) == len(expected)
        for left, right in zip(actual, expected, strict=True):
            assert_forecast_equal(left, right)
    else:
        assert type(actual) is type(expected) and actual == expected
