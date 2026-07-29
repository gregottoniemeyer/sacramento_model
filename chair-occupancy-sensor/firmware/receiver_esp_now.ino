// ESP-NOW receiver — sits permanently on USB (currently the Lonely Binary
// board), receives packets from sender_esp_now.ino and prints them to Serial
// in a fixed text format that tools/live_plot.py and friends parse:
//
//   Chair:N  Accel  X:val  Y:val  Z:val    Gyro  X:val  Y:val  Z:val    Temp:val
//
// Do not change the "Accel ... Temp:" part of this format without also
// updating the LINE_RE regex in every tools/*.py script that parses it.
// The "Chair:N" prefix is safe to leave in place for older tools: every
// LINE_RE uses re.search() anchored at "Accel", so they skip the prefix.
//
// CHAIR IDENTIFICATION
// ESP-NOW hands us the sender's MAC in info->src_addr, so which board a
// packet came from is already known here -- the senders do NOT carry a
// chair-ID field and do not need one. That means swapping a chair's board
// is a one-line edit to the table below rather than a reflash, and two
// chairs can't accidentally end up sharing an ID. Keep this table in sync
// with the board-number -> MAC table in ../NOTES.md.
//
// An unrecognized board prints "Chair:?" followed by its MAC, so a new or
// reflashed board announces itself instead of silently vanishing.
//
// BAUD RATE: 921600, not the old 115200. Seven boards at 100Hz is ~700
// lines/sec at ~90 bytes each = ~63 KB/s, and 115200 baud only carries
// ~11.5 KB/s -- roughly 5x oversubscribed, which shows up as silently
// dropped and garbled lines rather than a clean error. The capture command
// in ../README.md must use the matching rate:
//   stty -f /dev/fd/3 921600 raw
//
// INTERCHANGEABLE RECEIVER BOARDS (added 2026-07-24)
// This sketch claims RECEIVER_MAC below in software, so it can be flashed to
// ANY ESP32 and that board becomes a working receiver. The reason it has to:
// every sender unicasts to one hardcoded MAC (sender_esp_now.ino's
// receiverMac), so a second receiver with its own factory MAC would receive
// nothing at all -- it would boot cleanly, report no error, and print
// silence. Cloning the MAC here means a second receiver needs no sender
// changes whatsoever.
//
// On the original Lonely Binary board this is a no-op (it already has that
// MAC from the factory), so one firmware serves every receiver board and
// there is no second sketch to keep in sync.
//
// >>> NEVER POWER TWO RECEIVERS AT THE SAME TIME. <<<
// They share a MAC. Two boards answering to one address in radio range will
// both ACK the senders and corrupt each other's reception. One plugged in at
// a time -- that is the whole point, so you can leave one at each machine
// and stop unplugging and carrying the same board back and forth.
//
// The long-term fix that removes this restriction is switching the senders
// to broadcast (FF:FF:FF:FF:FF:FF), which allows any number of simultaneous
// receivers -- but that needs all seven senders reflashed over USB, and the
// mounting step is itself hard on the boards, so it is worth doing only as
// chairs come out for other reasons. See ../NOTES.md.

#include <WiFi.h>
#include <esp_wifi.h>
#include <esp_now.h>

// The single MAC every sender transmits to. Must stay identical to
// receiverMac in sender_esp_now.ino -- if you ever change one, change both.
uint8_t RECEIVER_MAC[6] = {0x78, 0x1C, 0x3C, 0x35, 0x83, 0x6C};

// TWO WIRE FORMATS, TOLD APART BY LENGTH (added 2026-07-29)
// v1 (14 bytes) is the original raw 100Hz sample from sender_esp_now.ino.
// v2 (32 bytes) is the 8Hz on-device summary from sender_summary.ino.
//
// Both are accepted, on purpose, for two reasons that both matter during
// rollout: chairs get reflashed one at a time, so the fleet is mixed for as
// long as that takes; and the retired chair-1 board has a torn-off micro-USB
// connector, so it can NEVER be reflashed -- if it is ever pressed into
// service as an emergency spare it will speak v1 forever.
//
// v2 lines print the same "Accel ... Temp:" section as v1 and append the new
// fields AFTER it. Every LINE_RE in tools/*.py uses re.search() anchored
// between "Accel" and "Temp:", so appending is invisible to them and no tool
// needs changing to keep working. Only live_plot.py reads the extra fields.
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
} SummaryPacket;

// Must match the identical assertion in sender_summary.ino. The two formats
// are told apart by length alone, so a silent size disagreement between the
// files would present as every packet arriving as "BAD PACKET".
static_assert(sizeof(SummaryPacket) == 32, "SummaryPacket size changed -- update sender_summary.ino to match");
static_assert(sizeof(SensorPacket) == 14, "SensorPacket size changed -- v1 senders would stop being recognised");

// 7 real chairs + 1 bench test slot (see slot 8 below).
const int NUM_CHAIRS = 8;

// Index 0 = chair 1, index 6 = chair 7. From ../NOTES.md (2026-07-10 bring-up).
const uint8_t chairMacs[NUM_CHAIRS][6] = {
  {0x8C, 0x94, 0xDF, 0x46, 0xB5, 0x54},  // chair 1 (rebuilt 2026-07-22)
  {0x88, 0xF1, 0x55, 0x30, 0xAF, 0xB4},  // chair 2 (was board 8; swapped in 2026-07-22)
  {0x88, 0xF1, 0x55, 0x32, 0x49, 0xC4},  // chair 3
  {0x8C, 0x94, 0xDF, 0x45, 0xCA, 0x28},  // chair 4
  {0x88, 0xF1, 0x55, 0x30, 0xA6, 0x58},  // chair 5
  {0x8C, 0x94, 0xDF, 0x97, 0x4F, 0x34},  // chair 6
  {0x8C, 0x94, 0xDF, 0x45, 0xB3, 0xD0},  // chair 7
  // Slot 8 is not a chair: it is a bench test board, added 2026-07-24. This is
  // the spare Lonely Binary board that briefly served as the MAC-cloned second
  // receiver, reflashed as a sender so a sensor can be tested on the dashboard
  // without unmounting a real chair. Its factory MAC is in the same
  // 78:1c:3c:35:xx range as the receiver, which is expected -- same board
  // family, not a duplicate of the receiver's 83:6c.
  {0x78, 0x1C, 0x3C, 0x35, 0x04, 0x84},  // 8 = TEST BENCH board
};

// Returns 1-7 for a known board, or 0 for an unrecognized one.
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
    // Unknown board -- print the MAC so it can be added to the table above.
    Serial.print("Chair:?[");
    for (int i = 0; i < 6; i++) {
      if (mac[i] < 0x10) Serial.print('0');
      Serial.print(mac[i], HEX);
      if (i < 5) Serial.print(':');
    }
    Serial.print(']');
  }
}

// The shared "Accel ... Temp:" section. Every tools/*.py parser depends on
// this exact text, so both packet versions emit it identically.
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
  // RSSI comes free with every packet and is the cheapest early warning there
  // is that a chair is about to start dropping out -- worth logging even
  // though nothing consumes it yet.
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
    // Neither format. Report it rather than dropping it silently -- a
    // mismatched struct between sender and receiver is otherwise invisible
    // and looks exactly like a dead board.
    printChairPrefix(info->src_addr);
    Serial.print("  BAD PACKET len:"); Serial.println(len);
  }
}

void setup() {
  Serial.begin(921600);
  WiFi.mode(WIFI_STA);

  // Claim the address the senders transmit to. Must happen after
  // WiFi.mode() (the interface has to exist) and before esp_now_init()
  // (ESP-NOW binds to whatever MAC the interface has at init time).
  esp_err_t macErr = esp_wifi_set_mac(WIFI_IF_STA, RECEIVER_MAC);

  // Verify rather than assume. A silently-failed MAC set produces exactly
  // the same symptom as a dead board -- no lines at all -- so check it here
  // where it can be reported, instead of debugging it later at the log.
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
