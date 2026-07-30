#include <WiFi.h>
#include <esp_wifi.h>
#include <esp_now.h>

uint8_t RECEIVER_MAC[6] = {0x78, 0x1C, 0x3C, 0x35, 0x83, 0x6C};

typedef struct {
  int16_t accX, accY, accZ;
  int16_t temp;
  int16_t gyroX, gyroY, gyroZ;
} SensorPacket;

typedef struct __attribute__((packed)) {
  uint8_t  version;
  uint8_t  flags;
  uint16_t seq;
  int16_t  accMeanX, accMeanY, accMeanZ;
  int16_t  gyroMeanX, gyroMeanY, gyroMeanZ;
  uint16_t gyroStdX, gyroStdY, gyroStdZ;
  uint8_t  bigDeltaCount;
  uint8_t  sampleCount;
  int16_t  temp;
  uint16_t touchRaw;
  uint16_t touchBaseline;
  uint16_t uptimeMin;
  uint16_t peakJump;
  int32_t  yawSumNew;
  uint8_t  nNew;
} SummaryPacket;

static_assert(sizeof(SummaryPacket) == 39, "SummaryPacket size changed -- update sender_summary.ino to match");
static_assert(sizeof(SensorPacket) == 14, "SensorPacket size changed -- v1 senders would stop being recognised");

const int NUM_CHAIRS = 8;

const uint8_t chairMacs[NUM_CHAIRS][6] = {
  {0x8C, 0x94, 0xDF, 0x46, 0xB5, 0x54},
  {0x88, 0xF1, 0x55, 0x30, 0xAF, 0xB4},
  {0x88, 0xF1, 0x55, 0x32, 0x49, 0xC4},
  {0x8C, 0x94, 0xDF, 0x45, 0xCA, 0x28},
  {0x88, 0xF1, 0x55, 0x30, 0xA6, 0x58},
  {0x8C, 0x94, 0xDF, 0x97, 0x4F, 0x34},
  {0x8C, 0x94, 0xDF, 0x45, 0xB3, 0xD0},

  {0x88, 0xF1, 0x55, 0x32, 0x5F, 0x6C},
};

int chairForMac(const uint8_t *mac) {
  for (int i = 0; i < NUM_CHAIRS; i++) {
    if (memcmp(mac, chairMacs[i], 6) == 0) return i + 1;
  }
  return 0;
}

void printChairPrefix(const uint8_t *mac) {
  int chair = chairForMac(mac);
  if (chair > 0) {
    Serial.print("Chair:"); Serial.print(chair);
  } else {

    Serial.print("Chair:?[");
    for (int i = 0; i < 6; i++) {
      if (mac[i] < 0x10) Serial.print('0');
      Serial.print(mac[i], HEX);
      if (i < 5) Serial.print(':');
    }
    Serial.print(']');
  }
}

void printMotion(int16_t ax, int16_t ay, int16_t az,
                 int16_t gx, int16_t gy, int16_t gz, int16_t temp) {
  Serial.print("  Accel  X:"); Serial.print(ax);
  Serial.print("  Y:"); Serial.print(ay);
  Serial.print("  Z:"); Serial.print(az);
  Serial.print("    Gyro  X:"); Serial.print(gx);
  Serial.print("  Y:"); Serial.print(gy);
  Serial.print("  Z:"); Serial.print(gz);
  Serial.print("    Temp:"); Serial.print(temp);
}

void onDataRecv(const esp_now_recv_info_t *info, const uint8_t *data, int len) {

  int rssi = info->rx_ctrl ? info->rx_ctrl->rssi : 0;

  if (len == (int)sizeof(SummaryPacket)) {
    SummaryPacket p;
    memcpy(&p, data, sizeof(p));
    printChairPrefix(info->src_addr);
    printMotion(p.accMeanX, p.accMeanY, p.accMeanZ,
                p.gyroMeanX, p.gyroMeanY, p.gyroMeanZ, p.temp);
    Serial.print("    Std  X:"); Serial.print(p.gyroStdX);
    Serial.print("  Y:"); Serial.print(p.gyroStdY);
    Serial.print("  Z:"); Serial.print(p.gyroStdZ);
    Serial.print("    Big:"); Serial.print(p.bigDeltaCount);
    Serial.print("  N:"); Serial.print(p.sampleCount);
    Serial.print("  Touch:"); Serial.print(p.touchRaw);
    Serial.print("  TBase:"); Serial.print(p.touchBaseline);
    Serial.print("  Peak:"); Serial.print(p.peakJump);
    Serial.print("  YawS:"); Serial.print(p.yawSumNew);
    Serial.print("  YawN:"); Serial.print(p.nNew);
    Serial.print("  Up:"); Serial.print(p.uptimeMin);
    Serial.print("  Seq:"); Serial.print(p.seq);
    Serial.print("  Flags:"); Serial.print(p.flags);
    Serial.print("  Rssi:"); Serial.println(rssi);

  } else if (len == (int)sizeof(SensorPacket)) {
    SensorPacket packet;
    memcpy(&packet, data, sizeof(packet));
    printChairPrefix(info->src_addr);
    printMotion(packet.accX, packet.accY, packet.accZ,
                packet.gyroX, packet.gyroY, packet.gyroZ, packet.temp);
    Serial.print("  Rssi:"); Serial.println(rssi);

  } else {

    printChairPrefix(info->src_addr);
    Serial.print("  BAD PACKET len:"); Serial.println(len);
  }
}

void setup() {
  Serial.begin(921600);
  WiFi.mode(WIFI_STA);

  esp_err_t macErr = esp_wifi_set_mac(WIFI_IF_STA, RECEIVER_MAC);

  uint8_t actual[6];
  esp_wifi_get_mac(WIFI_IF_STA, actual);
  bool ok = (macErr == ESP_OK) && (memcmp(actual, RECEIVER_MAC, 6) == 0);

  Serial.println();
  Serial.print("Receiver MAC: ");
  Serial.print(WiFi.macAddress());
  if (ok) {
    Serial.println("  [OK - matches the address senders transmit to]");
  } else {
    Serial.println("  [WRONG - senders transmit to 78:1C:3C:35:83:6C]");
    Serial.println("This board will receive NOTHING. esp_wifi_set_mac failed.");
  }

  if (esp_now_init() != ESP_OK) {
    Serial.println("ESP-NOW init failed");
    return;
  }
  esp_now_register_recv_cb(onDataRecv);
}

void loop() {}
