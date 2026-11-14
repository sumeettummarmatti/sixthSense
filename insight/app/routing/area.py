"""The demo area: a bounding box plus the point features routes are scored against.

The file comes from `scripts/build_area_features.py`: OpenStreetMap via Overpass, optionally
replaced by BBMP streetlights, BMTC stops and police KML downloaded by hand from
data.opencity.in. It is public infrastructure data only; nothing in it is about a person.
"""

import json
from dataclasses import dataclass
from pathlib import Path

from app.routing.geo import GridIndex, LatLon

KINDS = (
    "lamp",
    "bus_stop",
    "station",
    "police",
    "hospital",
    "pharmacy",
    "food",
    "shop",
    "atm",
    "fuel",
)
OPEN_PLACE_KINDS = frozenset({"pharmacy", "food", "shop", "atm", "fuel"})

_M_PER_DEG = 111_320.0


@dataclass(frozen=True)
class Feature:
    id: int
    kind: str
    lat: float
    lon: float
    late: bool  # usually still open after 22:00 (24/7 tag, late closing hour, or kind default)


@dataclass
class Area:
    name: str
    label: str
    bbox: tuple[float, float, float, float]  # south, west, north, east
    sources: list[str]
    features: list[Feature]
    index: dict[str, GridIndex]

    def contains(self, point: LatLon, pad_m: float = 0.0) -> bool:
        pad = pad_m / _M_PER_DEG
        south, west, north, east = self.bbox
        return south - pad <= point[0] <= north + pad and west - pad <= point[1] <= east + pad

    def counts(self) -> dict[str, int]:
        return {kind: self.index[kind].count for kind in KINDS}


def build_area(
    name: str,
    label: str,
    bbox: tuple[float, float, float, float],
    sources: list[str],
    rows: list[tuple[str, float, float, bool]],
) -> Area:
    index = {kind: GridIndex() for kind in KINDS}
    features = []
    for i, (kind, lat, lon, late) in enumerate(rows):
        if kind not in index:
            continue
        feature = Feature(i, kind, lat, lon, bool(late))
        features.append(feature)
        index[kind].add((lat, lon), feature)
    return Area(name, label, bbox, sources, features, index)


def load_area(path: str | Path) -> Area:
    data = json.loads(Path(path).read_text())
    rows = [(f[0], float(f[1]), float(f[2]), bool(f[3])) for f in data["features"]]
    return build_area(
        data["name"], data["label"], tuple(data["bbox"]), list(data.get("sources", [])), rows
    )
