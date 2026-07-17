// ESP-NOW receiver — sits permanently on USB (currently the Lonely Binary
// board), receives packets from sender_esp_now.ino and prints them to Serial
// in a fixed text format that tools/live_plot.py and friends parse:
//
//   Accel  X:val  Y:val  Z:val    Gyro  X:val  Y:val  Z:val    Temp:val
//
// Do not change this print format without also updating the LINE_RE regex
// in every tools/*.py script that parses it.

#include <WiFi.h>
#include <esp_now.h>

typedef struct {
  int16_t accX, accY, accZ;
  int16_t temp;
  int16_t gyroX, gyroY, gyroZ;
} SensorPacket;

void onDataRecv(const esp_now_recv_info_t *info, const uint8_t *data, int len) {
  SensorPacket packet;
  memcpy(&packet, data, sizeof(packet));
  Serial.print("Accel  X:"); Serial.print(packet.accX);
  Serial.print("  Y:"); Serial.print(packet.accY);
  Serial.print("  Z:"); Serial.print(packet.accZ);
  Serial.print("    Gyro  X:"); Serial.print(packet.gyroX);
  Serial.print("  Y:"); Serial.print(packet.gyroY);
  Serial.print("  Z:"); Serial.print(packet.gyroZ);
  Serial.print("    Temp:"); Serial.println(packet.temp);
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
