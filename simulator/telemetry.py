"""Transformation des relevés réels London Smart Meters en événements Pub/Sub."""

from __future__ import annotations

import csv
import hashlib
import math
from datetime import datetime, timezone
from typing import Iterable, Iterator, Mapping, TextIO
from uuid import NAMESPACE_URL, uuid5
from zoneinfo import ZoneInfo


SCHEMA_VERSION = "1.0"
SOURCE = "STREAM_REPLAY"
LONDON_TIMEZONE = ZoneInfo("Europe/London")
METER_COLUMNS = ("LCLid", "lclid", "meter_id")
TIME_COLUMNS = ("DateTime", "tstp", "event_time")
ENERGY_COLUMNS = (
    "KWH/hh (per half hour) ",
    "KWH/hh (per half hour)",
    "energy(kWh/hh)",
    "energy_kwh",
)


class InvalidReading(ValueError):
    """La ligne source ne peut pas devenir un événement de consommation valide."""


def _first_value(row: Mapping[str, object], names: Iterable[str]) -> object:
    for name in names:
        value = row.get(name)
        if value is not None and str(value).strip():
            return value
    raise InvalidReading(f"Colonne obligatoire absente parmi: {', '.join(names)}")


def parse_event_time(value: object) -> datetime:
    raw = str(value).strip().replace("Z", "+00:00")
    parsed = None
    for parser in (
        lambda text: datetime.fromisoformat(text),
        lambda text: datetime.strptime(text, "%Y-%m-%d %H:%M:%S"),
    ):
        try:
            parsed = parser(raw)
            break
        except ValueError:
            continue
    if parsed is None:
        raise InvalidReading(f"Horodatage invalide: {value!r}")
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=LONDON_TIMEZONE)
    return parsed.astimezone(timezone.utc)


def parse_energy_kwh(value: object) -> float:
    raw = str(value).strip()
    if not raw or raw.lower() in {"null", "nan", "none"}:
        raise InvalidReading("Consommation absente")
    try:
        energy = float(raw)
    except ValueError as exc:
        raise InvalidReading(f"Consommation invalide: {value!r}") from exc
    if not math.isfinite(energy) or energy < 0:
        raise InvalidReading(f"Consommation hors domaine: {value!r}")
    return energy


def virtual_group_id(meter_id: str, group_count: int = 5) -> str:
    if group_count < 1:
        raise ValueError("group_count doit être supérieur à zéro")
    digest = hashlib.sha256(meter_id.encode("utf-8")).digest()
    group_number = int.from_bytes(digest[:4], "big") % group_count + 1
    return f"LONDON-GROUP-{group_number:02d}"


def london_event(
    row: Mapping[str, object],
    *,
    group_count: int = 5,
    ingestion_time: datetime | None = None,
) -> dict[str, object]:
    meter_id = str(_first_value(row, METER_COLUMNS)).strip()
    event_time = parse_event_time(_first_value(row, TIME_COLUMNS))
    energy_kwh = parse_energy_kwh(_first_value(row, ENERGY_COLUMNS))
    ingestion = (ingestion_time or datetime.now(timezone.utc)).astimezone(timezone.utc)
    event_key = f"{meter_id}|{event_time.isoformat()}"

    return {
        "event_id": str(uuid5(NAMESPACE_URL, f"smartgrid-pulse:london:{event_key}")),
        "meter_id": meter_id,
        "virtual_group_id": virtual_group_id(meter_id, group_count),
        "event_time": event_time.isoformat().replace("+00:00", "Z"),
        "ingestion_time": ingestion.isoformat().replace("+00:00", "Z"),
        "energy_kwh": energy_kwh,
        "source": SOURCE,
        "schema_version": SCHEMA_VERSION,
    }


def iter_london_events(
    stream: TextIO,
    *,
    limit: int,
    group_count: int = 5,
    start_time: datetime | None = None,
    end_time: datetime | None = None,
) -> Iterator[dict[str, object]]:
    """Lit progressivement un CSV Kaggle et ignore ses relevés incomplets."""
    emitted = 0
    for row in csv.DictReader(stream):
        try:
            event = london_event(row, group_count=group_count)
        except InvalidReading:
            continue
        event_time = parse_event_time(event["event_time"])
        if start_time and event_time < start_time:
            continue
        if end_time and event_time >= end_time:
            continue
        yield event
        emitted += 1
        if emitted >= limit:
            return
