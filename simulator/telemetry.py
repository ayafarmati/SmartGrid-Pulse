import argparse
import json
import random
from datetime import datetime, timezone
from uuid import uuid4


# Puissances nominales utilisées uniquement pour les mesures simulées.
SUBSTATIONS = {
    "SUB-MADRID-01": 4500,
    "SUB-BARCELONA-02": 3200,
    "SUB-VALENCIA-03": 2100,
    "SUB-SEVILLE-04": 1800,
    "SUB-BILBAO-05": 1500,
}

# Chaque scénario force une seule mesure hors de son seuil d'alerte.
ANOMALIES = {
    "sous-frequence": ("frequency_hz", 49.7, "UNDER_FREQUENCY"),
    "surfrequence": ("frequency_hz", 50.3, "OVER_FREQUENCY"),
    "surtension": ("voltage_kv", 425.0, "OVERVOLTAGE"),
    "surchauffe": ("transformer_temp_c", 90.0, "OVERHEAT"),
}
SCENARIOS = ("normal", *ANOMALIES)


def generate_telemetry(device_id, nominal_mw, scenario="normal"):
    active_power = round(nominal_mw * random.uniform(0.8, 1.1), 2)
    metrics = {
        "active_power_mw": active_power,
        "reactive_power_mvar": round(active_power * 0.22, 2),
        "voltage_kv": round(random.uniform(396, 404), 2),
        "frequency_hz": round(random.uniform(49.95, 50.05), 3),
        "transformer_temp_c": round(random.uniform(55, 75), 1),
    }
    grid_status = "NORMAL"
    if scenario != "normal":
        metric, value, grid_status = ANOMALIES[scenario]
        metrics[metric] = value

    return {
        "event_id": str(uuid4()),
        "device_id": device_id,
        "timestamp_utc": datetime.now(timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z"),
        "metrics": metrics,
        "grid_status": grid_status,
        "is_alert": grid_status != "NORMAL",
    }


def generate_batch(scenario="normal"):
    """Produit un relevé par station, avec l'anomalie éventuelle à Madrid."""
    return [
        generate_telemetry(device_id, nominal_mw, scenario if index == 0 else "normal")
        for index, (device_id, nominal_mw) in enumerate(SUBSTATIONS.items())
    ]


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Générer cinq relevés SmartGrid Pulse en JSON.")
    parser.add_argument("--scenario", choices=SCENARIOS, default="normal")
    args = parser.parse_args()

    for event in generate_batch(args.scenario):
        print(json.dumps(event))
