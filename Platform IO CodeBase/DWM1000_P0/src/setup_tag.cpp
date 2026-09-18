#include <Arduino.h>

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
// CIR_LEN on the anchor is 150 samples (CIR_BEFORE_FP=50 + CIR_AFTER_FP=100).
// Printing that as CSV - header line, column header, 150 data rows, "# END" -
// is ~4.3 KB of text. At 921600 baud (8N1 = 92160 bytes/sec) that is
// ~47 ms of serial time alone, BEFORE the accumulator SPI read, register
// diagnostics, and restartReceiver() - and the receiver is fully off
// (TRXOFF) for every millisecond of it, since restartReceiver() is the last
// line of the anchor's loop(). The previous 50 ms interval left ~0 ms of
// margin against that, which is consistent with the frame count varying
// wildly run to run (0, 5, 130...) rather than settling near a fixed rate -
// it was a race, not a steady bottleneck. 100 ms gives the anchor roughly
// 2x headroom over its own measured worst case.
// const uint32_t TX_INTERVAL_MS = 100;   // ~10 Hz -> faster, but less margin for the anchor to finish its serial output before the next frame arrives
const uint32_t TX_INTERVAL_MS = 50;   // ~20 Hz

// Minimal fixed payload -- content doesn't matter for CIR capture, only that
// a valid, correctly-configured frame goes out. A frame counter is included
// purely so you can eyeball tag-side vs. anchor-side counts if you want to
// check for drops later.
byte txData[] = {0xC0, 0xFF, 0xEE, 0x00, 0x00, 0x00, 0x00};

uint32_t lastTx = 0;
uint32_t txCount = 0;

void setup() {
    Serial.begin(921600);   // matches monitor_speed for uwb_tag in platformio.ini
    delay(200);

    Serial.println(F("# DW1000 CIR tag (bare periodic TX) - initialising"));

    SPI.begin(18, 19, 23);   // explicit SCK, MISO, MOSI for the Makerfabs board

    DW1000.begin(PIN_IRQ, PIN_RST);
    DW1000.select(PIN_SS);

    DW1000.newConfiguration();
    DW1000.setDefaults();

    // Must match the anchor exactly: channel, PRF, data rate, preamble length.
    DW1000.enableMode(DW1000.MODE_LONGDATA_RANGE_LOWPOWER);
    DW1000.setChannel(DW1000.CHANNEL_1);
    DW1000.commitConfiguration();

    // ---- TX power, 5 dB below the library default --------------------------
    // Must come AFTER commitConfiguration(), which is what writes tune()'s
    // per-channel default - anything set before it gets overwritten.
    //
    // Default for channel 1/2 at 16 MHz PRF in manual power mode is
    // 0x75757575 (DW1000 User Manual Table 19). Each byte is a coarse (DA,
    // 3 dB/step, bits 7-5) + fine (mixer, 0.5 dB/step, bits 4-0) pair:
    //   0x75 = 011 10101 -> coarse 9 dB + fine 21*0.5 = 10.5 dB = 19.5 dB
    //   0x6B = 011 01011 -> coarse 9 dB + fine 11*0.5 =  5.5 dB = 14.5 dB
    // Coarse is left alone (best spectral shape per the manual); only the
    // fine field drops by 10 steps = exactly 5.0 dB.
    //
    // If the link fails, comment this line out FIRST to separate a TX-power
    // problem from a channel problem - they are independent variables.
    DW1000.setTXPower(0x6B6B6B6BL);

    char msg[128];
    DW1000.getPrintableDeviceMode(msg);
    Serial.print(F("# Mode: ")); Serial.println(msg);
    Serial.println(F("# TX power: 0x6B6B6B6B (5 dB below default)"));
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
