// Diagnostic utility: find which GPIO drives the onboard LED on these
// WEMOS/Snvi ESP32 + 18650-holder boards. Not part of the deployed system.
//
// Why this exists: the status-indicator firmware needs to know the LED pin,
// and these boards are a generic clone whose pinout is not documented
// consistently. GPIO2 is the usual answer on ESP32 dev boards, but the
// 18650-shield variants have also been seen wired elsewhere, and the
// project's 2026-07-06 bring-up notes record "a basic blink sketch (LED on a
// pin)" without saying which pin it used.
//
// THE GROUPS ARE SELF-IDENTIFYING. Each candidate pin blinks a number of
// times equal to its position in the list, then pauses. So you do not need to
// know when the sweep started or count passes: just count the blinks in any
// one group and that number tells you the pin.
//
//     1 blink  = GPIO2       5 blinks = GPIO25
//     2 blinks = GPIO16      6 blinks = GPIO17
//     3 blinks = GPIO5       7 blinks = GPIO22
//     4 blinks = GPIO4
//
// (An earlier version of this sketch blinked every pin the same number of
// times and expected the pin to be identified by counting passes from the
// start of the sweep. That is unusable in practice -- there is no visible
// marker for where a sweep begins. Hence the encoding.)
//
// Candidates avoid anything the deployed system needs: GPIO21/22 are I2C to
// the MPU-6050 (22 is included last only to catch the case where the "LED" is
// really an I2C activity light), GPIO27 is the capacitive touch electrode,
// and the strapping pins (0, 12, 15) are left out because holding them at the
// wrong level breaks the next firmware upload.
//
// Run with the board on USB. Serial Monitor at 115200 is optional -- the
// blink count is the answer, the serial output just mirrors it.

const int CANDIDATES[] = {2, 16, 5, 4, 25, 17, 22};
const int NUM_CANDIDATES = sizeof(CANDIDATES) / sizeof(CANDIDATES[0]);

const int ON_MS = 200;
const int OFF_MS = 250;
const int GROUP_GAP_MS = 2500;   // long enough that groups never run together
const int SWEEP_GAP_MS = 5000;   // longer still, so a full sweep is obvious

void setup() {
  Serial.begin(115200);
  delay(500);
  Serial.println();
  Serial.println("LED pin probe -- blink COUNT identifies the pin");
  Serial.println("  1 blink = GPIO2    2 = GPIO16   3 = GPIO5   4 = GPIO4");
  Serial.println("  5 blinks = GPIO25  6 = GPIO17   7 = GPIO22");
  Serial.println("Count the blinks in any one group. Long pause = next group.");
  Serial.println();

  for (int i = 0; i < NUM_CANDIDATES; i++) {
    pinMode(CANDIDATES[i], OUTPUT);
    digitalWrite(CANDIDATES[i], LOW);
  }
}

void loop() {
  for (int i = 0; i < NUM_CANDIDATES; i++) {
    int pin = CANDIDATES[i];
    int blinks = i + 1;

    Serial.print(blinks);
    Serial.print(blinks == 1 ? " blink  -> GPIO" : " blinks -> GPIO");
    Serial.println(pin);

    for (int b = 0; b < blinks; b++) {
      digitalWrite(pin, HIGH);
      delay(ON_MS);
      digitalWrite(pin, LOW);
      delay(OFF_MS);
    }
    delay(GROUP_GAP_MS);
  }

  Serial.println("--- sweep complete, repeating ---");
  Serial.println();
  delay(SWEEP_GAP_MS);
}
