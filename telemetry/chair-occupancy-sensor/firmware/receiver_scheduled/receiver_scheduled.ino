#include <WiFi.h>
#include <esp_wifi.h>
#include <esp_now.h>

// This remains the destination MAC compiled into every deployed sender.
uint8_t RECEIVER_MAC[6] = {0x78, 0x1C, 0x3C, 0x35, 0x83, 0x6C};
const uint8_t ESPNOW_CHANNEL = 1;

// A scheduled sender sets this bit in its normal SummaryPacket.  Old senders
// never set it and continue to work without receiving any extra traffic.
const uint8_t FLAG_SCHEDULE_REQUEST = 0x20;

const uint32_t SCHEDULE_MAGIC = 0x53434831UL;  // ASCII "SCH1"
const uint8_t SCHEDULE_VERSION = 1;
const uint8_t SCHEDULE_VALID = 0x01;
const uint8_t GALLERY_OPEN = 0x02;
const uint32_t HOST_SCHEDULE_STALE_MS = 20000;
const uint32_t MAX_CLOSED_SECONDS = 14UL * 60UL * 60UL;

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

typedef struct __attribute__((packed)) {
  uint32_t magic;
  uint8_t version;
  uint8_t flags;
  uint16_t reserved;
  uint32_t secondsUntilOpen;
  uint32_t receiverUptimeS;
} SchedulePacket;

static_assert(sizeof(SummaryPacket) == 39,
              "SummaryPacket must remain compatible with deployed senders");
static_assert(sizeof(SensorPacket) == 14,
              "SensorPacket must remain compatible with v1 senders");
static_assert(sizeof(SchedulePacket) == 16,
              "SchedulePacket wire size changed");

const int NUM_CHAIRS = 8;
const uint8_t chairMacs[NUM_CHAIRS][6] = {
  {0x8C, 0x94, 0xDF, 0x46, 0xB5, 0x54},
  {0x88, 0xF1, 0x55, 0x30, 0xAF, 0xB4},
  {0x88, 0xF1, 0x55, 0x32, 0x49, 0xC4},
  {0x8C, 0x94, 0xDF, 0x45, 0xCA, 0x28},
  {0x88, 0xF1, 0x55, 0x30, 0xA6, 0x58},
  {0x8C, 0x94, 0xDF, 0x97, 0x4F, 0x34},
  {0x8C, 0x94, 0xDF, 0x45, 0xB3, 0xD0},
  // Receiver slot 8 is the replacement mapped to logical chair 3 / Gold Rush.
  {0x88, 0xF1, 0x55, 0x32, 0x5F, 0x6C},
};

bool radioReady = false;
uint8_t radioStartFailures = 0;
uint32_t lastRadioStartMs = 0;

bool scheduleValid = false;
bool scheduleOpen = true;
uint32_t scheduleSecondsUntilOpen = 0;
uint32_t scheduleUpdatedMs = 0;

char hostCommand[64];
uint8_t hostCommandLength = 0;

portMUX_TYPE requestMux = portMUX_INITIALIZER_UNLOCKED;
volatile bool scheduleRequestPending = false;
uint8_t scheduleRequestMac[6] = {};

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
    return;
  }
  Serial.print("Chair:?[");
  for (int i = 0; i < 6; i++) {
    if (mac[i] < 0x10) Serial.print('0');
    Serial.print(mac[i], HEX);
    if (i < 5) Serial.print(':');
  }
  Serial.print(']');
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

void queueScheduleRequest(const uint8_t *mac) {
  portENTER_CRITICAL(&requestMux);
  memcpy(scheduleRequestMac, mac, 6);
  scheduleRequestPending = true;
  portEXIT_CRITICAL(&requestMux);
}

void onDataRecv(const esp_now_recv_info_t *info, const uint8_t *data, int len) {
  int rssi = info->rx_ctrl ? info->rx_ctrl->rssi : 0;

  if (len == (int)sizeof(SummaryPacket)) {
    SummaryPacket packet;
    memcpy(&packet, data, sizeof(packet));
    printChairPrefix(info->src_addr);
    printMotion(packet.accMeanX, packet.accMeanY, packet.accMeanZ,
                packet.gyroMeanX, packet.gyroMeanY, packet.gyroMeanZ,
                packet.temp);
    Serial.print("    Std  X:"); Serial.print(packet.gyroStdX);
    Serial.print("  Y:"); Serial.print(packet.gyroStdY);
    Serial.print("  Z:"); Serial.print(packet.gyroStdZ);
    Serial.print("    Big:"); Serial.print(packet.bigDeltaCount);
    Serial.print("  N:"); Serial.print(packet.sampleCount);
    Serial.print("  Touch:"); Serial.print(packet.touchRaw);
    Serial.print("  TBase:"); Serial.print(packet.touchBaseline);
    Serial.print("  Peak:"); Serial.print(packet.peakJump);
    Serial.print("  YawS:"); Serial.print(packet.yawSumNew);
    Serial.print("  YawN:"); Serial.print(packet.nNew);
    Serial.print("  Up:"); Serial.print(packet.uptimeMin);
    Serial.print("  Seq:"); Serial.print(packet.seq);
    Serial.print("  Flags:"); Serial.print(packet.flags);
    Serial.print("  Rssi:"); Serial.println(rssi);

    if (packet.flags & FLAG_SCHEDULE_REQUEST) {
      queueScheduleRequest(info->src_addr);
    }
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

bool startRadio() {
  lastRadioStartMs = millis();
  if (!WiFi.mode(WIFI_STA)) return false;

  esp_err_t macError = esp_wifi_set_mac(WIFI_IF_STA, RECEIVER_MAC);
  esp_err_t channelError =
      esp_wifi_set_channel(ESPNOW_CHANNEL, WIFI_SECOND_CHAN_NONE);
  if (macError != ESP_OK || channelError != ESP_OK) {
    WiFi.mode(WIFI_OFF);
    return false;
  }
  if (esp_now_init() != ESP_OK) {
    WiFi.mode(WIFI_OFF);
    return false;
  }
  if (esp_now_register_recv_cb(onDataRecv) != ESP_OK) {
    esp_now_deinit();
    WiFi.mode(WIFI_OFF);
    return false;
  }
  radioReady = true;
  radioStartFailures = 0;
  return true;
}

void applyHostCommand() {
  unsigned int openValue = 0;
  unsigned long secondsUntilOpen = 0;
  if (sscanf(hostCommand, "GALLERY %u %lu",
             &openValue, &secondsUntilOpen) != 2) return;
  if (openValue > 1 || secondsUntilOpen > MAX_CLOSED_SECONDS) return;
  if (openValue == 0 && secondsUntilOpen == 0) return;

  scheduleOpen = openValue == 1;
  scheduleSecondsUntilOpen = scheduleOpen ? 0 : secondsUntilOpen;
  scheduleUpdatedMs = millis();
  scheduleValid = true;

  // Repeat this acknowledgement for every five-second host update. Besides
  // confirming the receiver's clock link, this lets chair_state distinguish
  // a live OPEN/CLOSED clock from an old line left in the serial log.
  Serial.print("Gallery clock: ");
  Serial.print(scheduleOpen ? "OPEN" : "CLOSED");
  if (!scheduleOpen) {
    Serial.print(" until open:");
    Serial.print(scheduleSecondsUntilOpen);
    Serial.print('s');
  }
  Serial.println();
}

void readHostCommands() {
  while (Serial.available() > 0) {
    char value = (char)Serial.read();
    if (value == '\r') continue;
    if (value == '\n') {
      hostCommand[hostCommandLength] = '\0';
      applyHostCommand();
      hostCommandLength = 0;
      continue;
    }
    if (value >= 32 && value <= 126 &&
        hostCommandLength + 1 < sizeof(hostCommand)) {
      hostCommand[hostCommandLength++] = value;
    } else if (hostCommandLength + 1 >= sizeof(hostCommand)) {
      hostCommandLength = 0;
    }
  }
}

bool takeScheduleRequest(uint8_t *destination) {
  bool pending;
  portENTER_CRITICAL(&requestMux);
  pending = scheduleRequestPending;
  if (pending) {
    memcpy(destination, scheduleRequestMac, 6);
    scheduleRequestPending = false;
  }
  portEXIT_CRITICAL(&requestMux);
  return pending;
}

bool ensurePeer(const uint8_t *mac) {
  if (esp_now_is_peer_exist(mac)) return true;
  esp_now_peer_info_t peer = {};
  memcpy(peer.peer_addr, mac, 6);
  peer.channel = ESPNOW_CHANNEL;
  peer.ifidx = WIFI_IF_STA;
  peer.encrypt = false;
  return esp_now_add_peer(&peer) == ESP_OK;
}

void replyWithSchedule(const uint8_t *destination) {
  uint32_t now = millis();
  bool fresh = scheduleValid &&
               now - scheduleUpdatedMs <= HOST_SCHEDULE_STALE_MS;
  bool open = scheduleOpen;
  uint32_t remaining = 0;

  if (fresh && !open) {
    uint32_t elapsed = (now - scheduleUpdatedMs) / 1000;
    if (elapsed >= scheduleSecondsUntilOpen) {
      open = true;  // countdown expiry fails awake
    } else {
      remaining = scheduleSecondsUntilOpen - elapsed;
    }
  }

  SchedulePacket reply = {};
  reply.magic = SCHEDULE_MAGIC;
  reply.version = SCHEDULE_VERSION;
  if (fresh) reply.flags |= SCHEDULE_VALID;
  if (fresh && open) reply.flags |= GALLERY_OPEN;
  reply.secondsUntilOpen = remaining;
  reply.receiverUptimeS = now / 1000;

  if (ensurePeer(destination)) {
    esp_now_send(destination, (uint8_t *)&reply, sizeof(reply));
  }
}

void setup() {
  Serial.begin(921600);
  Serial.println();
  Serial.println("Chair receiver with .11 gallery schedule relay");
  if (!startRadio()) {
    radioStartFailures = 1;
    Serial.println("ESP-NOW receiver start failed; retrying");
  } else {
    Serial.print("Receiver MAC: ");
    Serial.print(WiFi.macAddress());
    Serial.print(" channel:");
    Serial.println(ESPNOW_CHANNEL);
  }
}

void loop() {
  readHostCommands();

  if (!radioReady && millis() - lastRadioStartMs >= 5000) {
    if (!startRadio()) {
      radioStartFailures++;
      if (radioStartFailures >= 3) ESP.restart();
    }
  }

  uint8_t destination[6];
  if (radioReady && takeScheduleRequest(destination)) {
    replyWithSchedule(destination);
  }
  delay(1);
}
