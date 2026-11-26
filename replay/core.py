"""Fonctions pures du replay 2018, testables sans compte GCP."""

from __future__ import annotations

import hashlib
import json
import math
from datetime import datetime, timezone
from typing import Iterable, Iterator, Mapping, TextIO


class ReplayContractError(ValueError):
    """Événement incompatible avec le contrat de replay."""


def parse_utc(value: str) -> datetime:
    """Parse un instant ISO-8601 et le normalise en UTC."""
    try:
        parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    except (AttributeError, ValueError) as exc:
        raise ReplayContractError(f"event_time invalide: {value!r}") from exc
    if parsed.tzinfo is None:
        raise ReplayContractError("event_time doit inclure un fuseau horaire")
    return parsed.astimezone(timezone.utc)


def deterministic_event_id(event_time: str) -> str:
    """Produit la clé idempotente commune Bronze/Silver/Gold."""
    canonical = parse_utc(event_time).isoformat().replace("+00:00", "Z")
    digest = hashlib.sha256(f"ES|STREAM_REPLAY|{canonical}".encode()).hexdigest()[:24]
    return f"es-2018-{digest}"


def normalize_event(event: Mapping[str, object]) -> dict[str, object]:
    """Normalise et contrôle les invariants métier avant publication."""
    normalized = dict(event)
    event_time = str(normalized.get("event_time", ""))
    timestamp = parse_utc(event_time)
    if timestamp.astimezone(timezone.utc).year != 2018 or any(
        (timestamp.minute, timestamp.second, timestamp.microsecond)
    ):
        raise ReplayContractError("Une observation doit correspondre à une heure UTC de 2018")
    normalized["event_time"] = timestamp.isoformat().replace("+00:00", "Z")
    normalized.setdefault("schema_version", "1.0")
    normalized.setdefault("source", "STREAM_REPLAY")
    normalized.setdefault("country_code", "ES")

    expected_id = deterministic_event_id(normalized["event_time"])
    supplied_id = normalized.get("event_id")
    if supplied_id not in (None, expected_id):
        raise ReplayContractError("event_id ne correspond pas à event_time")
    normalized["event_id"] = expected_id

    if normalized["source"] != "STREAM_REPLAY" or normalized["country_code"] != "ES":
        raise ReplayContractError("source/country_code incompatibles avec le replay Espagne")
    load = normalized.get("actual_load_mw")
    if type(load) not in (int, float) or not math.isfinite(load) or load < 0:
        raise ReplayContractError("actual_load_mw doit être positif ou nul")
    weather = normalized.get("weather")
    if not isinstance(weather, list) or not weather:
        raise ReplayContractError("weather doit contenir au moins une observation")
    return normalized


def read_ndjson(stream: TextIO) -> Iterator[dict[str, object]]:
    """Lit un flux NDJSON en signalant précisément la ligne fautive."""
    for line_number, raw_line in enumerate(stream, start=1):
        line = raw_line.strip()
        if not line:
            continue
        try:
            value = json.loads(line)
        except json.JSONDecodeError as exc:
            raise ReplayContractError(f"JSON invalide à la ligne {line_number}") from exc
        if not isinstance(value, dict):
            raise ReplayContractError(f"objet JSON attendu à la ligne {line_number}")
        yield normalize_event(value)


def ordered_unique(events: Iterable[Mapping[str, object]]) -> list[dict[str, object]]:
    """Trie chronologiquement et élimine les doublons par event_id."""
    unique: dict[str, dict[str, object]] = {}
    for raw_event in events:
        event = normalize_event(raw_event)
        event_id = str(event["event_id"])
        if event_id in unique and unique[event_id] != event:
            raise ReplayContractError(f"Observations incompatibles pour {event_id}")
        unique[event_id] = event
    return sorted(unique.values(), key=lambda item: str(item["event_time"]))


def encode_message(event: Mapping[str, object]) -> tuple[bytes, dict[str, str]]:
    """Encode le corps Pub/Sub et ses attributs de routage."""
    normalized = normalize_event(event)
    payload = json.dumps(normalized, separators=(",", ":"), sort_keys=True, allow_nan=False).encode()
    attributes = {
        "event_id": str(normalized["event_id"]),
        "event_time": str(normalized["event_time"]),
        "schema_version": str(normalized["schema_version"]),
        "source": str(normalized["source"]),
    }
    return payload, attributes
