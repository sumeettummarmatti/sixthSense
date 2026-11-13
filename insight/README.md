# Insight service (P4)

The anonymous zone: its own database (`insight-db`, port 5433), no user identifiers, never imports
Core code or credentials (ADR-1). Reports are about places, never people.

## Run locally
```bash
docker compose -f infra/docker-compose.yml up -d --wait
cd insight && uv sync && uv run alembic upgrade head
uv run uvicorn app.main:app --port 8001
```
Checks: `uv run ruff check . && uv run pytest` (tests need no database and no network).

## Routes (`P4-W1-demo-safe-routes`)
Ranked walking routes for one area, re-ranked from an existing router by what is around each way.

- Demo map: http://localhost:8001/routes/demo (click a start, then a destination; switch the
  time; "Report a place" drops a report).
- API: `GET /routes?from=12.9719,77.6412&to=12.9610,77.6390&at=night`,
  `POST /routes/reports`, `GET /routes/area`. Contract: `contracts/openapi.yaml`.
- Router: `ROUTING_PROVIDER=osrm` (public server, no key; dev default) or `valhalla`
  (local, see `routing-engine/README.md`; use this for a real demo).
- Area data: `data/areas/indiranagar.json` (OpenStreetMap). Rebuild or add an area with
  `uv run python scripts/build_area_features.py --name <area> --label "<Label>" --bbox s,w,n,e`.
  BBMP streetlights, BMTC stops and police KML from data.opencity.in can replace the OSM layers
  (`--streetlights-kml`, `--bus-stops-csv`, `--police-kml`); download them in a browser, the site
  blocks scripts.
- Reports feed routes only once a ~55 m cell has `PUBLISH_MIN_REPORTS` reports from
  `PUBLISH_MIN_DEVICES` reporters (set both to 1 on a dev laptop to see one report move a route).
- Rule 5 applies everywhere: labels are *Strong evidence of concern*, *Some reports of concern*,
  *Insufficient data*. Nothing is ever labelled safe, and the map has no green.
