import json
import os
from concurrent.futures import TimeoutError
from functools import cache
from time import monotonic
from uuid import uuid4

from flask import Flask, jsonify, request
from google.api_core.exceptions import GoogleAPIError
from google.auth.exceptions import GoogleAuthError
from google.cloud import pubsub_v1

from telemetry import SCENARIOS, generate_batch


@cache
def publisher_client():
    return pubsub_v1.PublisherClient()


def create_app(publisher=None):
    app = Flask(__name__)
    app.config["MAX_CONTENT_LENGTH"] = 1024

    @app.get("/healthz")
    def health():
        return jsonify(status="ok")

    @app.post("/simulate")
    def simulate():
        body = request.get_json(silent=True)
        if not isinstance(body, dict) or body.get("scenario", "normal") not in SCENARIOS:
            return jsonify(error="Provide a valid JSON scenario", allowed_scenarios=SCENARIOS), 400

        topic = os.getenv("PUBSUB_TOPIC")
        if not topic:
            app.logger.error("PUBSUB_TOPIC is missing")
            return jsonify(error="The Pub/Sub topic is not configured"), 503

        scenario = body.get("scenario", "normal")
        batch_id = str(uuid4())
        messages = []
        deadline = monotonic() + 20
        try:
            client = publisher if publisher is not None else publisher_client()
            for event in generate_batch(scenario):
                remaining = deadline - monotonic()
                if remaining <= 0:
                    raise TimeoutError("Simulator publication deadline exceeded")

                event["batch_id"] = batch_id
                future = client.publish(
                    topic,
                    json.dumps(event).encode("utf-8"),
                    batch_id=batch_id,
                    source="cloud-run-simulator",
                )
                messages.append({
                    "message_id": future.result(timeout=remaining),
                    "event_id": event["event_id"],
                    "device_id": event["device_id"],
                    "is_alert": event["is_alert"],
                })
        except (GoogleAPIError, GoogleAuthError, TimeoutError):
            app.logger.exception("Publication incomplete for batch %s", batch_id)
            return jsonify(batch_id=batch_id, messages=messages, error="Publication incomplete"), 502

        return jsonify(batch_id=batch_id, scenario=scenario, messages=messages)

    return app


app = create_app()
