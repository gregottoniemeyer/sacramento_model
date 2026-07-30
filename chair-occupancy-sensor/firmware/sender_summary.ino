#include <Wire.h>
#include <WiFi.h>
#include <esp_now.h>
#include <esp_wifi.h>
#include <math.h>

const int LED_PIN = 16;
const bool LED_ACTIVE_HIGH = false;

const bool BENCH_SERIAL_STATUS = true;
const uint32_t STATUS_PERIOD_MS = 1000;

const uint32_t SAMPLE_PERIOD_MS = 10;
const uint32_t WINDOW_MS = 1000;
const uint32_t TX_PERIOD_MS = 125;
const int WINDOW_SAMPLES = WINDOW_MS / SAMPLE_PERIOD_MS;

const int32_t BIG_DELTA_RAW = 3000;

const uint16_t QUIET_STD_RAW = 16;

const int32_t ACC_MAG_MIN_RAW = 9011;
const int32_t ACC_MAG_MAX_RAW = 26214;

const uint32_t NOISE_BUCKET_MS = 10000;
const int NOISE_BUCKETS = 12;
const uint16_t NOISE_UNSET = 0xFFFF;

const float QUIET_FRAC_ALPHA = 1.0f / 256.0f;

const uint32_t RADIO_OK_TIMEOUT_MS = 3000;

const bool ENABLE_ESPNOW_POWER_SAVE = true;

const int MPU_ADDR = 0x68;
const int TOUCH_PIN = T7;
uint8_t receiverMac[] = {0x78, 0x1C, 0x3C, 0x35, 0x83, 0x6C};

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

static_assert(sizeof(SummaryPacket) == 39, "SummaryPacket size changed -- update receiver_esp_now.ino to match");

const uint8_t FLAG_SENSOR_OK  = 0x01;
const uint8_t FLAG_RADIO_OK   = 0x02;
const uint8_t FLAG_TOUCH_OK   = 0x04;
const uint8_t FLAG_I2C_FAIL   = 0x08;
const uint8_t FLAG_ALL_ZERO   = 0x10;

int16_t bufAcc[3][WINDOW_SAMPLES];
int16_t bufGyro[3][WINDOW_SAMPLES];
bool    bufBig[WINDOW_SAMPLES];
int     bufHead = 0;
int     bufCount = 0;

int64_t sumAcc[3]   = {0, 0, 0};
int64_t sumGyro[3]  = {0, 0, 0};
int64_t sumSqGyro[3] = {0, 0, 0};
int     bigCount = 0;

int16_t lastTemp = 0;
int16_t prevGyro[3] = {0, 0, 0};
bool    havePrevGyro = false;
uint16_t bufJump[WINDOW_SAMPLES];
int32_t  yawAccum = 0;
uint8_t  yawCount = 0;
uint16_t lastPeakJump = 0;

uint16_t seqCounter = 0;
volatile uint32_t lastSendOkMs = 0;
bool i2cFail = false;
bool allZero = false;
bool sensorOk = false;

uint16_t noiseBucket[NOISE_BUCKETS];
int noiseIdx = 0;
uint32_t noiseBucketStartMs = 0;
bool noiseHistoryFull = false;
uint16_t minSmax = 0;
float quietFrac = 0.0f;

void updateNoiseFloor(uint32_t now, uint16_t smax) {
  if (noiseBucketStartMs == 0) noiseBucketStartMs = now;
  if (smax < noiseBucket[noiseIdx]) noiseBucket[noiseIdx] = smax;

  if (now - noiseBucketStartMs >= NOISE_BUCKET_MS) {
    noiseBucketStartMs = now;
    noiseIdx = (noiseIdx + 1) % NOISE_BUCKETS;
    if (noiseIdx == 0) noiseHistoryFull = true;
    noiseBucket[noiseIdx] = NOISE_UNSET;
  }

  uint16_t mn = NOISE_UNSET;
  for (int i = 0; i < NOISE_BUCKETS; i++) {
    if (noiseBucket[i] != NOISE_UNSET && noiseBucket[i] < mn) mn = noiseBucket[i];
  }
  minSmax = (mn == NOISE_UNSET) ? 0 : mn;

  quietFrac += ((smax < QUIET_STD_RAW ? 1.0f : 0.0f) - quietFrac) * QUIET_FRAC_ALPHA;
}

uint32_t touchBaseline = 0;
uint16_t touchRaw = 0;
bool touchValid = false;

uint32_t nextSampleMs = 0;
uint32_t nextTxMs = 0;
uint32_t nextStatusMs = 0;
uint32_t bootMs = 0;

const uint32_t LED_BLIP_CYCLE_MS = 3000;
const uint32_t LED_BLIP_ON_MS = 40;
const uint32_t LED_BLINK_MS = 150;
const uint32_t LED_BOOT_MS = 1000;

const char *LED_PATTERN_NAME = "boot";

void ledWrite(bool on) {
  digitalWrite(LED_PIN, (on == LED_ACTIVE_HIGH) ? HIGH : LOW);
}

void updateLed(uint32_t now, bool radioOk) {
  uint32_t since = now - bootMs;

  if (since < LED_BOOT_MS) {
    LED_PATTERN_NAME = "boot(solid)";
    ledWrite(true);
    return;
  }

  if (!sensorOk || !radioOk) {
    LED_PATTERN_NAME = "BLINK(problem)";
    ledWrite((since / LED_BLINK_MS) % 2 == 0);
  } else {
    LED_PATTERN_NAME = "flash(ok)";
    ledWrite((since % LED_BLIP_CYCLE_MS) < LED_BLIP_ON_MS);
  }
}

void onDataSent(const wifi_tx_info_t *info, esp_now_send_status_t status) {
  if (status == ESP_NOW_SEND_SUCCESS) {
    lastSendOkMs = millis();
  }
}

void evictOldest() {
  int tail = (bufHead - bufCount + WINDOW_SAMPLES) % WINDOW_SAMPLES;
  for (int i = 0; i < 3; i++) {
    sumAcc[i]  -= bufAcc[i][tail];
    sumGyro[i] -= bufGyro[i][tail];
    sumSqGyro[i] -= (int64_t)bufGyro[i][tail] * bufGyro[i][tail];
  }
  if (bufBig[tail]) bigCount--;
  bufCount--;
}

void pushSample(int16_t ax, int16_t ay, int16_t az,
                int16_t gx, int16_t gy, int16_t gz) {
  if (bufCount == WINDOW_SAMPLES) evictOldest();

  int32_t d = 0;
  if (havePrevGyro) {
    d = max(max(abs((int32_t)gx - prevGyro[0]), abs((int32_t)gy - prevGyro[1])),
            abs((int32_t)gz - prevGyro[2]));
  }
  bool big = havePrevGyro && d > BIG_DELTA_RAW;

  bufAcc[0][bufHead] = ax; bufAcc[1][bufHead] = ay; bufAcc[2][bufHead] = az;
  bufGyro[0][bufHead] = gx; bufGyro[1][bufHead] = gy; bufGyro[2][bufHead] = gz;
  bufBig[bufHead] = big;
  bufJump[bufHead] = (d > 65535) ? 65535 : (uint16_t)d;

  yawAccum += gz;
  if (yawCount < 255) yawCount++;

  sumAcc[0] += ax; sumAcc[1] += ay; sumAcc[2] += az;
  sumGyro[0] += gx; sumGyro[1] += gy; sumGyro[2] += gz;
  sumSqGyro[0] += (int64_t)gx * gx;
  sumSqGyro[1] += (int64_t)gy * gy;
  sumSqGyro[2] += (int64_t)gz * gz;
  if (big) bigCount++;

  prevGyro[0] = gx; prevGyro[1] = gy; prevGyro[2] = gz;
  havePrevGyro = true;
  bufHead = (bufHead + 1) % WINDOW_SAMPLES;
  bufCount++;
}

void readSensor() {
  Wire.beginTransmission(MPU_ADDR);
  Wire.write(0x3B);
  if (Wire.endTransmission(false) != 0) { i2cFail = true; return; }
  if (Wire.requestFrom(MPU_ADDR, 14, true) != 14) { i2cFail = true; return; }

  int16_t ax = Wire.read() << 8 | Wire.read();
  int16_t ay = Wire.read() << 8 | Wire.read();
  int16_t az = Wire.read() << 8 | Wire.read();
  lastTemp   = Wire.read() << 8 | Wire.read();
  int16_t gx = Wire.read() << 8 | Wire.read();
  int16_t gy = Wire.read() << 8 | Wire.read();
  int16_t gz = Wire.read() << 8 | Wire.read();

  i2cFail = false;

  allZero = (ax == 0 && ay == 0 && az == 0 && gx == 0 && gy == 0 && gz == 0);

  pushSample(ax, ay, az, gx, gy, gz);
}

uint16_t stdOf(int axis) {
  if (bufCount < 2) return 0;
  double mean = (double)sumGyro[axis] / bufCount;
  double var = (double)sumSqGyro[axis] / bufCount - mean * mean;
  if (var < 0) var = 0;
  double s = sqrt(var);

  return (s > 65535.0) ? 65535 : (uint16_t)s;
}

void sendSummary(uint32_t now, bool radioOk) {
  SummaryPacket p = {};
  p.version = 2;
  p.seq = seqCounter++;
  p.sampleCount = (bufCount > 255) ? 255 : (uint8_t)bufCount;
  p.temp = lastTemp;
  p.uptimeMin = (uint16_t)((now - bootMs) / 60000UL);

  if (bufCount > 0) {
    for (int i = 0; i < 3; i++) {
      int16_t accMean = (int16_t)(sumAcc[i] / bufCount);
      int16_t gyroMean = (int16_t)(sumGyro[i] / bufCount);
      if (i == 0) { p.accMeanX = accMean; p.gyroMeanX = gyroMean; }
      if (i == 1) { p.accMeanY = accMean; p.gyroMeanY = gyroMean; }
      if (i == 2) { p.accMeanZ = accMean; p.gyroMeanZ = gyroMean; }
    }
  }
  p.gyroStdX = stdOf(0);
  p.gyroStdY = stdOf(1);
  p.gyroStdZ = stdOf(2);
  p.bigDeltaCount = (bigCount > 255) ? 255 : (uint8_t)bigCount;

  uint16_t peak = 0;
  for (int i = 0; i < bufCount; i++) {
    int idx = (bufHead - 1 - i + WINDOW_SAMPLES) % WINDOW_SAMPLES;
    if (bufJump[idx] > peak) peak = bufJump[idx];
  }
  p.peakJump = peak;
  lastPeakJump = peak;
  p.yawSumNew = yawAccum;
  p.nNew = yawCount;
  yawAccum = 0;
  yawCount = 0;

  bool reading = (bufCount >= 5 && !i2cFail && !allZero);
  bool magOk = false;
  if (reading) {
    double mx = (double)sumAcc[0] / bufCount;
    double my = (double)sumAcc[1] / bufCount;
    double mz = (double)sumAcc[2] / bufCount;
    double mag = sqrt(mx * mx + my * my + mz * mz);
    magOk = (mag >= ACC_MAG_MIN_RAW && mag <= ACC_MAG_MAX_RAW);
  }
  uint16_t smaxNow = max(max(p.gyroStdX, p.gyroStdY), p.gyroStdZ);

  if (reading) updateNoiseFloor(now, smaxNow);
  sensorOk = magOk;

  uint16_t raw = (uint16_t)touchRead(TOUCH_PIN);
  touchValid = (raw > 0);
  touchRaw = raw;

  if (touchValid) {
    if (touchBaseline == 0) {
      touchBaseline = raw;
    } else if (smaxNow < QUIET_STD_RAW) {
      touchBaseline = (touchBaseline * 511 + raw) / 512;
    }
  }
  p.touchBaseline = (uint16_t)touchBaseline;
  p.touchRaw = touchRaw;

  p.flags = 0;
  if (sensorOk)  p.flags |= FLAG_SENSOR_OK;
  if (radioOk)   p.flags |= FLAG_RADIO_OK;
  if (touchValid) p.flags |= FLAG_TOUCH_OK;
  if (i2cFail)   p.flags |= FLAG_I2C_FAIL;
  if (allZero)   p.flags |= FLAG_ALL_ZERO;

  esp_now_send(receiverMac, (uint8_t *)&p, sizeof(p));
}

void setup() {
  Serial.begin(115200);
  pinMode(LED_PIN, OUTPUT);
  ledWrite(false);
  bootMs = millis();

  Wire.begin(21, 22);
  Wire.setClock(400000);
  Wire.beginTransmission(MPU_ADDR);
  Wire.write(0x6B);
  Wire.write(0);
  Wire.endTransmission(true);

  WiFi.mode(WIFI_STA);
  esp_now_init();
  esp_now_register_send_cb(onDataSent);
  esp_now_peer_info_t peerInfo = {};
  memcpy(peerInfo.peer_addr, receiverMac, 6);
  peerInfo.channel = 0;
  peerInfo.encrypt = false;
  esp_now_add_peer(&peerInfo);

  setCpuFrequencyMhz(80);
  esp_wifi_set_ps(WIFI_PS_MIN_MODEM);
  if (ENABLE_ESPNOW_POWER_SAVE) {
    esp_now_set_wake_window(0);
  }

  Serial.println();
  Serial.print("Chair sender v2, ");
  Serial.print(1000 / TX_PERIOD_MS);
  Serial.print("Hz summary, MAC ");
  Serial.println(WiFi.macAddress());
  Serial.print("packet size: ");
  Serial.println(sizeof(SummaryPacket));

  nextSampleMs = millis();
  nextTxMs = millis() + WINDOW_MS;
  nextStatusMs = millis() + STATUS_PERIOD_MS;
  for (int i = 0; i < NOISE_BUCKETS; i++) noiseBucket[i] = NOISE_UNSET;
}

void loop() {
  uint32_t now = millis();

  if ((int32_t)(now - nextSampleMs) >= 0) {
    nextSampleMs += SAMPLE_PERIOD_MS;
    readSensor();
  }

  bool radioOk = (lastSendOkMs != 0) && (now - lastSendOkMs < RADIO_OK_TIMEOUT_MS);

  if ((int32_t)(now - nextTxMs) >= 0) {
    nextTxMs += TX_PERIOD_MS;
    sendSummary(now, radioOk);
  }

  updateLed(now, radioOk);

  if (BENCH_SERIAL_STATUS && (int32_t)(now - nextStatusMs) >= 0) {
    nextStatusMs += STATUS_PERIOD_MS;
    double mag = 0;
    if (bufCount > 0) {
      double mx = (double)sumAcc[0] / bufCount;
      double my = (double)sumAcc[1] / bufCount;
      double mz = (double)sumAcc[2] / bufCount;
      mag = sqrt(mx * mx + my * my + mz * mz) / 16384.0;
    }
    Serial.print("STATUS  ");
    Serial.print(sensorOk ? "sensor:OK    " : "sensor:FAULT ");
    Serial.print(radioOk ? "radio:OK    " : "radio:NO-ACK ");
    Serial.print("accMag:"); Serial.print(mag, 3); Serial.print("g  ");
    Serial.print("std("); Serial.print(stdOf(0)); Serial.print(",");
    Serial.print(stdOf(1)); Serial.print(","); Serial.print(stdOf(2));
    Serial.print(")  n:"); Serial.print(bufCount);
    Serial.print("  touch:"); Serial.print(touchRaw);
    Serial.print("/"); Serial.print(touchBaseline);
    Serial.print("  peak:"); Serial.print(lastPeakJump);
    Serial.print("  minStd:"); Serial.print(minSmax);
    Serial.print("  quiet:"); Serial.print(quietFrac * 100.0f, 0); Serial.print("%");
    Serial.print(noiseHistoryFull ? "" : "(warming)");
    Serial.print("  i2c:"); Serial.print(i2cFail ? "FAIL" : "ok");
    Serial.print("  zeros:"); Serial.print(allZero ? "YES" : "no");
    Serial.print("  led:"); Serial.print(LED_PATTERN_NAME);
    Serial.print("  up:"); Serial.print((now - bootMs) / 1000);
    Serial.println("s");
  }

  int32_t untilSample = (int32_t)(nextSampleMs - millis());
  if (untilSample > 1) delay(untilSample - 1);
}
