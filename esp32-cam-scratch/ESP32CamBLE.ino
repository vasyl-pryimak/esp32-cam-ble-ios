#include "esp_camera.h"
#include "soc/soc.h"
#include "soc/rtc_cntl_reg.h"
#include <BLEDevice.h>
#include <BLEServer.h>
#include <BLEUtils.h>
#include <BLE2902.h>

// ===================
// Select camera model
// ===================
#define CAMERA_MODEL_AI_THINKER // Has PSRAM
#include "camera_pins.h"

// ===========================
// BLE UUIDs
// ===========================
#define SERVICE_UUID           "e5320ca0-0001-0001-0001-000000000001"
#define CHAR_COMMAND_UUID      "e5320ca0-0001-0001-0001-000000000002"
#define CHAR_PHOTO_INFO_UUID   "e5320ca0-0001-0001-0001-000000000003"
#define CHAR_PHOTO_DATA_UUID   "e5320ca0-0001-0001-0001-000000000004"
#define CHAR_STATUS_UUID       "e5320ca0-0001-0001-0001-000000000005"

// BLE globals
BLEServer *pServer = NULL;
BLECharacteristic *pCommandChar = NULL;
BLECharacteristic *pPhotoInfoChar = NULL;
BLECharacteristic *pPhotoDataChar = NULL;
BLECharacteristic *pStatusChar = NULL;
bool deviceConnected = false;
bool sendingPhoto = false;

// Photo buffer in PSRAM
uint8_t *last_photo_buf = NULL;
size_t last_photo_len = 0;

// LED flash
int ledIntensity = 50;
void setupLedFlash(int pin) {
  ledcSetup(0, 5000, 8);       // channel 0, 5kHz, 8-bit
  ledcAttachPin(pin, 0);       // attach pin to channel 0
  ledcWrite(0, 0);             // off
}

// Timers in RTC memory (survive deep sleep)
RTC_DATA_ATTR uint32_t sleepHours = 24;    // deep sleep interval (hours)
RTC_DATA_ATTR uint32_t awakeMinutes = 5;   // stay awake time (minutes)

// Forward declarations
void sendPhotoData();
void sendStatus();

// Flow control
volatile bool nextBatchRequested = false;
volatile bool startSendingPhoto = false;

// ===========================
// BLE Callbacks
// ===========================
class ServerCallbacks : public BLEServerCallbacks {
  void onConnect(BLEServer *pServer) {
    deviceConnected = true;
    Serial.println("BLE: iPhone connected");
  }

  void onDisconnect(BLEServer *pServer) {
    deviceConnected = false;
    sendingPhoto = false;
    Serial.println("BLE: iPhone disconnected");
    // Restart advertising
    delay(500);
    pServer->startAdvertising();
    Serial.println("BLE: Advertising restarted");
  }
};

// Commands: "capture", "saved", "flash:XXX"
class CommandCallbacks : public BLECharacteristicCallbacks {
  void onWrite(BLECharacteristic *pCharacteristic) {
    String cmd = pCharacteristic->getValue().c_str();
    Serial.printf("BLE cmd: %s\n", cmd.c_str());

    if (cmd == "capture") {
      // Flash on before capture
#if defined(LED_GPIO_NUM)
      ledcWrite(0, ledIntensity);
      delay(100);
#endif

      // Take new photo
      camera_fb_t *fb = esp_camera_fb_get();

      // Flash off after capture
#if defined(LED_GPIO_NUM)
      ledcWrite(0, 0);
#endif

      if (fb && fb->format == PIXFORMAT_JPEG) {
        if (last_photo_buf) free(last_photo_buf);
        last_photo_buf = (uint8_t *)ps_malloc(fb->len);
        if (last_photo_buf) {
          memcpy(last_photo_buf, fb->buf, fb->len);
          last_photo_len = fb->len;
          Serial.printf("Photo captured: %u bytes\n", fb->len);
        }
        esp_camera_fb_return(fb);
      } else {
        if (fb) esp_camera_fb_return(fb);
        Serial.println("Capture failed");
        // Notify with size 0 = error
        uint32_t zero = 0;
        pPhotoInfoChar->setValue((uint8_t *)&zero, 4);
        pPhotoInfoChar->notify();
        return;
      }

      // Notify photo size
      uint32_t size = (uint32_t)last_photo_len;
      pPhotoInfoChar->setValue((uint8_t *)&size, 4);
      pPhotoInfoChar->notify();

    } else if (cmd == "saved") {
      // Send last saved photo info
      uint32_t size = (uint32_t)last_photo_len;
      pPhotoInfoChar->setValue((uint8_t *)&size, 4);
      pPhotoInfoChar->notify();

    } else if (cmd == "send") {
      // Flag to start sending from loop()
      startSendingPhoto = true;

    } else if (cmd == "next") {
      // Flow control: iPhone ready for next batch
      nextBatchRequested = true;

    } else if (cmd.startsWith("framesize:")) {
      int val = cmd.substring(10).toInt();
      sensor_t *s = esp_camera_sensor_get();
      if (s && val >= 0 && val <= 17) {
        s->set_framesize(s, (framesize_t)val);
        Serial.printf("Framesize set to: %d\n", val);
      }
      sendStatus();

    } else if (cmd.startsWith("flash:")) {
      int val = cmd.substring(6).toInt();
      ledIntensity = constrain(val, 0, 255);

#if defined(LED_GPIO_NUM)
      ledcWrite(0, ledIntensity);
#endif

      Serial.printf("Flash set to: %d\n", ledIntensity);
      sendStatus();

    } else if (cmd.startsWith("sleep:")) {
      int val = cmd.substring(6).toInt();
      if (val >= 1 && val <= 168) {  // 1h to 7 days
        sleepHours = val;
        Serial.printf("Sleep interval set to: %d hours\n", sleepHours);
      }
      sendStatus();

    } else if (cmd.startsWith("awake:")) {
      int val = cmd.substring(6).toInt();
      if (val >= 1 && val <= 60) {  // 1 to 60 minutes
        awakeMinutes = val;
        Serial.printf("Awake time set to: %d minutes\n", awakeMinutes);
      }
      sendStatus();
    }
  }
};

// ===========================
// Send photo over BLE in chunks
// ===========================
void sendPhotoData() {
  if (!last_photo_buf || last_photo_len == 0 || !deviceConnected) {
    Serial.println("No photo to send or not connected");
    return;
  }

  sendingPhoto = true;
  size_t chunkSize = 200;  // smaller chunks for stability
  size_t offset = 0;
  int batchSize = 10;      // send 10 chunks, then wait for "next"

  Serial.printf("Sending %u bytes (%u-byte chunks, batch of %d)...\n",
                last_photo_len, chunkSize, batchSize);

  while (offset < last_photo_len && deviceConnected && sendingPhoto) {
    // Send a batch of chunks
    for (int i = 0; i < batchSize && offset < last_photo_len && deviceConnected; i++) {
      size_t toSend = min(chunkSize, last_photo_len - offset);
      pPhotoDataChar->setValue(last_photo_buf + offset, toSend);
      pPhotoDataChar->notify();
      offset += toSend;
      delay(30);  // breathing room for BLE stack
    }

    Serial.printf("BLE sent: %u/%u bytes (%d%%)\n", offset, last_photo_len,
                   (int)(offset * 100 / last_photo_len));

    if (offset >= last_photo_len) break;

    // Wait for iPhone to send "next" (flow control)
    nextBatchRequested = false;
    unsigned long waitStart = millis();
    while (!nextBatchRequested && deviceConnected && millis() - waitStart < 10000) {
      delay(10);
    }

    if (!nextBatchRequested && deviceConnected) {
      Serial.println("BLE: Timeout waiting for 'next', continuing anyway");
    }
  }

  if (offset >= last_photo_len) {
    delay(50);
    // Send empty notification = transfer complete
    pPhotoDataChar->setValue((uint8_t*)"", 0);
    pPhotoDataChar->notify();
    Serial.printf("BLE: Photo sent complete (%u bytes)\n", last_photo_len);
  }

  sendingPhoto = false;
}

// ===========================
// Send status info
// ===========================
void sendStatus() {
  if (!deviceConnected) return;

  int currentFrameSize = 0;
  sensor_t *s = esp_camera_sensor_get();
  if (s) currentFrameSize = s->status.framesize;

  char status[256];
  snprintf(status, sizeof(status),
           "{\"led\":%d,\"psram_free\":%u,\"photo_size\":%u,\"uptime\":%lu,\"sleep_h\":%u,\"awake_m\":%u,\"framesize\":%d}",
           ledIntensity,
           (unsigned int)ESP.getFreePsram(),
           (unsigned int)last_photo_len,
           millis() / 1000,
           sleepHours,
           awakeMinutes,
           currentFrameSize);

  pStatusChar->setValue(status);
  pStatusChar->notify();
}

void setup() {

  Serial.begin(115200);
  Serial.println();
  Serial.println("ESP32-CAM BLE Mode");

  // Camera config
  camera_config_t config;
  config.ledc_channel = LEDC_CHANNEL_0;
  config.ledc_timer = LEDC_TIMER_0;
  config.pin_d0 = Y2_GPIO_NUM;
  config.pin_d1 = Y3_GPIO_NUM;
  config.pin_d2 = Y4_GPIO_NUM;
  config.pin_d3 = Y5_GPIO_NUM;
  config.pin_d4 = Y6_GPIO_NUM;
  config.pin_d5 = Y7_GPIO_NUM;
  config.pin_d6 = Y8_GPIO_NUM;
  config.pin_d7 = Y9_GPIO_NUM;
  config.pin_xclk = XCLK_GPIO_NUM;
  config.pin_pclk = PCLK_GPIO_NUM;
  config.pin_vsync = VSYNC_GPIO_NUM;
  config.pin_href = HREF_GPIO_NUM;
  config.pin_sccb_sda = SIOD_GPIO_NUM;
  config.pin_sccb_scl = SIOC_GPIO_NUM;
  config.pin_pwdn = PWDN_GPIO_NUM;
  config.pin_reset = RESET_GPIO_NUM;
  config.xclk_freq_hz = 20000000;
  config.frame_size = FRAMESIZE_VGA;
  config.pixel_format = PIXFORMAT_JPEG;
  config.grab_mode = CAMERA_GRAB_WHEN_EMPTY;
  config.fb_location = CAMERA_FB_IN_PSRAM;
  config.jpeg_quality = 15;
  config.fb_count = 1;

  if (psramFound()) {
    config.fb_count = 2;
    config.grab_mode = CAMERA_GRAB_LATEST;
    Serial.printf("PSRAM found: %u bytes free\n", ESP.getFreePsram());
  }

  // Camera init
  esp_err_t err = esp_camera_init(&config);
  if (err != ESP_OK) {
    Serial.printf("Camera init failed: 0x%x\n", err);
    return;
  }

  sensor_t *s = esp_camera_sensor_get();
  if (s->id.PID == OV3660_PID) {
    s->set_vflip(s, 1);
    s->set_brightness(s, 1);
    s->set_saturation(s, -2);
  }
  s->set_framesize(s, FRAMESIZE_VGA);

  // LED Flash
#if defined(LED_GPIO_NUM)
  setupLedFlash(LED_GPIO_NUM);
#endif

  // ===========================
  // BLE Setup
  // ===========================
  BLEDevice::init("ESP32-CAM");
  BLEDevice::setMTU(517);  // Request max MTU

  pServer = BLEDevice::createServer();
  pServer->setCallbacks(new ServerCallbacks());

  BLEService *pService = pServer->createService(BLEUUID(SERVICE_UUID), 20);

  // Command characteristic (write)
  pCommandChar = pService->createCharacteristic(
      BLEUUID(CHAR_COMMAND_UUID),
      BLECharacteristic::PROPERTY_WRITE);
  pCommandChar->setCallbacks(new CommandCallbacks());

  // Photo info characteristic (notify) - sends photo size
  pPhotoInfoChar = pService->createCharacteristic(
      BLEUUID(CHAR_PHOTO_INFO_UUID),
      BLECharacteristic::PROPERTY_READ | BLECharacteristic::PROPERTY_NOTIFY);
  pPhotoInfoChar->addDescriptor(new BLE2902());

  // Photo data characteristic (notify) - sends photo chunks
  pPhotoDataChar = pService->createCharacteristic(
      BLEUUID(CHAR_PHOTO_DATA_UUID),
      BLECharacteristic::PROPERTY_NOTIFY);
  pPhotoDataChar->addDescriptor(new BLE2902());

  // Status characteristic (notify)
  pStatusChar = pService->createCharacteristic(
      BLEUUID(CHAR_STATUS_UUID),
      BLECharacteristic::PROPERTY_READ | BLECharacteristic::PROPERTY_NOTIFY);
  pStatusChar->addDescriptor(new BLE2902());

  pService->start();

  BLEAdvertising *pAdvertising = BLEDevice::getAdvertising();
  pAdvertising->addServiceUUID(BLEUUID(SERVICE_UUID));
  pAdvertising->setScanResponse(true);
  pAdvertising->setMinPreferred(0x06);
  pAdvertising->setMinPreferred(0x12);
  BLEDevice::startAdvertising();

  Serial.println("BLE: Advertising started, waiting for iPhone...");
  Serial.println("Will go to deep sleep in 5 minutes if no connection.");
}

// Calculated from RTC variables

unsigned long lastActivity = 0;

void loop() {
  if (lastActivity == 0) lastActivity = millis();

  // Reset timer when device is connected
  if (deviceConnected) {
    lastActivity = millis();
  }

  // Send photo if requested (outside BLE callback to avoid deadlock)
  if (startSendingPhoto && deviceConnected) {
    startSendingPhoto = false;
    sendPhotoData();
  }

  // Send status every 10 seconds if connected
  static unsigned long lastStatus = 0;
  if (deviceConnected && millis() - lastStatus > 10000) {
    sendStatus();
    lastStatus = millis();
  }

  // Auto deep sleep after N min of no connection
  unsigned long stayAwakeMs = (unsigned long)awakeMinutes * 60UL * 1000UL;
  if (millis() - lastActivity > stayAwakeMs) {
    uint64_t sleepUs = (uint64_t)sleepHours * 3600ULL * 1000000ULL;
    Serial.printf("No connection for %u min. Deep sleep for %u hours...\n", awakeMinutes, sleepHours);
    esp_sleep_enable_timer_wakeup(sleepUs);
    esp_deep_sleep_start();
  }

  delay(1000);
}
