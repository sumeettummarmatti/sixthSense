# Routing engine (Valhalla) — P4

Safety-weighted pedestrian routing on OpenStreetMap data.

## Run locally
1. Download an extract for the pilot area into `routing-engine/data/` (git-ignored), e.g. the
   Karnataka extract from Geofabrik (`southern-zone-latest.osm.pbf`) or a clipped campus bbox.
2. `docker compose -f routing-engine/docker-compose.yml up -d` — first start builds tiles (slow).
3. `curl http://localhost:8002/status`

## Used by the Insight routes API (P4-W1-demo-safe-routes)
`insight/app/routing/` asks a router for walking routes and re-ranks them. In dev it uses the
public OSRM server (`ROUTING_PROVIDER=osrm`, no setup). For a demo, run Valhalla here and set
`ROUTING_PROVIDER=valhalla` and `VALHALLA_BASE_URL=http://localhost:8002` in `.env`, so the demo
does not depend on a shared public server. The Insight side asks for `pedestrian` costing with
`alternates`, and adds its own alternatives through side points, so no custom costing is needed yet.

## Safety costing (P4-W7-valhalla-safety-costing)
Route cost = travel time + (user caution level × segment risk) + accessibility penalties.
Segment risk comes from the Insight risk layer (published clusters only), lighting data and
open-shop density. Routes are never logged against a user.
