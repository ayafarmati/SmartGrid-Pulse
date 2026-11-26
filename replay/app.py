"""Point d'entrée d'un Cloud Run Job qui rejoue les observations 2018."""

from __future__ import annotations

import argparse
import io
import json
import os
import sys
import time
from pathlib import Path
from typing import TextIO

from jsonschema import Draft202012Validator, FormatChecker

try:
    from .core import encode_message, ordered_unique, read_ndjson
except ImportError:  # Exécution directe dans l'image Cloud Run Job.
    from core import encode_message, ordered_unique, read_ndjson


def parse_gs_uri(uri: str) -> tuple[str, str]:
    if not uri.startswith("gs://") or "/" not in uri[5:]:
        raise ValueError(f"URI GCS invalide: {uri}")
    bucket, blob = uri[5:].split("/", 1)
    return bucket, blob


def open_input(uri: str) -> TextIO:
    if uri.startswith("gs://"):
        from google.cloud import storage

        bucket, blob = parse_gs_uri(uri)
        content = storage.Client().bucket(bucket).blob(blob).download_as_text()
        return io.StringIO(content)
    return Path(uri).open("r", encoding="utf-8")


def load_checkpoint(uri: str | None) -> str | None:
    if not uri:
        return None
    if uri.startswith("gs://"):
        from google.cloud import storage

        bucket, blob = parse_gs_uri(uri)
        target = storage.Client().bucket(bucket).blob(blob)
        return target.download_as_text().strip() if target.exists() else None
    path = Path(uri)
    return path.read_text(encoding="utf-8").strip() if path.exists() else None


def save_checkpoint(uri: str | None, event_id: str) -> None:
    if not uri:
        return
    if uri.startswith("gs://"):
        from google.cloud import storage

        bucket, blob = parse_gs_uri(uri)
        storage.Client().bucket(bucket).blob(blob).upload_from_string(event_id)
        return
    Path(uri).write_text(event_id, encoding="utf-8")


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Replay chronologique SmartGrid Pulse 2018")
    parser.add_argument("--input-uri", default=os.getenv("INPUT_URI"), required=not os.getenv("INPUT_URI"))
    parser.add_argument("--project", default=os.getenv("GOOGLE_CLOUD_PROJECT"))
    parser.add_argument("--topic", default=os.getenv("TOPIC_ID", "grid-telemetry-topic"))
    parser.add_argument("--checkpoint-uri", default=os.getenv("CHECKPOINT_URI"))
    parser.add_argument("--interval-seconds", type=float, default=float(os.getenv("INTERVAL_SECONDS", "1")))
    parser.add_argument("--limit", type=int, default=0)
    parser.add_argument("--dry-run", action="store_true")
    return parser


def main() -> int:
    args = build_parser().parse_args()
    schema_path = Path(__file__).with_name("energy_replay_event.schema.json")
    if not schema_path.exists():
        schema_path = Path(__file__).resolve().parents[1] / "schemas" / schema_path.name
    schema = json.loads(schema_path.read_text(encoding="utf-8"))
    validator = Draft202012Validator(schema, format_checker=FormatChecker())

    with open_input(args.input_uri) as stream:
        events = ordered_unique(read_ndjson(stream))
    for event in events:
        validator.validate(event)

    checkpoint = None if args.dry_run else load_checkpoint(args.checkpoint_uri)
    if checkpoint:
        checkpoint_index = next((i for i, event in enumerate(events) if event["event_id"] == checkpoint), None)
        if checkpoint_index is not None:
            events = events[checkpoint_index + 1 :]
        else:
            raise ValueError("Le point de reprise ne correspond pas au fichier source")
    if args.limit > 0:
        events = events[: args.limit]

    publisher = None
    topic_path = None
    if not args.dry_run:
        if not args.project:
            raise ValueError("--project est obligatoire hors dry-run")
        from google.cloud import pubsub_v1

        publisher = pubsub_v1.PublisherClient()
        topic_path = publisher.topic_path(args.project, args.topic)

    for index, event in enumerate(events):
        payload, attributes = encode_message(event)
        if args.dry_run:
            print(payload.decode())
        else:
            assert publisher is not None and topic_path is not None
            publisher.publish(topic_path, payload, **attributes).result(timeout=60)
            save_checkpoint(args.checkpoint_uri, str(event["event_id"]))
        if not args.dry_run and args.interval_seconds > 0 and index < len(events) - 1:
            time.sleep(args.interval_seconds)

    print(json.dumps({"status": "completed", "events": len(events), "dry_run": args.dry_run}), file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
