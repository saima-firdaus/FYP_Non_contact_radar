// ============================================================================
// ESP32_UWB_NLOS_tag.ino
//
// DW1000 CIR capture, TRANSMITTER side.
// Board: Makerfabs ESP32 UWB (DWM1000).
// Library: jremington / thotro arduino-dw1000.
//
// This REPLACES the DW1000Ranging-based tag sketch. It does not attempt to
// range, discover, or hold a conversation with the anchor at all -- it just
// fires a short frame on a fixed timer, forever. See the explanation below
// for why this is necessary now that the anchor no longer runs the ranging
// protocol either.
// ============================================================================

#include <SPI.h>
#include <DW1000.h>

// ---- Makerfabs ESP32 UWB pin map (same board as the anchor) ----
const uint8_t PIN_RST = 27;
const uint8_t PIN_IRQ = 34;
const uint8_t PIN_SS  = 4;

// ---- Transmit cadence ----
// The anchor currently needs roughly 25-35 ms to read the accumulator and
// print one CIR frame at 921600 baud before it's listening again. 50 ms
// gives it a comfortable, consistent window to be ready for each
// transmission, rather than firing faster than the anchor can ever use.
// Tighten this once the anchor side is optimised, or loosen it if you see
// the anchor's error counter climbing.
const uint32_t TX_INTERVAL_MS = 50;   // ~20 Hz

// Minimal fixed payload -- content doesn't matter for CIR capture, only that
// a valid, correctly-configured frame goes out. A frame counter is included
// purely so you can eyeball tag-side vs. anchor-side counts if you want to
// check for drops later.
byte txData[] = {0xC0, 0xFF, 0xEE, 0x00, 0x00, 0x00, 0x00};

uint32_t lastTx = 0;
uint32_t txCount = 0;

void setup() {
    Serial.begin(115200);
    delay(200);

    Serial.println(F("# DW1000 CIR tag (bare periodic TX) - initialising"));

    SPI.begin(18, 19, 23);   // explicit SCK, MISO, MOSI for the Makerfabs board

    DW1000.begin(PIN_IRQ, PIN_RST);
    DW1000.select(PIN_SS);

    DW1000.newConfiguration();
    DW1000.setDefaults();

    // Must match the anchor exactly: channel, PRF, data rate, preamble length.
    DW1000.enableMode(DW1000.MODE_LONGDATA_RANGE_LOWPOWER);
    DW1000.setChannel(DW1000.CHANNEL_5);
    DW1000.commitConfiguration();

    char msg[128];
    DW1000.getPrintableDeviceMode(msg);
    Serial.print(F("# Mode: ")); Serial.println(msg);
    Serial.println(F("# Transmitting..."));
}

void sendFrame() {
    txCount++;
    memcpy(txData + 3, &txCount, sizeof(txCount));

    DW1000.newTransmit();
    DW1000.setDefaults();
    DW1000.setData(txData, sizeof(txData));
    DW1000.startTransmit();
}

void loop() {
    const uint32_t now = millis();
    if (now - lastTx >= TX_INTERVAL_MS) {
        lastTx = now;
        sendFrame();
    }
}
