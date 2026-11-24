"""Vérifie la redirection Pub/Sub sans modifier les souscriptions d'ingestion."""

import argparse
import base64
import json
import subprocess
import sys
from time import monotonic, sleep
from urllib.error import HTTPError
from urllib.request import Request, urlopen
from uuid import uuid4


def gcloud(*arguments):
    result = subprocess.run(
        ["gcloud", *arguments, "--quiet"], capture_output=True, text=True, check=False,
    )
    if result.returncode:
        raise RuntimeError(result.stderr.strip() or "Échec de gcloud.")
    return result.stdout.strip()


def pubsub_request(token, method, resource, body=None):
    request = Request(
        f"https://pubsub.googleapis.com/v1/{resource}",
        data=json.dumps(body).encode("utf-8") if body is not None else None,
        headers={"Authorization": f"Bearer {token}", "Content-Type": "application/json"},
        method=method,
    )
    try:
        with urlopen(request, timeout=12) as response:
            return json.loads(response.read() or b"{}")
    except HTTPError as error:
        detail = error.read().decode("utf-8", errors="replace")
        raise RuntimeError(f"Pub/Sub HTTP {error.code} pour {method} {resource}: {detail}") from error


def pull(token, subscription):
    try:
        received = pubsub_request(token, "POST", f"{subscription}:pull", {
            "maxMessages": 1,
            "returnImmediately": True,
        }).get("receivedMessages", [])
    except TimeoutError:
        return None
    return next(iter(received), None)


def wait_for_forwarding(token, source, reader, source_name):
    deadline = monotonic() + 180
    while monotonic() < deadline:
        forwarded = pull(token, reader)
        if forwarded:
            message = forwarded["message"]
            attributes = message.get("attributes", {})
            origin = attributes.get("CloudPubSubDeadLetterSourceSubscription", "")
            if origin.rsplit("/", 1)[-1] != source_name:
                raise RuntimeError(f"Souscription source inattendue dans la DLQ : {origin}")

            pubsub_request(token, "POST", f"{reader}:acknowledge", {
                "ackIds": [forwarded["ackId"]],
            })
            return message

        received = pull(token, source)
        if received:
            attempt = received.get("deliveryAttempt") or "non disponible"
            print(f"Livraison de test refusée (tentative Pub/Sub : {attempt}).", flush=True)
            pubsub_request(token, "POST", f"{source}:modifyAckDeadline", {
                "ackIds": [received["ackId"]],
                "ackDeadlineSeconds": 0,
            })
        sleep(2)

    raise RuntimeError("Aucun message de ce test n'a été retrouvé dans la DLQ au bout de 180 s.")


def smoke_test(project):
    token = gcloud("auth", "print-access-token")
    project_number = gcloud("projects", "describe", project, "--format=value(projectNumber)")
    if not token or not project_number.isdecimal():
        raise RuntimeError("Vérifie le compte Google actif et le projet.")

    test_id = f"grid-dlq-test-{uuid4().hex[:12]}"
    prefix = f"projects/{project}"
    topic = f"{prefix}/topics/{test_id}"
    dlq = f"{prefix}/topics/grid-telemetry-dlq"
    source_name = f"{test_id}-source"
    source = f"{prefix}/subscriptions/{source_name}"
    reader = f"{prefix}/subscriptions/{test_id}-reader"
    created = []

    try:
        pubsub_request(token, "GET", dlq)
        pubsub_request(token, "PUT", topic, {})
        created.append(topic)

        pubsub_request(token, "PUT", source, {
            "topic": topic,
            "ackDeadlineSeconds": 10,
            "messageRetentionDuration": "600s",
            "deadLetterPolicy": {"deadLetterTopic": dlq, "maxDeliveryAttempts": 5},
        })
        created.append(source)
        agent = f"serviceAccount:service-{project_number}@gcp-sa-pubsub.iam.gserviceaccount.com"
        gcloud("pubsub", "subscriptions", "add-iam-policy-binding", source_name,
               f"--project={project}", f"--member={agent}", "--role=roles/pubsub.subscriber")

        source_attribute = "attributes.CloudPubSubDeadLetterSourceSubscription"
        pubsub_request(token, "PUT", reader, {
            "topic": dlq,
            "messageRetentionDuration": "600s",
            "filter": f'{source_attribute} = "{source_name}" OR {source_attribute} = "{source}"',
        })
        created.append(reader)

        data = base64.b64encode(test_id.encode("utf-8")).decode("ascii")
        published = pubsub_request(token, "POST", f"{topic}:publish", {"messages": [{"data": data}]})
        original_id = published["messageIds"][0]
        print(f"Message de test {original_id} envoyé sur {test_id}.", flush=True)

        forwarded = wait_for_forwarding(token, source, reader, source_name)
        attempts = forwarded.get("attributes", {}).get("CloudPubSubDeadLetterSourceDeliveryCount", "inconnu")
        print(f"DLQ OK — message {forwarded['messageId']} redirigé depuis {source_name} ({attempts} tentatives).")
    finally:
        for resource in reversed(created):
            try:
                pubsub_request(token, "DELETE", resource)
            except (OSError, RuntimeError) as error:
                print(f"Nettoyage à terminer pour {resource} : {error}", file=sys.stderr)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--project", required=True, help="Identifiant du projet GCP de test.")
    args = parser.parse_args()
    try:
        smoke_test(args.project)
    except (OSError, RuntimeError) as error:
        sys.exit(str(error))
