// Diagnostic utility, not part of the deployed system: reads the MPU-6050
// over I2C and prints values straight to Serial (no ESP-NOW, no receiver
// needed) so a board can be checked over just its USB cable. Same register
// read sequence as sender_esp_now.ino -- if this looks alive, that board's
// I2C wiring is good.

#include <Wire.h>

const int MPU_ADDR = 0x68;

void setup() {
  Serial.begin(115200);
  delay(500);
  Wire.begin(21, 22);       // SDA=21, SCL=22
  Wire.setClock(400000);    // match sender_esp_now.ino's speed

  Wire.beginTransmission(MPU_ADDR);
  Wire.write(0x6B);  // power management register
  Wire.write(0);     // wake the sensor up
  Wire.endTransmission(true);

  Serial.println("MPU-6050 read test starting...");
}

void loop() {
  Wire.beginTransmission(MPU_ADDR);
  Wire.write(0x3B);  // starting register for accel data
  Wire.endTransmission(false);
  Wire.requestFrom(MPU_ADDR, 14, true);

  int16_t accX = Wire.read() << 8 | Wire.read();
  int16_t accY = Wire.read() << 8 | Wire.read();
  int16_t accZ = Wire.read() << 8 | Wire.read();
  int16_t temp = Wire.read() << 8 | Wire.read();
  int16_t gyroX = Wire.read() << 8 | Wire.read();
  int16_t gyroY = Wire.read() << 8 | Wire.read();
  int16_t gyroZ = Wire.read() << 8 | Wire.read();

  Serial.print("Accel  X:"); Serial.print(accX);
  Serial.print("  Y:"); Serial.print(accY);
  Serial.print("  Z:"); Serial.print(accZ);
  Serial.print("    Gyro  X:"); Serial.print(gyroX);
  Serial.print("  Y:"); Serial.print(gyroY);
  Serial.print("  Z:"); Serial.print(gyroZ);
  Serial.print("    Temp:"); Serial.println(temp);

  delay(200);  // 5 samples/sec -- plenty fast to see wiggle, slow enough to read
}
