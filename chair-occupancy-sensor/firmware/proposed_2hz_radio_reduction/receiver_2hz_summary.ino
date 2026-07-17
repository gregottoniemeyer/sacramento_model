// PROPOSED, NOT YET FLASHED -- pairs with sender_2hz_summary.ino in this
// same folder. See that file's header comment for status/context.

#include <WiFi.h>
#include <esp_now.h>

typedef struct {
  int16_t accMeanX, accMeanY, accMeanZ;
  int16_t gyroMeanX, gyroMeanY, gyroMeanZ;
  uint16_t accActivity;
  uint16_t gyroActivity;
  int16_t temp;
} SummaryPacket;

void onDataRecv(const esp_now_recv_info_t *info, const uint8_t *data, int len) {
  SummaryPacket p;
  memcpy(&p, data, sizeof(p));
  Serial.print("Accel  X:"); Serial.print(p.accMeanX);
  Serial.print("  Y:"); Serial.print(p.accMeanY);
  Serial.print("  Z:"); Serial.print(p.accMeanZ);
  Serial.print("    Gyro  X:"); Serial.print(p.gyroMeanX);
  Serial.print("  Y:"); Serial.print(p.gyroMeanY);
  Serial.print("  Z:"); Serial.print(p.gyroMeanZ);
  Serial.print("    AccAct:"); Serial.print(p.accActivity);
  Serial.print("  GyroAct:"); Serial.print(p.gyroActivity);
  Serial.print("    Temp:"); Serial.println(p.temp);
}

void setup() {
  Serial.begin(115200);
  WiFi.mode(WIFI_STA);
  if (esp_now_init() != ESP_OK) {
    Serial.println("ESP-NOW init failed");
    return;
  }
  esp_now_register_recv_cb(onDataRecv);
}

void loop() {}
