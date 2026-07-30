// PROPOSED, NOT YET FLASHED TO ANY BOARD (paused 2026-07-07 to focus on the
// occupancy model first). Keeps sampling the MPU-6050 at 100Hz internally
// but only transmits a compact on-device-computed summary twice a second
// (2Hz) instead of every sample, cutting radio transmissions ~50x -- the
// actual battery-draining part -- with no loss of signal quality (the
// mean/activity stats here are computed from all 50 real samples per
// window, same or better than the current 100Hz-stream approach).
//
// If resumed: the occupancy model's constants (delta/debounce/hold) were
// tuned against a 1s window computed client-side from a 100Hz stream: they
// will likely need re-tuning for a 500ms on-device window. Also needs a
// matching receiver_2hz_summary.ino (same folder) flashed at the same time.

#include <Wire.h>
#include <WiFi.h>
#include <esp_now.h>
#include <math.h>

const int MPU_ADDR = 0x68;
uint8_t receiverMac[] = {0x78, 0x1C, 0x3C, 0x35, 0x83, 0x6C};
const unsigned long WINDOW_MS = 500;  // send twice a second

typedef struct {
  int16_t accMeanX, accMeanY, accMeanZ;
  int16_t gyroMeanX, gyroMeanY, gyroMeanZ;
  uint16_t accActivity;   // max per-axis std-dev over the window
  uint16_t gyroActivity;
  int16_t temp;
} SummaryPacket;

SummaryPacket packet;
unsigned long lastSample = 0;
unsigned long lastSend = 0;
long sumAcc[3] = {0,0,0}, sumSqAcc[3] = {0,0,0};
long sumGyro[3] = {0,0,0}, sumSqGyro[3] = {0,0,0};
int windowCount = 0;
int16_t lastTemp = 0;

void setup() {
  Serial.begin(115200);
  Wire.begin(21, 22);
  Wire.setClock(400000);
  Wire.beginTransmission(MPU_ADDR);
  Wire.write(0x6B);
  Wire.write(0);
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
  // Sample the sensor at the same 100Hz rate as the deployed sketch.
  if (millis() - lastSample >= 10) {
    lastSample += 10;

    Wire.beginTransmission(MPU_ADDR);
    Wire.write(0x3B);
    Wire.endTransmission(false);
    Wire.requestFrom(MPU_ADDR, 14, true);

    int16_t ax = Wire.read() << 8 | Wire.read();
    int16_t ay = Wire.read() << 8 | Wire.read();
    int16_t az = Wire.read() << 8 | Wire.read();
    lastTemp   = Wire.read() << 8 | Wire.read();
    int16_t gx = Wire.read() << 8 | Wire.read();
    int16_t gy = Wire.read() << 8 | Wire.read();
    int16_t gz = Wire.read() << 8 | Wire.read();

    sumAcc[0] += ax; sumAcc[1] += ay; sumAcc[2] += az;
    sumSqAcc[0] += (long)ax * ax; sumSqAcc[1] += (long)ay * ay; sumSqAcc[2] += (long)az * az;
    sumGyro[0] += gx; sumGyro[1] += gy; sumGyro[2] += gz;
    sumSqGyro[0] += (long)gx * gx; sumSqGyro[1] += (long)gy * gy; sumSqGyro[2] += (long)gz * gz;
    windowCount++;
  }

  // Only radio out a summary twice a second.
  if (millis() - lastSend >= WINDOW_MS && windowCount > 0) {
    lastSend = millis();

    float accActivity = 0, gyroActivity = 0;
    for (int i = 0; i < 3; i++) {
      float meanA = sumAcc[i] / (float)windowCount;
      float varA = sumSqAcc[i] / (float)windowCount - meanA * meanA;
      accActivity = max(accActivity, sqrtf(max(varA, 0.0f)));

      float meanG = sumGyro[i] / (float)windowCount;
      float varG = sumSqGyro[i] / (float)windowCount - meanG * meanG;
      gyroActivity = max(gyroActivity, sqrtf(max(varG, 0.0f)));
    }

    packet.accMeanX = sumAcc[0] / windowCount;
    packet.accMeanY = sumAcc[1] / windowCount;
    packet.accMeanZ = sumAcc[2] / windowCount;
    packet.gyroMeanX = sumGyro[0] / windowCount;
    packet.gyroMeanY = sumGyro[1] / windowCount;
    packet.gyroMeanZ = sumGyro[2] / windowCount;
    packet.accActivity = (uint16_t)accActivity;
    packet.gyroActivity = (uint16_t)gyroActivity;
    packet.temp = lastTemp;

    esp_now_send(receiverMac, (uint8_t *)&packet, sizeof(packet));

    for (int i = 0; i < 3; i++) { sumAcc[i]=0; sumSqAcc[i]=0; sumGyro[i]=0; sumSqGyro[i]=0; }
    windowCount = 0;
  }
}
