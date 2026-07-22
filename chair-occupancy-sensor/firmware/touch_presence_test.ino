// Experiment, not part of the deployed system: capacitive presence sensing
// on the chair, at Greg's suggestion (email 2026-07-21, "try using a
// capacitance loop to sense if a body is present on the chair").
//
// Why this is worth trying: the MPU-6050 only ever sees *motion*, so the
// occupancy model has to infer stillness-with-a-person-in-it from decay
// (see "Current occupancy model" in ../README.md). A capacitive electrode
// measures *presence* directly and continuously, which is exactly the
// signal the two known weaknesses need:
//   - a statue-sitter no longer depends on the 90s decay being generous
//   - a knock on an empty chair no longer reads OCCUPIED until it decays
//
// How it works: touchRead() drives the pin and times how long it takes to
// discharge. A nearby human body adds capacitance to the electrode, so the
// returned count goes DOWN when someone sits. Bigger electrode = bigger
// swing; this is why a loop of wire (or the seat pan itself) works far
// better than a bare pin.
//
// Wiring: one electrode wire from GPIO27 (touch channel T7) to whatever
// you're sensing with. Two electrode options to compare:
//   (a) LOOP  — a single loop of insulated wire taped under the seat
//               cushion, as large as the seat allows.
//   (b) SEAT  — the metal seat pan itself used as the electrode.
// Try (b) too, and probably first: these are metal swivel seats, and a
// grounded/floating metal pan sitting between a loop and the sitter will
// shield option (a) badly. Put a ~1M series resistor between the pin and
// the electrode either way -- it costs a little sensitivity and protects
// the GPIO from static off a person crossing a carpet.
//
// Two caveats to expect in the data, so they don't read as "it doesn't
// work":
//   - The board is battery powered and therefore floating (no earth
//     reference), which makes self-capacitance sensing weaker than the
//     same rig on a USB-tethered board. Compare on battery, not just on
//     USB, before judging it.
//   - Raw counts drift with temperature and humidity over tens of minutes,
//     so a fixed threshold will not survive a gallery day. This sketch
//     deliberately baselines ONCE at boot and prints raw values, so the
//     drift is visible in the recording rather than hidden by an
//     auto-baseline. A deployed version needs a slow baseline tracker that
//     only adapts while the chair is known-empty.

const int TOUCH_PIN = T7;      // GPIO27 -- free (I2C uses 21/22), not a strapping pin
const int BASELINE_SAMPLES = 64;

uint32_t baseline = 0;

void setup() {
  Serial.begin(115200);
  delay(500);

  // Baseline the EMPTY chair. Nobody sits, nobody leans on it, until the
  // "ready" line prints.
  Serial.println("Baselining -- keep the chair empty and stand clear...");
  uint32_t sum = 0;
  for (int i = 0; i < BASELINE_SAMPLES; i++) {
    sum += touchRead(TOUCH_PIN);
    delay(20);
  }
  baseline = sum / BASELINE_SAMPLES;

  Serial.print("Touch presence test ready. Empty-chair baseline: ");
  Serial.println(baseline);
  Serial.println("raw\tdelta\tpct");
}

void loop() {
  uint32_t raw = touchRead(TOUCH_PIN);

  // Positive delta = capacitance added = something conductive (a person)
  // is near the electrode.
  int32_t delta = (int32_t)baseline - (int32_t)raw;
  float pct = baseline ? (100.0f * delta / baseline) : 0.0f;

  Serial.print(raw);
  Serial.print('\t');
  Serial.print(delta);
  Serial.print('\t');
  Serial.println(pct, 1);

  delay(200);  // 5 samples/sec -- matches mpu_read_test.ino's pace
}
