import io
import unittest
from datetime import datetime, timezone

from simulator.telemetry import InvalidReading, iter_london_events, london_event


class LondonTelemetryTest(unittest.TestCase):
    def test_kaggle_row_becomes_stable_london_event(self):
        row = {
            "LCLid": "MAC000002",
            "DateTime": "2014-01-01 00:30:00",
            "KWH/hh (per half hour) ": "0.184",
        }
        ingestion = datetime(2026, 11, 24, 12, 0, tzinfo=timezone.utc)
        first = london_event(row, ingestion_time=ingestion)
        second = london_event(row, ingestion_time=ingestion)

        self.assertEqual(first, second)
        self.assertEqual(first["meter_id"], "MAC000002")
        self.assertEqual(first["event_time"], "2014-01-01T00:30:00Z")
        self.assertEqual(first["energy_kwh"], 0.184)
        self.assertEqual(first["source"], "STREAM_REPLAY")
        self.assertRegex(first["virtual_group_id"], r"^LONDON-GROUP-0[1-5]$")

    def test_missing_consumption_is_rejected(self):
        with self.assertRaises(InvalidReading):
            london_event({"LCLid": "MAC1", "DateTime": "2014-01-01", "energy_kwh": "Null"})

    def test_london_summer_time_is_converted_to_utc(self):
        event = london_event({
            "LCLid": "MAC1",
            "DateTime": "2013-07-01 12:00:00",
            "energy_kwh": "0.5",
        })
        self.assertEqual(event["event_time"], "2013-07-01T11:00:00Z")

    def test_reader_skips_invalid_rows_and_obeys_limit(self):
        stream = io.StringIO(
            "LCLid,DateTime,energy(kWh/hh)\n"
            "MAC1,2014-01-01 00:00:00,Null\n"
            "MAC1,2014-01-01 00:30:00,0.10\n"
            "MAC2,2014-01-01 00:30:00,0.20\n"
        )
        events = list(iter_london_events(stream, limit=1))
        self.assertEqual(len(events), 1)
        self.assertEqual(events[0]["energy_kwh"], 0.10)


if __name__ == "__main__":
    unittest.main()
