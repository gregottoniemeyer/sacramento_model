import unittest

from telemetry import controller


class ChairModelTests(unittest.TestCase):
    @staticmethod
    def sensor_source_without_reader():
        source = controller.SensorSource.__new__(controller.SensorSource)
        controller.Source.__init__(source)
        source.models = {
            c: controller.ChairModel()
            for c in range(1, controller.NUM_CHAIRS + 1)
        }
        source.last_seen = {
            c: None
            for c in range(1, controller.NUM_CHAIRS + 1)
        }
        source.last_peak = {
            c: 0
            for c in range(1, controller.NUM_CHAIRS + 1)
        }
        source.rotation_count = {
            c: 0
            for c in range(1, controller.NUM_CHAIRS + 1)
        }
        source.watershed_armed = True
        source.lock = controller.threading.Lock()
        return source

    def test_spare_sensor_eight_replaces_logical_chair_three(self):
        self.assertEqual(3, controller.logical_chair(8))
        self.assertIsNone(controller.logical_chair(3))
        self.assertEqual(2, controller.logical_chair(2))
        self.assertEqual(7, controller.logical_chair(7))

    def test_quiet_packets_do_not_activate_a_chair(self):
        model = controller.ChairModel()
        model.update(10.0, controller.PEAK_JUMP_RAW - 1)
        self.assertFalse(model.occupied)
        self.assertEqual(0.0, model.vote_frac)

    def test_major_motion_starts_exact_thirty_second_interval(self):
        model = controller.ChairModel()
        model.update(10.0, controller.PEAK_JUMP_RAW)
        self.assertTrue(model.occupied)
        self.assertEqual(40.0, model.occupied_until)
        self.assertEqual(1.0, model.vote_frac)

        model.update(39.999, 0)
        self.assertTrue(model.occupied)
        model.advance(40.0)
        self.assertFalse(model.occupied)
        self.assertEqual("30s interval expired", model.reason)

    def test_later_major_motion_renews_complete_interval(self):
        model = controller.ChairModel()
        model.update(10.0, 2000)
        model.update(25.0, 3000)
        self.assertEqual(55.0, model.occupied_until)
        model.advance(54.999)
        self.assertTrue(model.occupied)
        model.advance(55.0)
        self.assertFalse(model.occupied)

    def test_expiry_does_not_require_a_fresh_sensor_packet(self):
        model = controller.ChairModel()
        model.update(0.0, 5000)
        model.advance(30.0)
        self.assertFalse(model.occupied)

    def test_each_chair_is_an_independent_binary_timer(self):
        source = self.sensor_source_without_reader()
        source._ingest_summary_packet(2, 2000, 0, 10.0)
        source._ingest_summary_packet(4, 3000, 0, 15.0)
        self.assertEqual([0, 1, 0, 1, 0, 0, 0], source.chairs)

        source._ingest_summary_packet(2, 2500, 0, 25.0)
        source.poll(45.0)
        self.assertEqual([0, 1, 0, 0, 0, 0, 0], source.chairs)
        source.poll(55.0)
        self.assertEqual([0, 0, 0, 0, 0, 0, 0], source.chairs)

    def test_one_high_peak_only_activates_its_named_chair(self):
        source = self.sensor_source_without_reader()
        source._ingest_summary_packet(3, 65000, 0, 1.0)
        self.assertEqual([0, 0, 1, 0, 0, 0, 0], source.chairs)

    def test_subthreshold_motion_does_not_activate_a_chair(self):
        source = self.sensor_source_without_reader()
        source._ingest_summary_packet(2, controller.PEAK_JUMP_RAW - 1, 0, 1.0)
        self.assertEqual([0, 0, 0, 0, 0, 0, 0], source.chairs)

    def test_confirmed_rotation_activates_below_tap_threshold(self):
        source = self.sensor_source_without_reader()
        source._ingest_summary_packet(
            1, 200, 0, 1.0, controller.ROTATION_STD_RAW
        )
        self.assertEqual([0, 0, 0, 0, 0, 0, 0], source.chairs)
        source._ingest_summary_packet(
            1, 200, 0, 1.1, controller.ROTATION_STD_RAW
        )
        self.assertEqual([1, 0, 0, 0, 0, 0, 0], source.chairs)
        self.assertEqual(
            "confirmed rotation; 30s interval renewed",
            source.models[1].reason,
        )

    def test_single_rotation_spike_does_not_activate(self):
        source = self.sensor_source_without_reader()
        source._ingest_summary_packet(
            1, 100, 0, 1.0, controller.ROTATION_STD_RAW
        )
        source._ingest_summary_packet(
            1, 100, 0, 1.1, controller.ROTATION_STD_RAW - 1
        )
        source._ingest_summary_packet(
            1, 100, 0, 1.2, controller.ROTATION_STD_RAW
        )
        self.assertEqual([0, 0, 0, 0, 0, 0, 0], source.chairs)

    def test_watershed_clears_others_then_releases_everything(self):
        source = self.sensor_source_without_reader()
        source._ingest_summary_packet(2, 2000, 0, 10.0)
        source._ingest_summary_packet(4, 3000, 0, 11.0)
        source._ingest_summary_packet(7, 5000, 0, 12.0)
        self.assertEqual([0, 0, 0, 0, 0, 0, 1], source.chairs)
        self.assertEqual("cleared by Watershed", source.models[2].reason)
        self.assertEqual("cleared by Watershed", source.models[4].reason)

        source.poll(41.999)
        self.assertEqual([0, 0, 0, 0, 0, 0, 1], source.chairs)
        source.poll(42.0)
        self.assertEqual([0, 0, 0, 0, 0, 0, 0], source.chairs)

    def test_new_strong_input_ends_watershed_immediately(self):
        source = self.sensor_source_without_reader()
        source._ingest_summary_packet(7, 5000, 0, 10.0)
        source._ingest_summary_packet(2, controller.PEAK_JUMP_RAW - 1, 0, 11.0)
        self.assertEqual([0, 0, 0, 0, 0, 0, 1], source.chairs)

        source._ingest_summary_packet(2, 3000, 0, 12.0)
        self.assertEqual([0, 1, 0, 0, 0, 0, 0], source.chairs)
        self.assertEqual(
            "ended by newer strong chair input",
            source.models[7].reason,
        )

        # Repeated packets from the canceled rolling Watershed peak cannot
        # immediately take control back.
        source._ingest_summary_packet(7, 5000, 0, 12.1)
        self.assertEqual([0, 1, 0, 0, 0, 0, 0], source.chairs)
        source._ingest_summary_packet(7, 0, 0, 13.0)
        source._ingest_summary_packet(7, 5000, 0, 14.0)
        self.assertEqual([0, 0, 0, 0, 0, 0, 1], source.chairs)


if __name__ == "__main__":
    unittest.main()
