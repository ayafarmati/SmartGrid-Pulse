import io
import json
import sys
import unittest
from pathlib import Path

from jsonschema import Draft202012Validator, FormatChecker

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from replay.core import (  # noqa: E402
    ReplayContractError,
    deterministic_event_id,
    encode_message,
    ordered_unique,
    read_ndjson,
)


def event_at(timestamp: str) -> dict[str, object]:
    return {
        "event_time": timestamp,
        "actual_load_mw": 25_000,
        "weather": [
            {
                "city_name": "Madrid",
                "temperature_c": 18.5,
                "humidity_pct": 45,
                "wind_speed_m_s": 3.2,
            }
        ],
    }


class ReplayCoreTest(unittest.TestCase):
    def test_event_id_is_deterministic_across_timezones(self) -> None:
        self.assertEqual(
            deterministic_event_id("2018-01-01T01:00:00+01:00"),
            deterministic_event_id("2018-01-01T00:00:00Z"),
        )

    def test_ordering_and_deduplication(self) -> None:
        first = event_at("2018-01-01T00:00:00Z")
        second = event_at("2018-01-01T01:00:00Z")
        result = ordered_unique([second, first, first])
        self.assertEqual(2, len(result))
        self.assertEqual("2018-01-01T00:00:00Z", result[0]["event_time"])

    def test_message_attributes_match_payload(self) -> None:
        payload, attributes = encode_message(event_at("2018-01-01T00:00:00Z"))
        parsed = json.loads(payload)
        self.assertEqual(parsed["event_id"], attributes["event_id"])
        self.assertEqual("STREAM_REPLAY", attributes["source"])

        schema = json.loads((ROOT / "schemas" / "energy_replay_event.schema.json").read_text(encoding="utf-8"))
        Draft202012Validator(schema, format_checker=FormatChecker()).validate(parsed)

    def test_bad_ndjson_reports_contract_error(self) -> None:
        with self.assertRaises(ReplayContractError):
            list(read_ndjson(io.StringIO("not-json\n")))


if __name__ == "__main__":
    unittest.main()
