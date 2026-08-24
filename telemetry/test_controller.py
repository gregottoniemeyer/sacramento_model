import unittest

from telemetry import controller


class ChairModelTests(unittest.TestCase):
    def test_quiet_packets_do_not_activate_a_chair(self):
        model = controller.ChairModel()
        model.update(10.0, controller.PEAK_JUMP_RAW - 1)
        self.assertFalse(model.occupied)
        self.assertEqual(0.0, model.vote_frac)

    def test_major_motion_starts_exact_sixty_second_interval(self):
        model = controller.ChairModel()
        model.update(10.0, controller.PEAK_JUMP_RAW)
        self.assertTrue(model.occupied)
        self.assertEqual(70.0, model.occupied_until)
        self.assertEqual(1.0, model.vote_frac)

        model.update(69.999, 0)
        self.assertTrue(model.occupied)
        model.advance(70.0)
        self.assertFalse(model.occupied)
        self.assertEqual("60s interval expired", model.reason)

    def test_later_major_motion_renews_complete_interval(self):
        model = controller.ChairModel()
        model.update(10.0, 2000)
        model.update(55.0, 3000)
        self.assertEqual(115.0, model.occupied_until)
        model.advance(114.999)
        self.assertTrue(model.occupied)
        model.advance(115.0)
        self.assertFalse(model.occupied)

    def test_expiry_does_not_require_a_fresh_sensor_packet(self):
        model = controller.ChairModel()
        model.update(0.0, 5000)
        model.advance(60.0)
        self.assertFalse(model.occupied)


if __name__ == "__main__":
    unittest.main()
