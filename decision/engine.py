"""Moteur de règles explicable appliqué aux quatre prédictions métier."""

from __future__ import annotations

import hashlib
from dataclasses import asdict, dataclass
from datetime import datetime


@dataclass(frozen=True)
class DecisionThresholds:
    warning_residual_demand_mw: float = 24_000
    high_residual_demand_mw: float = 30_000
    warning_price_eur_mwh: float = 120
    high_price_eur_mwh: float = 180
    warning_load_error_pct: float = 5
    high_load_error_pct: float = 10
    minimum_renewable_coverage_pct: float = 15


@dataclass(frozen=True)
class DecisionInput:
    target_time_utc: str
    predicted_demand_mw: float
    predicted_solar_mw: float
    predicted_wind_mw: float
    predicted_price_eur_mwh: float
    actual_demand_mw: float | None = None
    demand_model_version: str = "unknown"
    solar_model_version: str = "unknown"
    wind_model_version: str = "unknown"
    price_model_version: str = "unknown"


def _validate(values: DecisionInput) -> None:
    datetime.fromisoformat(values.target_time_utc.replace("Z", "+00:00"))
    if values.predicted_demand_mw <= 0:
        raise ValueError("predicted_demand_mw doit être strictement positif")
    if values.predicted_solar_mw < 0 or values.predicted_wind_mw < 0:
        raise ValueError("les productions prédites ne peuvent pas être négatives")


def evaluate(
    values: DecisionInput,
    thresholds: DecisionThresholds = DecisionThresholds(),
    rule_version: str = "energy-v1",
) -> dict[str, object]:
    """Calcule indicateurs, anomalie, vigilance et recommandations explicables."""
    _validate(values)
    residual = max(
        values.predicted_demand_mw - values.predicted_solar_mw - values.predicted_wind_mw,
        0,
    )
    solar_coverage = 100 * values.predicted_solar_mw / values.predicted_demand_mw
    wind_coverage = 100 * values.predicted_wind_mw / values.predicted_demand_mw
    renewable_coverage = solar_coverage + wind_coverage

    load_error_pct = None
    if values.actual_demand_mw is not None:
        load_error_pct = 100 * abs(values.actual_demand_mw - values.predicted_demand_mw) / values.predicted_demand_mw

    high_reasons: list[str] = []
    warning_reasons: list[str] = []
    if residual >= thresholds.high_residual_demand_mw:
        high_reasons.append("RESIDUAL_DEMAND_HIGH")
    elif residual >= thresholds.warning_residual_demand_mw:
        warning_reasons.append("RESIDUAL_DEMAND_WARNING")
    if values.predicted_price_eur_mwh >= thresholds.high_price_eur_mwh:
        high_reasons.append("PRICE_HIGH")
    elif values.predicted_price_eur_mwh >= thresholds.warning_price_eur_mwh:
        warning_reasons.append("PRICE_WARNING")
    if load_error_pct is not None:
        if load_error_pct >= thresholds.high_load_error_pct:
            high_reasons.append("LOAD_FORECAST_ERROR_HIGH")
        elif load_error_pct >= thresholds.warning_load_error_pct:
            warning_reasons.append("LOAD_FORECAST_ERROR_WARNING")
    if renewable_coverage < thresholds.minimum_renewable_coverage_pct:
        warning_reasons.append("RENEWABLE_COVERAGE_LOW")

    if high_reasons:
        level, reasons = "HIGH_VIGILANCE", high_reasons + warning_reasons
    elif warning_reasons:
        level, reasons = "WARNING", warning_reasons
    else:
        level, reasons = "NORMAL", ["OPERATING_RANGE_NORMAL"]

    recommendations: list[str] = []
    if any(reason.startswith("RESIDUAL_DEMAND") for reason in reasons):
        recommendations.append("Vérifier les réserves pilotables et la flexibilité de la demande")
    if any(reason.startswith("PRICE") for reason in reasons):
        recommendations.append("Décaler les charges non critiques hors de l'horizon de prix élevé")
    if "RENEWABLE_COVERAGE_LOW" in reasons:
        recommendations.append("Surveiller la production renouvelable et préparer une capacité de remplacement")
    if any("FORECAST_ERROR" in reason for reason in reasons):
        recommendations.append("Contrôler la dérive du modèle et programmer un réentraînement")
    if not recommendations:
        recommendations.append("Maintenir la surveillance normale")

    versions = "|".join([
        values.demand_model_version,
        values.solar_model_version,
        values.wind_model_version,
        values.price_model_version,
    ])
    decision_id = hashlib.sha256(
        f"{values.target_time_utc}|{versions}|{rule_version}".encode()
    ).hexdigest()[:32]

    return {
        "decision_id": decision_id,
        "target_time_utc": values.target_time_utc,
        "vigilance_level": level,
        "residual_demand_mw": round(residual, 3),
        "solar_coverage_pct": round(solar_coverage, 3),
        "wind_coverage_pct": round(wind_coverage, 3),
        "renewable_coverage_pct": round(renewable_coverage, 3),
        "load_error_pct": None if load_error_pct is None else round(load_error_pct, 3),
        "is_anomaly": load_error_pct is not None and load_error_pct >= thresholds.warning_load_error_pct,
        "reason_codes": reasons,
        "recommendations": recommendations,
        "rule_version": rule_version,
        "model_versions": {
            "demand": values.demand_model_version,
            "solar": values.solar_model_version,
            "wind": values.wind_model_version,
            "price": values.price_model_version,
        },
        "thresholds": asdict(thresholds),
    }
