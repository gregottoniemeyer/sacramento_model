const int SDA_PIN = 21;
const int SCL_PIN = 22;

const int SAMPLES = 50;
const int CONNECTED_PCT = 80;

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
