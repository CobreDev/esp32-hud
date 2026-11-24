// ESP32-HUD firmware: a dumb 240x240 JPEG display for the MacHUD menu bar app.
// Protocol: see ../PROTOCOL.md
//
// Board: ESP32-S3-Zero, FQBN esp32:esp32:esp32s3:CDCOnBoot=cdc,PSRAM=enabled,FlashSize=4M
// Library: LovyanGFX

#include "LGFX_Config.h"

#define FW_VERSION "1.0.0"
#define PROTO_VERSION 1

static constexpr uint32_t MAX_PAYLOAD = 96 * 1024;  // JPEG bytes
static constexpr uint32_t IDLE_TIMEOUT_MS = 10000;
static constexpr uint32_t BYTE_TIMEOUT_MS = 500;

// Message types
enum : uint8_t {
  MSG_HELLO = 0x01,
  MSG_PING = 0x02,
  MSG_FRAME = 0x10,
  MSG_DISPLAY_ON = 0x11,
  MSG_DISPLAY_OFF = 0x12,
  MSG_HELLO_REPLY = 0x81,
  MSG_PONG = 0x82,
  MSG_ACK = 0x90,
};

enum : uint8_t {
  ACK_OK = 0,
  ACK_BAD_CRC = 1,
  ACK_TOO_LARGE = 2,
  ACK_DECODE_FAILED = 3,
  ACK_DISPLAY_OFF = 4,
  ACK_UNKNOWN_TYPE = 5,
};

static LGFX lcd;
static LGFX_Sprite canvas(&lcd);
static bool canvasOK = false;

static uint8_t* payload = nullptr;  // PSRAM receive buffer

static bool displayOn = true;
static bool idleShown = false;
static uint32_t lastRxMs = 0;

// ---------------------------------------------------------------- CRC-32 (IEEE)
static uint32_t crcTable[256];

static void crcInit() {
  for (uint32_t i = 0; i < 256; i++) {
    uint32_t c = i;
    for (int k = 0; k < 8; k++) c = (c & 1) ? (0xEDB88320u ^ (c >> 1)) : (c >> 1);
    crcTable[i] = c;
  }
}

// Running CRC: start with 0xFFFFFFFF, finish with ~crc.
static inline uint32_t crcUpdate(uint32_t crc, const uint8_t* p, size_t n) {
  while (n--) crc = crcTable[(crc ^ *p++) & 0xFF] ^ (crc >> 8);
  return crc;
}

// ---------------------------------------------------------------- TX
static void sendPacket(uint8_t type, uint8_t seq, const uint8_t* data, uint32_t len) {
  uint8_t hdr[8] = {0xA5, 0x5A, type, seq,
                    (uint8_t)len, (uint8_t)(len >> 8), (uint8_t)(len >> 16), (uint8_t)(len >> 24)};
  uint32_t crc = crcUpdate(0xFFFFFFFFu, hdr + 2, 6);
  if (len) crc = crcUpdate(crc, data, len);
  crc = ~crc;
  uint8_t tail[4] = {(uint8_t)crc, (uint8_t)(crc >> 8), (uint8_t)(crc >> 16), (uint8_t)(crc >> 24)};
  Serial.write(hdr, 8);
  if (len) Serial.write(data, len);
  Serial.write(tail, 4);
  Serial.flush();
}

static void sendAck(uint8_t seq, uint8_t status, uint16_t drawMs = 0) {
  uint8_t p[4] = {seq, status, (uint8_t)drawMs, (uint8_t)(drawMs >> 8)};
  sendPacket(MSG_ACK, seq, p, sizeof(p));
}

// ---------------------------------------------------------------- Display
static void panelOff() {
  lcd.fillScreen(TFT_BLACK);
  lcd.startWrite();
  lcd.writeCommand(0x28);  // DISPOFF
  lcd.endWrite();
  lcd.sleep();             // SLPIN
  displayOn = false;
}

static void panelOn() {
  lcd.wakeup();            // SLPOUT
  lcd.startWrite();
  lcd.writeCommand(0x29);  // DISPON
  lcd.endWrite();
  displayOn = true;
}

static void drawIdleScreen() {
  lcd.startWrite();
  lcd.fillScreen(TFT_BLACK);
  const int cx = lcd.width() / 2, cy = lcd.height() / 2;
  lcd.drawArc(cx, cy, 118, 114, 0, 360, lcd.color888(40, 40, 48));
  lcd.setTextDatum(textdatum_t::middle_center);
  lcd.setTextColor(lcd.color888(220, 220, 230));
  lcd.setFont(&fonts::FreeSansBold12pt7b);
  lcd.drawString("Waiting for Mac...", cx, cy - 8);
  lcd.setFont(&fonts::FreeSans9pt7b);
  lcd.setTextColor(lcd.color888(120, 120, 135));
  lcd.drawString("ESP32-HUD v" FW_VERSION, cx, cy + 22);
  lcd.endWrite();
  idleShown = true;
}

static uint8_t drawFrame(uint32_t len, uint16_t& ms) {
  if (!displayOn) return ACK_DISPLAY_OFF;
  uint32_t t0 = millis();
  bool ok;
  if (canvasOK) {
    ok = canvas.drawJpg(payload, len, 0, 0);
    if (ok) canvas.pushSprite(0, 0);
  } else {
    ok = lcd.drawJpg(payload, len, 0, 0);
  }
  ms = (uint16_t)min<uint32_t>(millis() - t0, 0xFFFF);
  if (ok) idleShown = false;
  return ok ? ACK_OK : ACK_DECODE_FAILED;
}

// ---------------------------------------------------------------- RX state machine
enum class RxState { Magic0, Magic1, Header, Payload, Crc, Skip };

static RxState rxState = RxState::Magic0;
static uint8_t hdrBuf[6];     // type, seq, len[4]
static uint8_t crcBuf[4];
static uint32_t rxCount = 0;  // bytes collected in the current state
static uint32_t rxLen = 0;
static uint32_t lastByteMs = 0;

static void resetParser() {
  rxState = RxState::Magic0;
  rxCount = 0;
}

static void handlePacket(uint8_t type, uint8_t seq, uint32_t len) {
  lastRxMs = millis();
  switch (type) {
    case MSG_HELLO: {
      char buf[96];
      int n = snprintf(buf, sizeof(buf), "id=ESP32-HUD;fw=" FW_VERSION ";proto=%d;w=%d;h=%d;max=%lu",
                       PROTO_VERSION, (int)lcd.width(), (int)lcd.height(), (unsigned long)MAX_PAYLOAD);
      sendPacket(MSG_HELLO_REPLY, seq, (const uint8_t*)buf, n);
      break;
    }
    case MSG_PING:
      sendPacket(MSG_PONG, seq, nullptr, 0);
      break;
    case MSG_FRAME: {
      uint16_t ms = 0;
      uint8_t st = drawFrame(len, ms);
      sendAck(seq, st, ms);
      break;
    }
    case MSG_DISPLAY_ON:
      if (!displayOn) panelOn();
      sendAck(seq, ACK_OK);
      break;
    case MSG_DISPLAY_OFF:
      if (displayOn) panelOff();
      idleShown = false;
      sendAck(seq, ACK_OK);
      break;
    default:
      sendAck(seq, ACK_UNKNOWN_TYPE);
      break;
  }
}

static void finishPacket() {
  uint32_t got = crcBuf[0] | (crcBuf[1] << 8) | (crcBuf[2] << 16) | ((uint32_t)crcBuf[3] << 24);
  uint32_t crc = crcUpdate(0xFFFFFFFFu, hdrBuf, 6);
  if (rxLen) crc = crcUpdate(crc, payload, rxLen);
  crc = ~crc;
  if (crc != got) {
    sendAck(hdrBuf[1], ACK_BAD_CRC);
  } else {
    handlePacket(hdrBuf[0], hdrBuf[1], rxLen);
  }
  resetParser();
}

static void pumpSerial() {
  int avail = Serial.available();
  uint32_t now = millis();

  if (avail <= 0) {
    if (rxState != RxState::Magic0 && now - lastByteMs > BYTE_TIMEOUT_MS) resetParser();
    return;
  }
  lastByteMs = now;

  while (avail > 0) {
    switch (rxState) {
      case RxState::Magic0: {
        int b = Serial.read();
        avail--;
        if (b == 0xA5) rxState = RxState::Magic1;
        break;
      }
      case RxState::Magic1: {
        int b = Serial.read();
        avail--;
        if (b == 0x5A) { rxState = RxState::Header; rxCount = 0; }
        else if (b != 0xA5) rxState = RxState::Magic0;
        break;
      }
      case RxState::Header: {
        size_t n = Serial.read(hdrBuf + rxCount, min<size_t>(avail, 6 - rxCount));
        avail -= n;
        rxCount += n;
        if (rxCount == 6) {
          rxLen = hdrBuf[2] | (hdrBuf[3] << 8) | (hdrBuf[4] << 16) | ((uint32_t)hdrBuf[5] << 24);
          rxCount = 0;
          if (rxLen > MAX_PAYLOAD) {
            sendAck(hdrBuf[1], ACK_TOO_LARGE);
            rxLen += 4;  // also skip the CRC
            rxState = RxState::Skip;
          } else {
            rxState = rxLen ? RxState::Payload : RxState::Crc;
          }
        }
        break;
      }
      case RxState::Payload: {
        size_t n = Serial.read(payload + rxCount, min<size_t>(avail, rxLen - rxCount));
        avail -= n;
        rxCount += n;
        if (rxCount == rxLen) { rxState = RxState::Crc; rxCount = 0; }
        break;
      }
      case RxState::Crc: {
        size_t n = Serial.read(crcBuf + rxCount, min<size_t>(avail, 4 - rxCount));
        avail -= n;
        rxCount += n;
        if (rxCount == 4) finishPacket();
        break;
      }
      case RxState::Skip: {
        uint8_t junk[256];
        size_t n = Serial.read(junk, min<size_t>({(size_t)avail, sizeof(junk), (size_t)(rxLen - rxCount)}));
        avail -= n;
        rxCount += n;
        if (rxCount >= rxLen) resetParser();
        break;
      }
    }
  }
}

// ---------------------------------------------------------------- Arduino
void setup() {
  Serial.setRxBufferSize(32 * 1024);
  Serial.setTxTimeoutMs(50);  // never block long if the host isn't reading
  Serial.begin(115200);

  crcInit();

  payload = (uint8_t*)ps_malloc(MAX_PAYLOAD);
  if (!payload) payload = (uint8_t*)malloc(MAX_PAYLOAD);  // fallback; should not happen

  lcd.init();
  lcd.setRotation(0);
  lcd.fillScreen(TFT_BLACK);

  canvas.setPsram(true);
  canvas.setColorDepth(16);
  canvasOK = canvas.createSprite(lcd.width(), lcd.height()) != nullptr;

  lastRxMs = millis() - IDLE_TIMEOUT_MS;  // show idle screen right away
}

void loop() {
  pumpSerial();

  if (displayOn && !idleShown && millis() - lastRxMs > IDLE_TIMEOUT_MS) {
    drawIdleScreen();
  }
  if (rxState == RxState::Magic0 && Serial.available() == 0) delay(1);
}
