"""Derived weather values computed from raw readings (US units throughout)."""

from __future__ import annotations

import math


def dew_point_f(temp_f: float | None, rh: float | None) -> float | None:
    """Dew point (°F) using the Magnus-Tetens approximation."""
    if temp_f is None or rh is None or rh <= 0:
        return None
    t = (temp_f - 32) * 5 / 9
    a, b = 17.625, 243.04
    gamma = math.log(min(rh, 100) / 100) + a * t / (b + t)
    td = b * gamma / (a - gamma)
    return td * 9 / 5 + 32


def wind_chill_f(temp_f: float | None, wind_mph: float | None) -> float | None:
    """NWS wind chill (2001). Equals air temperature outside its valid range
    (T > 50 °F or wind < 3 mph), matching what a console displays."""
    if temp_f is None:
        return None
    if wind_mph is None or temp_f > 50 or wind_mph < 3:
        return temp_f
    v = wind_mph**0.16
    return 35.74 + 0.6215 * temp_f - 35.75 * v + 0.4275 * temp_f * v


def heat_index_f(temp_f: float | None, rh: float | None) -> float | None:
    """Temperature-Humidity Index (the console's THI): NWS heat index.

    At or below 70 °F humidity has no meaningful effect and THI equals the air
    temperature; between that and 80 °F the simple Steadman form is used.
    """
    if temp_f is None:
        return None
    if temp_f <= 70:
        return temp_f
    if rh is None:
        return None
    t, r = temp_f, rh
    simple = 0.5 * (t + 61.0 + (t - 68.0) * 1.2 + r * 0.094)
    if (simple + t) / 2 < 80:
        return simple
    hi = (
        -42.379
        + 2.04901523 * t
        + 10.14333127 * r
        - 0.22475541 * t * r
        - 0.00683783 * t * t
        - 0.05481717 * r * r
        + 0.00122874 * t * t * r
        + 0.00085282 * t * r * r
        - 0.00000199 * t * t * r * r
    )
    if r < 13 and 80 <= t <= 112:
        hi -= ((13 - r) / 4) * math.sqrt((17 - abs(t - 95)) / 17)
    elif r > 85 and 80 <= t <= 87:
        hi += ((r - 85) / 10) * ((87 - t) / 5)
    return hi


# A change of at least this much over the comparison window lights RISE/FALL.
PRESSURE_TREND_THRESHOLD_INHG = 0.02


def pressure_trend(now: float | None, earlier: float | None) -> str:
    """Return 'rise', 'fall' or 'steady'."""
    if now is None or earlier is None:
        return "steady"
    delta = now - earlier
    if delta >= PRESSURE_TREND_THRESHOLD_INHG:
        return "rise"
    if delta <= -PRESSURE_TREND_THRESHOLD_INHG:
        return "fall"
    return "steady"


def compass_sector(deg: float | None, sectors: int = 16) -> int | None:
    """0 = N, 4 = E, 8 = S, 12 = W for 16 sectors."""
    if deg is None:
        return None
    width = 360 / sectors
    return int(((deg % 360) + width / 2) // width) % sectors
