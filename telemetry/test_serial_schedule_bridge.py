import datetime as dt
import unittest
from zoneinfo import ZoneInfo

from telemetry.serial_schedule_bridge import gallery_schedule, schedule_command


PACIFIC = ZoneInfo("America/Los_Angeles")


class GalleryScheduleTests(unittest.TestCase):
    def at(self, year, month, day, hour, minute=0, second=0):
        return dt.datetime(
            year, month, day, hour, minute, second, tzinfo=PACIFIC
        )

    def test_open_interval_includes_nine_am(self):
        self.assertEqual((True, 0), gallery_schedule(self.at(2026, 8, 27, 9)))
        self.assertEqual((True, 0), gallery_schedule(self.at(2026, 8, 27, 20, 59)))

    def test_closed_interval_starts_at_nine_pm(self):
        self.assertEqual(
            (False, 12 * 60 * 60),
            gallery_schedule(self.at(2026, 8, 27, 21)),
        )

    def test_before_open_counts_down_to_nine(self):
        self.assertEqual(
            (False, 30 * 60),
            gallery_schedule(self.at(2026, 8, 27, 8, 30)),
        )

    def test_fall_dst_night_uses_elapsed_seconds(self):
        self.assertEqual(
            (False, 13 * 60 * 60),
            gallery_schedule(self.at(2026, 10, 31, 21)),
        )

    def test_spring_dst_night_uses_elapsed_seconds(self):
        self.assertEqual(
            (False, 11 * 60 * 60),
            gallery_schedule(self.at(2027, 3, 13, 21)),
        )

    def test_wire_command_is_compact_ascii(self):
        self.assertEqual(
            b"GALLERY 0 1800\n",
            schedule_command(self.at(2026, 8, 27, 8, 30)),
        )


if __name__ == "__main__":
    unittest.main()
