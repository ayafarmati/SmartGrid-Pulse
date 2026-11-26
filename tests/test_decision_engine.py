import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from decision.engine import DecisionInput, evaluate  # noqa: E402


class DecisionEngineTest(unittest.TestCase):
    def test_normal_operation(self) -> None:
        result = evaluate(
            DecisionInput(
                target_time_utc="2018-01-01T00:00:00Z",
                predicted_demand_mw=20_000,
                predicted_solar_mw=4_000,
                predicted_wind_mw=5_000,
                predicted_price_eur_mwh=60,
            )
        )
        self.assertEqual("NORMAL", result["vigilance_level"])
        self.assertFalse(result["is_anomaly"])

    def test_price_and_residual_trigger_high_vigilance(self) -> None:
        result = evaluate(
            DecisionInput(
                target_time_utc="2018-01-01T01:00:00Z",
                predicted_demand_mw=40_000,
                predicted_solar_mw=1_000,
                predicted_wind_mw=2_000,
                predicted_price_eur_mwh=200,
            )
        )
        self.assertEqual("HIGH_VIGILANCE", result["vigilance_level"])
        self.assertIn("PRICE_HIGH", result["reason_codes"])
        self.assertIn("RESIDUAL_DEMAND_HIGH", result["reason_codes"])

    def test_actual_vs_previous_prediction_creates_anomaly(self) -> None:
        result = evaluate(
            DecisionInput(
                target_time_utc="2018-01-01T02:00:00Z",
                predicted_demand_mw=20_000,
                predicted_solar_mw=3_000,
                predicted_wind_mw=5_000,
                predicted_price_eur_mwh=70,
                actual_demand_mw=23_000,
            )
        )
        self.assertTrue(result["is_anomaly"])
        self.assertIn("LOAD_FORECAST_ERROR_HIGH", result["reason_codes"])


if __name__ == "__main__":
    unittest.main()
