"""Prépare les observations horaires 2018 pour le job de replay."""

import argparse
import csv
import json
import math
import sys
from collections import defaultdict
from pathlib import Path

from .core import ReplayContractError, ordered_unique, parse_utc


def number(value):
    if not value or not value.strip():
        return None
    parsed = float(value)
    return parsed if math.isfinite(parsed) else None


def rows(path, timestamp_column, required_columns):
    with path.open(encoding="utf-8-sig", newline="") as stream:
        reader = csv.DictReader(stream)
        missing = {timestamp_column, *required_columns} - set(reader.fieldnames or ())
        if missing:
            raise ReplayContractError(f"{path.name} : colonnes absentes {sorted(missing)}")
        for row in reader:
            stamp = parse_utc(row[timestamp_column].strip().removesuffix(" UTC"))
            if stamp.year == 2018:
                yield stamp, row


def prepare(energy, weather):
    weather_by_hour = defaultdict(dict)
    counts = {"weather_duplicates": 0, "missing_load": 0, "missing_weather": 0}
    for stamp, row in rows(weather, "dt_iso", ("city_name", "temp", "humidity", "wind_speed")):
        city = row["city_name"].strip()
        temperature = number(row["temp"])
        humidity = number(row["humidity"])
        wind = number(row["wind_speed"])
        if not city or temperature is None or humidity is None or wind is None:
            continue
        if temperature < 0 or not 0 <= humidity <= 100 or wind < 0:
            continue
        cities = weather_by_hour[stamp]
        if city in cities:
            counts["weather_duplicates"] += 1
            continue
        cities[city] = {
            "city_name": city,
            "temperature_c": round(temperature - 273.15, 3),
            "humidity_pct": humidity,
            "wind_speed_m_s": wind,
            "pressure_hpa": number(row.get("pressure")),
            "cloud_cover_pct": number(row.get("clouds_all")),
        }

    events = []
    for stamp, row in rows(energy, "time", ("total load actual", "generation solar", "generation wind onshore", "price actual")):
        load = number(row["total load actual"])
        if load is None or load < 0:
            counts["missing_load"] += 1
            continue
        cities = weather_by_hour.get(stamp)
        if not cities:
            counts["missing_weather"] += 1
            continue
        events.append({
            "event_time": stamp.isoformat(),
            "actual_load_mw": load,
            "forecast_load_mw": number(row.get("total load forecast")),
            "price_actual_eur_mwh": number(row["price actual"]),
            "generation_solar_mw": number(row["generation solar"]),
            "generation_wind_onshore_mw": number(row["generation wind onshore"]),
            "weather": [cities[city] for city in sorted(cities)],
        })
    events = ordered_unique(events)
    if not events:
        raise ReplayContractError("Aucune heure énergie–météo admissible pour 2018")
    return events, counts


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--energy", required=True, type=Path)
    parser.add_argument("--weather", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    events, counts = prepare(args.energy, args.weather)
    with args.output.open("x", encoding="utf-8", newline="\n") as stream:
        for event in events:
            stream.write(json.dumps(event, ensure_ascii=False, allow_nan=False) + "\n")
    print(json.dumps({"events": len(events), **counts}), file=sys.stderr)


if __name__ == "__main__":
    main()
