// Diagnostic utility: when i2c_scanner finds NOTHING, this says WHICH wire is
// at fault. Not part of the deployed system.
//
// Why it works: a GY-521 carries its own pull-up resistors to VCC on SDA and
// SCL. So with the module powered, a properly connected data line is pulled
// HIGH even against the ESP32's much weaker internal pull-down. A line that
// reads LOW is not electrically reaching the module.
//
// This closes a real gap in the escalation ladder in README.md. i2c_scanner
// distinguishes a cold joint from a solder bridge, but a clean "No I2C
// devices found" still leaves you guessing which of VCC / GND / SDA / SCL is
// the problem. The module's own power LED covers VCC and GND. This covers the
// other two.
//
// Found the real fault on 2026-07-29: a freshly installed replacement module
// read SDA high 100% and SCL high 0%. Power was fine and the LED was lit,
// which is exactly the misleading case -- NOTES.md already records this
// signature for friction-fit connections ("SDA/SCL never made reliable
// contact even though VCC/GND did, their own power LED lit").
//
// If SCL specifically reads dead on a new module, check the wire is on SCL
// and not on the adjacent XCL. XCL is the auxiliary clock pin and has no
// pull-up, so it produces precisely this reading.
//
// Reading:
//   both HIGH -> both data wires connected; look elsewhere (or a dead module)
//   one LOW   -> that wire is the broken one
//   both LOW  -> neither data wire is making contact
//
// Run with the board on USB, Serial Monitor at 115200.

const int SDA_PIN = 21;   // red wire, per the project colour convention
const int SCL_PIN = 22;   // yellow wire

const int SAMPLES = 50;
const int CONNECTED_PCT = 80;   // a connected line sits high essentially always

void setup() {
  Serial.begin(115200);
  delay(400);
  Serial.println();
  Serial.println("I2C line check -- which data wire is connected?");
  Serial.println("(the module must be POWERED: check its own LED first)");
  Serial.println();
  pinMode(SDA_PIN, INPUT_PULLDOWN);
  pinMode(SCL_PIN, INPUT_PULLDOWN);
}

void loop() {
  int sda = 0, scl = 0;
  for (int i = 0; i < SAMPLES; i++) {
    sda += digitalRead(SDA_PIN);
    scl += digitalRead(SCL_PIN);
    delay(2);
  }
  int sdaPct = sda * 100 / SAMPLES;
  int sclPct = scl * 100 / SAMPLES;

  Serial.print("SDA(GPIO"); Serial.print(SDA_PIN);
  Serial.print(", red) high "); Serial.print(sdaPct); Serial.print("%   ");
  Serial.print("SCL(GPIO"); Serial.print(SCL_PIN);
  Serial.print(", yellow) high "); Serial.print(sclPct); Serial.print("%   -> ");

  bool sdaOk = sdaPct >= CONNECTED_PCT;
  bool sclOk = sclPct >= CONNECTED_PCT;
  if (sdaOk && sclOk)       Serial.println("BOTH CONNECTED");
  else if (!sdaOk && !sclOk) Serial.println("NEITHER data wire connected");
  else if (!sdaOk)           Serial.println("SDA (red, GPIO21) NOT CONNECTED");
  else                       Serial.println("SCL (yellow, GPIO22) NOT CONNECTED -- check it is on SCL, not XCL");

  delay(800);
}
