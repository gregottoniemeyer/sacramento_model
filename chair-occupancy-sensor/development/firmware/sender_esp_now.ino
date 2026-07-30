// Chair sensor node — reads MPU-6050 at 100Hz, transmits every sample over
// ESP-NOW to the receiver board. Runs on the WEMOS/18650-holder ESP32,
// battery powered, no USB connection needed once flashed.
//
// Wiring (color convention): blue=VCC->3V3, green=GND->GND,
// yellow=SCL->GPIO22, red=SDA->GPIO21.
//
// NOTE: this transmits on every single sample (100 packets/sec) -- a lower-
// power redesign that only radios twice a second exists in
// ../proposed_2hz_radio_reduction/ but has not been flashed to any board yet.

#include <Wire.h>
#include <WiFi.h>
#include <esp_now.h>

const int MPU_ADDR = 0x68;
uint8_t receiverMac[] = {0x78, 0x1C, 0x3C, 0x35, 0x83, 0x6C};  // Lonely Binary receiver board

typedef struct {
  int16_t accX, accY, accZ;
  int16_t temp;
  int16_t gyroX, gyroY, gyroZ;
} SensorPacket;

SensorPacket packet;
unsigned long lastSample = 0;

void setup() {
  Serial.begin(115200);
  Wire.begin(21, 22);
  Wire.setClock(400000);
  Wire.beginTransmission(MPU_ADDR);
  Wire.write(0x6B);  // power management register
  Wire.write(0);     // wake the sensor up
  Wire.endTransmission(true);

  WiFi.mode(WIFI_STA);
  esp_now_init();
  esp_now_peer_info_t peerInfo = {};
  memcpy(peerInfo.peer_addr, receiverMac, 6);
  peerInfo.channel = 0;
  peerInfo.encrypt = false;
  esp_now_add_peer(&peerInfo);
}

void loop() {
  if (millis() - lastSample < 10) return;  // 10ms = 100Hz
  lastSample += 10;

  Wire.beginTransmission(MPU_ADDR);
  Wire.write(0x3B);  // starting register for accel data
  Wire.endTransmission(false);
  Wire.requestFrom(MPU_ADDR, 14, true);

  packet.accX = Wire.read() << 8 | Wire.read();
  packet.accY = Wire.read() << 8 | Wire.read();
  packet.accZ = Wire.read() << 8 | Wire.read();
  packet.temp = Wire.read() << 8 | Wire.read();
  packet.gyroX = Wire.read() << 8 | Wire.read();
  packet.gyroY = Wire.read() << 8 | Wire.read();
  packet.gyroZ = Wire.read() << 8 | Wire.read();

  esp_now_send(receiverMac, (uint8_t *)&packet, sizeof(packet));
}
