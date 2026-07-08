// Diagnostic utility, not part of the deployed system: confirms an MPU-6050
// (or any I2C device) responds on the bus. The MPU-6050 should show up at
// address 0x68. Useful any time a new board/sensor pairing needs verifying
// before trusting it in the real sender sketch.

#include <Wire.h>

void setup() {
  Serial.begin(115200);
  delay(500);
  Wire.begin(21, 22);  // SDA=21, SCL=22
  Serial.println("\nI2C scanner starting...");
}

void loop() {
  byte count = 0;
  Serial.println("Scanning...");
  for (byte addr = 1; addr < 127; addr++) {
    Wire.beginTransmission(addr);
    if (Wire.endTransmission() == 0) {
      Serial.print("  Found device at 0x");
      if (addr < 16) Serial.print("0");
      Serial.println(addr, HEX);
      count++;
    }
  }
  if (count == 0) Serial.println("  No I2C devices found.");
  Serial.println("Done.\n");
  delay(2000);
}
