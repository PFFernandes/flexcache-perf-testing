"""Parse and print sizes: 64KiB, 1.5GiB, 500GB, 4096."""
from __future__ import annotations

import re

_UNITS = {
    "": 1, "b": 1,
    "k": 1024, "kib": 1024, "m": 1024**2, "mib": 1024**2,
    "g": 1024**3, "gib": 1024**3, "t": 1024**4, "tib": 1024**4,
    "kb": 1000, "mb": 1000**2, "gb": 1000**3, "tb": 1000**4,
}
_RE = re.compile(r"^\s*([0-9]+(?:\.[0-9]+)?)\s*([a-zA-Z]*)\s*$")


def parse_size(value) -> int:
    """'64KiB' -> 65536. Integers pass through. KiB/MiB/... are 1024-based, KB/MB/... 1000-based."""
    if isinstance(value, bool):
        raise ValueError(f"not a size: {value!r}")
    if isinstance(value, int):
        if value < 0:
            raise ValueError(f"size can't be negative: {value}")
        return value
    m = _RE.match(str(value))
    if not m or m.group(2).lower() not in _UNITS:
        raise ValueError(f"not a size: {value!r} (examples: 4096, 64KiB, 1.5GiB, 500GB)")
    return int(float(m.group(1)) * _UNITS[m.group(2).lower()])


def format_size(n: float) -> str:
    """65536 -> '64.0 KiB'."""
    for unit in ("B", "KiB", "MiB", "GiB", "TiB"):
        if abs(n) < 1024 or unit == "TiB":
            return f"{n:.0f} {unit}" if unit == "B" else f"{n:.1f} {unit}"
        n /= 1024
    return f"{n:.1f} TiB"
