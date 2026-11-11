"use client";

import "maplibre-gl/dist/maplibre-gl.css";

import maplibregl from "maplibre-gl";
import { useEffect, useRef } from "react";

// Placeholder centre (Bengaluru). Replaced by the pilot campus in P4-W9.
const CENTER: [number, number] = [77.5946, 12.9716];

/**
 * Institution map. Will show PUBLISHED clusters only (>= k reports from >= m devices),
 * never individual reports or people.
 */
export default function CampusMap() {
  const container = useRef<HTMLDivElement>(null);

  useEffect(() => {
    if (!container.current) return;
    const map = new maplibregl.Map({
      container: container.current,
      style: "https://demotiles.maplibre.org/style.json",
      center: CENTER,
      zoom: 13,
    });
    map.addControl(new maplibregl.NavigationControl(), "top-right");
    return () => map.remove();
  }, []);

  return <div ref={container} style={{ width: "100%", height: "100%" }} />;
}
