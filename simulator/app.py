"""API Cloud Run qui rejoue un extrait réel du dataset Smart Meters in London."""

from __future__ import annotations

import json
import os
from concurrent.futures import TimeoutError
from functools import cache
from time import monotonic
from urllib.parse import urlparse
from uuid import uuid4

from flask import Flask, jsonify, request
from google.api_core.exceptions import GoogleAPIError
from google.auth.exceptions import GoogleAuthError
from google.cloud import pubsub_v1, storage

from telemetry import iter_london_events, parse_event_time


MAX_MESSAGES_PER_REQUEST = 500


@cache
def publisher_client():
    return pubsub_v1.PublisherClient()


@cache
def storage_client():
    return storage.Client()


def parse_gcs_uri(uri: str) -> tuple[str, str]:
    parsed = urlparse(uri)
    if parsed.scheme != "gs" or not parsed.netloc or not parsed.path.strip("/"):
        raise ValueError("source_uri doit être une URI gs://bucket/object valide")
    return parsed.netloc, parsed.path.lstrip("/")


def source_is_allowed(uri: str) -> bool:
    allowed_prefix = os.getenv("REPLAY_GCS_PREFIX", "").rstrip("/")
    return bool(allowed_prefix) and uri.startswith(f"{allowed_prefix}/")


def create_app(publisher=None, storage_service=None):
    app = Flask(__name__)
    app.config["MAX_CONTENT_LENGTH"] = 16 * 1024

    @app.get("/healthz")
    def health():
        return jsonify(status="ok", dataset="London Smart Meters", mode="real-data-replay")

    @app.post("/replay")
    def replay():
        body = request.get_json(silent=True)
        if not isinstance(body, dict):
            return jsonify(error="Le corps doit être un objet JSON"), 400

        source_uri = str(body.get("source_uri", ""))
        if not source_is_allowed(source_uri):
            return jsonify(error="source_uri est hors du préfixe REPLAY_GCS_PREFIX autorisé"), 403

        try:
            limit = int(body.get("max_messages", 100))
            if not 1 <= limit <= MAX_MESSAGES_PER_REQUEST:
                raise ValueError(f"max_messages doit être entre 1 et {MAX_MESSAGES_PER_REQUEST}")
            start_time = parse_event_time(body["start_time"]) if body.get("start_time") else None
            end_time = parse_event_time(body["end_time"]) if body.get("end_time") else None
            bucket_name, object_name = parse_gcs_uri(source_uri)
        except (TypeError, ValueError) as exc:
            return jsonify(error=str(exc)), 400

        topic = os.getenv("PUBSUB_TOPIC")
        if not topic:
            return jsonify(error="PUBSUB_TOPIC n'est pas configuré"), 503

        run_id = str(uuid4())
        published = []
        deadline = monotonic() + 25
        try:
            gcs = storage_service if storage_service is not None else storage_client()
            blob = gcs.bucket(bucket_name).blob(object_name)
            client = publisher if publisher is not None else publisher_client()
            with blob.open("rt", encoding="utf-8-sig", newline="") as stream:
                for event in iter_london_events(
                    stream,
                    limit=limit,
                    start_time=start_time,
                    end_time=end_time,
                ):
                    remaining = deadline - monotonic()
                    if remaining <= 0:
                        raise TimeoutError("Délai de publication dépassé")
                    future = client.publish(
                        topic,
                        json.dumps(event, separators=(",", ":")).encode("utf-8"),
                        event_id=event["event_id"],
                        meter_id=event["meter_id"],
                        source="stream-replay",
                        schema_version=event["schema_version"],
                        replay_run_id=run_id,
                    )
                    published.append({
                        "message_id": future.result(timeout=remaining),
                        "event_id": event["event_id"],
                        "meter_id": event["meter_id"],
                        "event_time": event["event_time"],
                    })
        except (GoogleAPIError, GoogleAuthError, TimeoutError, OSError):
            app.logger.exception("Replay Londres incomplet pour %s", run_id)
            return jsonify(run_id=run_id, published=published, error="Replay incomplet"), 502

        return jsonify(
            run_id=run_id,
            source_uri=source_uri,
            published_count=len(published),
            messages=published,
        )

    return app


app = create_app()
