"""Build the point-feature file one demo area routes are scored against (P4-W1-demo-safe-routes).

    cd insight && uv run python scripts/build_area_features.py \
        --name indiranagar --label "Indiranagar, Bengaluru" --bbox 12.955,77.620,12.995,77.660

Pulls streetlights, shops, food, pharmacies, ATMs, fuel, hospitals, police, stations and bus
stops from OpenStreetMap (Overpass, trying several public mirrors). Files from data.opencity.in
can replace the OSM layer of the same kind; the site is behind a browser check, so download them
by hand and pass the paths:

    --streetlights-kml <BBMP zone KML> ...   replaces OSM street lamps
    --police-kml <KML>                        replaces OSM police stations
    --bus-stops-csv <BMTC CSV with lat/lon>   replaces OSM bus stops

Output is public infrastructure data only. Nothing about a person is read or written.
"""

import argparse
import csv
import json
import re
import sys
import time
import xml.etree.ElementTree as ET
from datetime import UTC, datetime
from pathlib import Path

import httpx

OVERPASS_MIRRORS = (
    "https://maps.mail.ru/osm/tools/overpass/api/interpreter",
    "https://overpass-api.de/api/interpreter",
    "https://overpass.kumi.systems/api/interpreter",
    "https://overpass.private.coffee/api/interpreter",
)
QUERY = """
[out:json][timeout:90];
(
  node["highway"="street_lamp"]({bbox});
  node["highway"="bus_stop"]({bbox});
  node["railway"="station"]({bbox});
  node["amenity"~"^(police|hospital|pharmacy|cafe|restaurant|fast_food|fuel|atm|bank)$"]({bbox});
  node["shop"]({bbox});
);
out tags center;
"""
# Kinds that are open round the clock, or usually open after 22:00, when OSM has no hours.
LATE_BY_DEFAULT = {"police", "hospital", "fuel", "atm", "station", "pharmacy", "food"}
_HOURS = re.compile(r"(\d{1,2}):(\d{2})")


def kind_of(tags: dict) -> str | None:
    if tags.get("highway") == "street_lamp":
        return "lamp"
    if tags.get("highway") == "bus_stop":
        return "bus_stop"
    if tags.get("railway") == "station":
        return "station"
    amenity = tags.get("amenity")
    if amenity in ("police", "hospital", "pharmacy", "fuel", "atm"):
        return amenity
    if amenity in ("cafe", "restaurant", "fast_food"):
        return "food"
    if amenity == "bank" or "shop" in tags:
        return "shop"
    return None


def is_late(kind: str, hours: str | None) -> bool:
    """Open after 22:00? From opening_hours when we can read it, else the kind's default."""
    if hours:
        if "24/7" in hours:
            return True
        closings = [int(h) for h, _ in _HOURS.findall(hours)][1::2]  # every second time = closing
        if closings:
            return any(h >= 22 or h <= 5 for h in closings)
    return kind in LATE_BY_DEFAULT


def fetch_overpass(bbox: tuple[float, float, float, float]) -> list[dict]:
    query = QUERY.format(bbox=",".join(f"{v:.6f}" for v in bbox))
    last = "no mirror tried"
    for attempt, url in enumerate(OVERPASS_MIRRORS):
        try:
            resp = httpx.post(
                url,
                data={"data": query},
                timeout=120,
                headers={"User-Agent": "sixthsense-area-builder"},
            )
            if resp.status_code == 200 and resp.text.lstrip().startswith("{"):
                return resp.json()["elements"]
            last = f"{url}: http {resp.status_code}"
        except httpx.HTTPError as error:
            last = f"{url}: {type(error).__name__}"
        print(f"   {last}; trying the next mirror", file=sys.stderr)
        time.sleep(2 * (attempt + 1))
    sys.exit(f"FAILED: Overpass unavailable ({last}). Try again in a few minutes.")


def osm_rows(elements: list[dict]) -> dict[str, list[tuple[str, float, float, bool]]]:
    rows: dict[str, list] = {}
    for element in elements:
        tags = element.get("tags", {})
        kind = kind_of(tags)
        lat, lon = element.get("lat"), element.get("lon")
        if kind is None or lat is None:
            continue
        rows.setdefault(kind, []).append((kind, lat, lon, is_late(kind, tags.get("opening_hours"))))
    return rows


def kml_points(path: Path, bbox: tuple[float, float, float, float]) -> list[tuple[float, float]]:
    """Every <Point> in a KML (or the first file of a KMZ) inside the bbox."""
    text = path.read_bytes()
    if path.suffix.lower() == ".kmz":
        import io
        import zipfile

        with zipfile.ZipFile(io.BytesIO(text)) as archive:
            text = archive.read(next(n for n in archive.namelist() if n.endswith(".kml")))
    # The developer downloaded this file themselves; it is not untrusted input.
    root = ET.fromstring(text)  # noqa: S314
    south, west, north, east = bbox
    points = []
    for node in root.iter():
        if node.tag.endswith("coordinates") and node.text:
            for triple in node.text.split():
                parts = triple.split(",")
                if len(parts) < 2:
                    continue
                lon, lat = float(parts[0]), float(parts[1])
                if south <= lat <= north and west <= lon <= east:
                    points.append((lat, lon))
    return points


def csv_points(path: Path, bbox: tuple[float, float, float, float]) -> list[tuple[float, float]]:
    south, west, north, east = bbox
    points = []
    with path.open(newline="", encoding="utf-8-sig") as handle:
        reader = csv.DictReader(handle)
        headers = {h.lower(): h for h in reader.fieldnames or []}
        lat_col = next((headers[h] for h in headers if "lat" in h), None)
        lon_col = next((headers[h] for h in headers if "lon" in h or "lng" in h), None)
        if not lat_col or not lon_col:
            sys.exit(f"FAILED: no lat/lon columns in {path.name}: {reader.fieldnames}")
        for row in reader:
            try:
                lat, lon = float(row[lat_col]), float(row[lon_col])
            except (TypeError, ValueError):
                continue
            if south <= lat <= north and west <= lon <= east:
                points.append((lat, lon))
    return points


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--name", required=True, help="file and API name, e.g. indiranagar")
    parser.add_argument("--label", required=True, help='shown to people, e.g. "Indiranagar"')
    parser.add_argument("--bbox", required=True, help="south,west,north,east")
    parser.add_argument("--streetlights-kml", nargs="*", default=[], type=Path)
    parser.add_argument("--police-kml", type=Path)
    parser.add_argument("--bus-stops-csv", type=Path)
    parser.add_argument(
        "--overpass-json", type=Path, help="a saved Overpass response instead of querying"
    )
    parser.add_argument("--out", type=Path)
    args = parser.parse_args()

    bbox = tuple(float(v) for v in args.bbox.split(","))
    if len(bbox) != 4 or bbox[0] >= bbox[2] or bbox[1] >= bbox[3]:
        sys.exit("FAILED: --bbox must be south,west,north,east")
    out = args.out or Path(__file__).resolve().parents[1] / "data" / "areas" / f"{args.name}.json"

    if args.overpass_json:
        print(f"1. OpenStreetMap from {args.overpass_json}...")
        elements = json.loads(args.overpass_json.read_text())["elements"]
    else:
        print("1. OpenStreetMap via Overpass...")
        elements = fetch_overpass(bbox)
    rows = osm_rows(elements)
    sources = ["OpenStreetMap contributors (ODbL), via Overpass API"]

    if args.streetlights_kml:
        lamps = [p for path in args.streetlights_kml for p in kml_points(path, bbox)]
        osm_lamps = len(rows.get("lamp", []))
        print(f"2. BBMP streetlights: {len(lamps)} in the box (replacing {osm_lamps} from OSM)")
        rows["lamp"] = [("lamp", lat, lon, False) for lat, lon in lamps]
        sources.append("BBMP zone-wise streetlights 2024 (data.opencity.in)")
    if args.police_kml:
        police = kml_points(args.police_kml, bbox)
        print(f"   Police stations from KML: {len(police)}")
        rows["police"] = [("police", lat, lon, True) for lat, lon in police]
        sources.append("Police station locations, Bengaluru Urban (data.opencity.in)")
    if args.bus_stops_csv:
        stops = csv_points(args.bus_stops_csv, bbox)
        print(f"   BMTC bus stops from CSV: {len(stops)}")
        rows["bus_stop"] = [("bus_stop", lat, lon, False) for lat, lon in stops]
        sources.append("BMTC stops with location and routes, CC BY-SA 2.0 (data.opencity.in)")

    features = [row for kind in sorted(rows) for row in rows[kind]]
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(
        json.dumps(
            {
                "name": args.name,
                "label": args.label,
                "bbox": list(bbox),
                "built_at": datetime.now(UTC).strftime("%Y-%m-%d"),
                "sources": sources,
                "features": [
                    [k, round(lat, 6), round(lon, 6), int(late)] for k, lat, lon, late in features
                ],
            },
            separators=(",", ":"),
        )
    )
    counts = ", ".join(f"{kind} {len(rows[kind])}" for kind in sorted(rows))
    print(f"3. Wrote {out} ({len(features)} features: {counts})")


if __name__ == "__main__":
    main()
