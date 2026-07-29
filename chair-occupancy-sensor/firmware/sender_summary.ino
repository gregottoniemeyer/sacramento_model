// Chair sensor node, v2 firmware. Replaces sender_esp_now.ino on the chairs.
//
// This is ONE packet-format revision carrying all three of the remaining
// features, deliberately done together rather than as three separate changes,
// because each of them would otherwise have to break the wire format on its
// own (see NOTES.md, "Chair ID in firmware").
//
//   1. BATTERY. Still samples the MPU-6050 at 100Hz, but computes the
//      occupancy model's input statistics here and radios them at 8Hz
//      instead of transmitting all 100 raw samples.
//   2. STATUS LED. The onboard LED blinks a health code, so a chair can be
//      diagnosed through the enclosure window with no laptop and no dashboard.
//   3. CAPACITIVE PRESENCE. A touch-electrode reading rides along in every
//      packet, so the signal gets recorded in normal use and can be evaluated
//      against real occupancy later.
//
// -------------------------------------------------------------------------
// WHY 8Hz AND NOT THE 2Hz IN proposed_2hz_radio_reduction/
// -------------------------------------------------------------------------
// The 2Hz design was never validated against the labeled data; it was a
// guess at "much less radio". It was backtested on 2026-07-29 with
// tools/replay_summary.py against all three labeled sessions and it is
// measurably WORSE than the 100Hz system: it misses a stand-up (28/29) and
// adds a false FREE on a seated person.
//
// Measured, all three sessions, versus the 100Hz baseline of 29/29 stand-ups
// and 2 pre-existing false-frees:
//     2Hz  -> 28/29, 3 false-frees            degraded
//     5Hz  -> 29/29, 2 false-frees            clean, but only at zero loss:
//                                             at 10% packet loss it drops to
//                                             84/87 across repeated draws
//     8Hz  -> 29/29, 2 false-frees            clean at 0%, 10% AND 20% loss
//
// 8Hz is therefore the lowest rate with real margin, and it still removes
// 92 of every 100 transmissions. Going lower buys almost nothing anyway:
// the dominant battery cost is the radio being POWERED, not the number of
// packets pushed through it, so 8Hz and 2Hz draw nearly the same current
// while only 8Hz keeps detection intact.
//
// The statistics below are computed over a trailing 1.0s window at the full
// 100Hz sample rate -- identical to the window live_plot.py uses today. That
// is what lets every tuned constant in the occupancy model keep its meaning.
// Do not change WINDOW_MS without re-running tools/replay_summary.py.
//
// -------------------------------------------------------------------------
// WIRING
// -------------------------------------------------------------------------
// MPU-6050 (unchanged): blue=VCC->3V3, green=GND->GND, yellow=SCL->GPIO22,
// red=SDA->GPIO21.
// Touch electrode (new, optional): GPIO27 (touch channel T7) through a ~1M
// series resistor to the electrode. Try the metal seat pan itself before a
// wire loop under the cushion -- the pan shields a loop. A node with nothing
// wired to GPIO27 still works fine; it just reports touchValid=0.

#include <Wire.h>
#include <WiFi.h>
#include <esp_now.h>
#include <esp_wifi.h>
#include <math.h>

// ===========================================================================
//  BOARD CONFIGURATION -- set LED_PIN from firmware/led_probe.ino first
// ===========================================================================
// These WEMOS/Snvi 18650-holder boards are a generic clone and the onboard
// LED is not on a documented pin. If a future batch of boards differs, re-run
// firmware/led_probe.ino rather than assuming -- a wrong pin here produces a
// status indicator that silently never lights, which is worse than no
// indicator at all because it reads as "board dead".
//
// MEASURED on chair 1's board, 2026-07-29, with firmware/led_probe.ino and a
// polarity check: the onboard blue LED is on GPIO16 and is ACTIVE LOW (anode
// to 3V3, cathode to the pin), so driving the pin LOW lights it. Not GPIO2,
// which is the usual ESP32 dev-board position and was the wrong first guess.
const int LED_PIN = 16;
const bool LED_ACTIVE_HIGH = false;

// Print a one-line health summary over USB once a second. Left on in the
// deployed firmware on purpose: it is how a board gets verified at the bench
// without a receiver, and the cost is a few hundred bytes a second on a UART
// that is not even connected in the chairs.
const bool BENCH_SERIAL_STATUS = true;
const uint32_t STATUS_PERIOD_MS = 1000;

// ===========================================================================
//  TUNING -- keep in sync with tools/live_plot.py and tools/replay_summary.py
// ===========================================================================
const uint32_t SAMPLE_PERIOD_MS = 10;    // 100Hz sensor sampling, unchanged
const uint32_t WINDOW_MS = 1000;         // trailing statistics window
const uint32_t TX_PERIOD_MS = 125;       // 8Hz -- see the header note above
const int WINDOW_SAMPLES = WINDOW_MS / SAMPLE_PERIOD_MS;   // 100

// Mirrors BIG_DELTA_RAW in live_plot.py: a single-sample gyro jump this large
// is a jolt/plop. Counted here over the true 100Hz stream, which is strictly
// better than the old arrangement where the dashboard reconstructed it from
// whatever samples survived the radio.
const int32_t BIG_DELTA_RAW = 3000;

// Mirrors DEPART_QUIET_STD_RAW in live_plot.py. Used here only to decide when
// the chair is still enough to re-baseline the touch electrode.
const uint16_t QUIET_STD_RAW = 16;

// Mirrors SENSOR_OK_LOW/HIGH in live_plot.py, converted to raw counts at the
// MPU-6050's default +/-2g scale (1g = 16384). A stationary sensor must
// measure 1g because gravity is the only acceleration on it; a board with a
// marginal VCC/GND joint reads 0.000g on battery and a corrupted-I2C one read
// 2.008g. Deliberately wide so genuine motion does not trip it.
const int32_t ACC_MAG_MIN_RAW = 9011;    // 0.55g
const int32_t ACC_MAG_MAX_RAW = 26214;   // 1.60g

// NOISE-FLOOR FAULT -- the failure chair 1 actually had, 2026-07-29.
//
// A sensor can read a perfect 1.000g and still be useless. Chair 1 measured
// accMag 0.961g with clean I2C and a full 100 samples per window, so every
// existing health check passed it -- but its gyro noise floor sat at
// smax 15-18 at rest, where a healthy board reads 11-14.
//
// That single fact breaks the whole occupancy model. A stand-up is only
// confirmed when the chair goes quiet, and "quiet" means smax <
// DEPART_QUIET_STD_RAW (16). A board whose noise floor never drops below 16
// can never produce a quiet sample, so the departure detector never fires and
// the chair reads OCCUPIED forever. That is exactly the symptom Max reported.
//
// The MINIMUM smax turned out to be the wrong statistic: chair 1's minimum is
// 14, which is under the bar, so a minimum-based test clears it. What actually
// matters is HOW OFTEN it is quiet, because confirming a departure needs 65%
// of a 4s window below the bar (DEPART_QUIET_FRACTION). A healthy empty chair
// is quiet essentially all the time; chair 1 only dips occasionally.
//
// So quietFrac below is the diagnostic number, and it is reported over USB
// but deliberately does NOT drive the LED or sensorOk. A chair that is
// genuinely occupied for minutes on end also has a low quiet fraction, and a
// chair blinking at Greg mid-show because somebody sat in it for a while
// would be worse than useless. This is a bring-up check for the bench, judged
// by a human, not an autonomous alarm.
const uint32_t NOISE_BUCKET_MS = 10000;    // 12 buckets x 10s = 120s of history
const int NOISE_BUCKETS = 12;
const uint16_t NOISE_UNSET = 0xFFFF;
// Smoothing for the quiet fraction. 1/256 at 8Hz is a ~32s time constant:
// long enough to be stable, short enough to settle during a bench check.
const float QUIET_FRAC_ALPHA = 1.0f / 256.0f;

// How long without a successful ESP-NOW acknowledgement before the LED calls
// the radio down. Three seconds is ~24 missed transmissions at 8Hz, well past
// any normal burst of interference.
const uint32_t RADIO_OK_TIMEOUT_MS = 3000;

// ESP-NOW power save. A chair node only ever TRANSMITS, so it never needs to
// keep its receiver awake between packets; the MAC-layer acknowledgement that
// drives radioOk is handled in hardware during the transmit exchange itself.
// Set this to false if the bench board starts reporting send failures -- that
// is the symptom of this being wrong on a given core version, and it is the
// one power optimisation here with any behavioural risk.
const bool ENABLE_ESPNOW_POWER_SAVE = true;

const int MPU_ADDR = 0x68;
const int TOUCH_PIN = T7;                // GPIO27, free (I2C is on 21/22)
uint8_t receiverMac[] = {0x78, 0x1C, 0x3C, 0x35, 0x83, 0x6C};

// ===========================================================================
//  WIRE FORMAT
// ===========================================================================
// 32 bytes, versus 14 for the v1 raw SensorPacket. The receiver tells them
// apart by length, so a half-flashed fleet keeps working during rollout and
// the retired dead-USB spare board (which can never be reflashed) still
// reports if it is ever pressed into service. See receiver_esp_now.ino.
//
// Packed so sizeof() is identical on both sides regardless of how the
// compiler would otherwise pad it.
typedef struct __attribute__((packed)) {
  uint8_t  version;        // 2
  uint8_t  flags;          // see FLAG_* below
  uint16_t seq;            // window counter; lets the receiver see gaps
  int16_t  accMeanX, accMeanY, accMeanZ;
  int16_t  gyroMeanX, gyroMeanY, gyroMeanZ;
  uint16_t gyroStdX, gyroStdY, gyroStdZ;   // std-dev over the trailing 1.0s
  uint8_t  bigDeltaCount;  // gyro jumps > BIG_DELTA_RAW in the window
  uint8_t  sampleCount;    // samples actually in the window (100 when healthy)
  int16_t  temp;
  uint16_t touchRaw;
  uint16_t touchBaseline;
  uint16_t uptimeMin;      // minutes since power-up -- the battery gauge, see below
} SummaryPacket;

// WHY uptimeMin IS THE BATTERY GAUGE
// ----------------------------------
// There is no direct battery telemetry on this board and there cannot be
// without hardware surgery: the TP5400 BOOSTS the cell to a regulated rail,
// so the supply voltage the ESP32 sees stays flat at 3.3V until the cell
// collapses and then falls off a cliff. Reading the rail would tell you
// nothing useful. A real gauge needs a 2-resistor divider soldered to the raw
// cell terminal on every board -- and soldering on boards whose weak joints
// are exactly what failed at install is not a trade worth making.
//
// Minutes-since-power-up is the free substitute and it answers the question
// that actually matters operationally ("which chair needs charging tonight?").
// Once one board has been discharged on the bench to establish hours-per-
// charge, the dashboard can show every chair's elapsed fraction of that.
//
// uint16 minutes covers 45 days, so it will not wrap in service. Note that
// `seq` deliberately WILL wrap (about every 2.3 hours at 8Hz) -- it is only
// used to spot gaps between consecutive packets, which wrapping does not
// affect.

// The receiver tells v1 from v2 purely by length, so the two files MUST agree
// on this number. Asserting it here and in receiver_esp_now.ino turns a
// mismatch into a compile error instead of a fleet that boots cleanly, reports
// no error, and prints "BAD PACKET" forever.
static_assert(sizeof(SummaryPacket) == 32, "SummaryPacket size changed -- update receiver_esp_now.ino to match");

const uint8_t FLAG_SENSOR_OK  = 0x01;
const uint8_t FLAG_RADIO_OK   = 0x02;
const uint8_t FLAG_TOUCH_OK   = 0x04;
const uint8_t FLAG_I2C_FAIL   = 0x08;   // last read did not return 14 bytes
const uint8_t FLAG_ALL_ZERO   = 0x10;   // brownout signature, see NOTES.md

// ===========================================================================
//  STATE
// ===========================================================================
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

// Returns the lowest gyro std-dev seen over the whole retained history, and
// updates the fault flag once a full history exists. Deliberately does not
// judge before it has 120s of data: a board that has just booted has not had
// a chance to be quiet yet, and flagging it early would cry wolf on every
// power-up.
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

  // The number that actually predicts whether departures can ever confirm.
  quietFrac += ((smax < QUIET_STD_RAW ? 1.0f : 0.0f) - quietFrac) * QUIET_FRAC_ALPHA;
}

uint32_t touchBaseline = 0;
uint16_t touchRaw = 0;
bool touchValid = false;

uint32_t nextSampleMs = 0;
uint32_t nextTxMs = 0;
uint32_t nextStatusMs = 0;
uint32_t bootMs = 0;

// ===========================================================================
//  LED STATUS
// ===========================================================================
// TWO STATES ONLY. Nobody should have to decode an LED.
//
//   FLASH   one brief flash every 3s   = everything is fine
//   BLINK   continuous blinking        = something is wrong, plug in USB
//   DARK    nothing at all             = not running, charge the cell
//
// Which problem it is lives in the STATUS line over USB, not in the blink
// pattern. That is the right split: the LED answers "is this chair OK?" from
// across the room, and the moment the answer is no you are going to walk over
// and plug it in anyway, which is where the detail belongs.
//
// Healthy is ~1% duty on purpose: a continuously lit LED costs several mA and
// this firmware exists to save current. A faulty chair blinks far more, which
// is fine -- a chair that needs attention is not the one whose battery life
// is being optimised.
const uint32_t LED_BLIP_CYCLE_MS = 3000;   // healthy: one flash per 3s
const uint32_t LED_BLIP_ON_MS = 40;
const uint32_t LED_BLINK_MS = 150;         // any problem: continuous blinking
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

// ===========================================================================
//  SENSOR + WINDOW
// ===========================================================================
// NOTE the signature: ESP32 core 3.x changed the send callback's first
// argument from `const uint8_t *mac` to `const wifi_tx_info_t *`. This repo
// is already 3.x-only (receiver_esp_now.ino uses esp_now_recv_info_t, which
// does not exist in 2.x), so this targets 3.x. Verified against core 3.3.11.
// If this ever fails to compile with a conversion error naming
// esp_now_send_cb_t, the core version is what changed.
void onDataSent(const wifi_tx_info_t *info, esp_now_send_status_t status) {
  if (status == ESP_NOW_SEND_SUCCESS) {
    lastSendOkMs = millis();
  }
}

// Evict the oldest sample from the running sums, so the statistics stay O(1)
// per sample instead of re-summing 100 samples eight times a second.
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
  // The install-day brownout signature: the analog sensor core is starved
  // while the digital side and the radio keep running, so every field reads
  // exactly 0 at a full packet rate. Distinct from an I2C fault, which reads
  // -1 on every field. See NOTES.md, "Installation day".
  allZero = (ax == 0 && ay == 0 && az == 0 && gx == 0 && gy == 0 && gz == 0);

  pushSample(ax, ay, az, gx, gy, gz);
}

uint16_t stdOf(int axis) {
  if (bufCount < 2) return 0;
  double mean = (double)sumGyro[axis] / bufCount;
  double var = (double)sumSqGyro[axis] / bufCount - mean * mean;
  if (var < 0) var = 0;               // floating-point noise near zero variance
  double s = sqrt(var);
  // Saturate rather than wrap. A wrapped std would read as QUIET and could
  // falsely release an occupied chair -- the one failure mode this system
  // must not have.
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

  // --- sensor health, computed here so the LED and the dashboard agree -----
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
  // Only fold REAL readings into the noise statistics. A sensor that is not
  // answering reports a std-dev of 0, which sails under the quiet bar and
  // would make a completely dead board look like the quietest chair in the
  // room -- observed on 2026-07-29 as quiet:89% on a board reading nothing.
  if (reading) updateNoiseFloor(now, smaxNow);
  sensorOk = magOk;

  // --- capacitive presence -------------------------------------------------
  // Read once per window; touchRead() takes a fraction of a millisecond and
  // there is nothing to gain from oversampling a signal this slow.
  uint16_t raw = (uint16_t)touchRead(TOUCH_PIN);
  touchValid = (raw > 0);
  touchRaw = raw;

  // Track the empty-chair baseline slowly, and ONLY while the chair is
  // still enough to be plausibly empty. Raw touch counts drift with
  // temperature and humidity over tens of minutes, so a fixed threshold
  // would not survive a gallery day; but a baseline that adapts while
  // somebody is sitting there would quietly erase the very signal it is
  // measuring. Gating on stillness is the cheap approximation of
  // "known empty" available on the sender, which does not know occupancy.
  if (touchValid) {
    if (touchBaseline == 0) {
      touchBaseline = raw;                       // first reading after boot
    } else if (smaxNow < QUIET_STD_RAW) {
      touchBaseline = (touchBaseline * 511 + raw) / 512;   // very slow EMA
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

// ===========================================================================
void setup() {
  Serial.begin(115200);
  pinMode(LED_PIN, OUTPUT);
  ledWrite(false);
  bootMs = millis();

  Wire.begin(21, 22);
  Wire.setClock(400000);
  Wire.beginTransmission(MPU_ADDR);
  Wire.write(0x6B);   // power management register
  Wire.write(0);      // wake the sensor up
  Wire.endTransmission(true);

  WiFi.mode(WIFI_STA);
  esp_now_init();
  esp_now_register_send_cb(onDataSent);
  esp_now_peer_info_t peerInfo = {};
  memcpy(peerInfo.peer_addr, receiverMac, 6);
  peerInfo.channel = 0;
  peerInfo.encrypt = false;
  esp_now_add_peer(&peerInfo);

  // --- power ---------------------------------------------------------------
  // 80MHz is the lowest clock the WiFi radio will run at, and the workload
  // here (one 14-byte I2C read every 10ms) does not come close to needing
  // 240MHz. This is the single largest saving in this file and it carries no
  // behavioural risk.
  setCpuFrequencyMhz(80);
  esp_wifi_set_ps(WIFI_PS_MIN_MODEM);
  if (ENABLE_ESPNOW_POWER_SAVE) {
    esp_now_set_wake_window(0);   // transmit-only node: never wake to listen
  }

  Serial.println();
  Serial.print("Chair sender v2, ");
  Serial.print(1000 / TX_PERIOD_MS);
  Serial.print("Hz summary, MAC ");
  Serial.println(WiFi.macAddress());
  Serial.print("packet size: ");
  Serial.println(sizeof(SummaryPacket));

  nextSampleMs = millis();
  nextTxMs = millis() + WINDOW_MS;   // first send once a full window exists
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

  // Bench status. Reports exactly what the LED is reporting, in words, so a
  // board can be verified over USB without counting 40ms flashes and without
  // a receiver present. accMag is the number that matters: a healthy board
  // reads close to 1.000g because gravity is the only acceleration on a
  // stationary sensor.
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
    Serial.print("  minStd:"); Serial.print(minSmax);
    Serial.print("  quiet:"); Serial.print(quietFrac * 100.0f, 0); Serial.print("%");
    Serial.print(noiseHistoryFull ? "" : "(warming)");
    Serial.print("  i2c:"); Serial.print(i2cFail ? "FAIL" : "ok");
    Serial.print("  zeros:"); Serial.print(allZero ? "YES" : "no");
    Serial.print("  led:"); Serial.print(LED_PATTERN_NAME);
    Serial.print("  up:"); Serial.print((now - bootMs) / 1000);
    Serial.println("s");
  }

  // Yield rather than spin. The old firmware busy-polled millis(), which kept
  // the CPU at 100% for a workload that is idle ~95% of the time; delay()
  // hands control to the FreeRTOS idle task, which is what allows the core to
  // actually clock down between samples.
  int32_t untilSample = (int32_t)(nextSampleMs - millis());
  if (untilSample > 1) delay(untilSample - 1);
}
