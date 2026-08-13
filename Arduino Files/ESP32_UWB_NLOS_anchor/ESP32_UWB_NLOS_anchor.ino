// ============================================================
// CIR_Test.ino
//
// Purpose: Prove that the DW1000 CIR accumulator can be read.
// Upload to the ANCHOR (receiver) side.
// The TAG should be running normally and transmitting frames.
//
// Hardware: Makerfabs DWM1000 on Arduino
// Library:  thotro arduino-dw1000 (modified with readCIR())
//
// Serial output format (115200 baud):
//   sample,real,imag,magnitude_sq
//   0,123,-45,16938
//   1,127,-51,17722
//   ...
//
// NOTE: magnitude_sq = I^2 + Q^2 (avoids float sqrt on Arduino)
// ============================================================

#include <SPI.h>
#include <DW1000.h>

// ---- Pin definitions for Makerfabs DWM1000 ----
// Adjust these to match your wiring.
// Common Makerfabs wiring (verify against your schematic):
const uint8_t PIN_RST = 27;   // was 9
const uint8_t PIN_IRQ = 34;   // was 2
const uint8_t PIN_SS  = 4;    // was SS (default macro)

// ---- CIR configuration ----
// How many samples to read per frame.
// Full accumulator = 1016 samples, but that takes ~200 ms to print at 115200.
// Start with 200 samples to verify operation, then increase.
const uint16_t CIR_START_SAMPLE = 0;
// PRF 16 MHz: max 992 samples; PRF 64 MHz: max 1016 samples.
// Start with 200 samples to verify operation, increase later.
const uint16_t CIR_NUM_SAMPLES  = 200;

// Sample buffer (on heap to avoid stack overflow)
static CIRSample cirBuffer[CIR_NUM_SAMPLES];

// State
volatile boolean rxDone    = false;
volatile boolean rxFailed  = false;
static uint32_t  frameCount = 0;

// ---- Interrupt / callback ----
void handleReceived() {
    rxDone = true;
}

void handleReceiveFailed() {
    rxFailed = true;
}

void handleReceiveTimeout() {
    rxFailed = true;
}

// ---- Setup ----
void setup() {
    Serial.begin(115200);
    while (!Serial) { ; }  // Wait for Serial (Leonardo/Micro only)

    Serial.println(F("# DW1000 CIR Test — initialising..."));

    // Initialise DW1000
    DW1000.begin(PIN_IRQ, PIN_RST);
    Serial.println(F("#1"));
    DW1000.select(PIN_SS);
    Serial.println(F("#2"));

    DW1000.newConfiguration();
    Serial.println(F("#3"));
    DW1000.setDefaults();
    Serial.println(F("#4"));

    // ---- Match these settings to your Tag ----
    // Your tag (ESP32_UWB_setup_tag.ino) calls:
    //   DW1000Ranging.startAsTag(tag_addr, DW1000.MODE_LONGDATA_RANGE_LOWPOWER, false);
    // which is 110 kbps data rate, 16 MHz PRF, 2048 preamble length.
    // Channel, PRF, data rate, preamble length, and preamble code
    // MUST be identical on Tag and Anchor, or you will not receive frames.
    // enableMode() sets data rate + PRF + preamble length together, then
    // setChannel() automatically picks the matching preamble code for that
    // channel/PRF combo (see DW1000Class::setChannel in DW1000.cpp) — for
    // channel 5 @ 16 MHz PRF that's PREAMBLE_CODE_16MHZ_4.
    DW1000.enableMode(DW1000.MODE_LONGDATA_RANGE_LOWPOWER);
    Serial.println(F("#5")); // match Tag
    DW1000.setChannel(DW1000.CHANNEL_5);  
    Serial.println(F("#6"));                  // match Tag

    DW1000.commitConfiguration();
    Serial.println(F("#7"));

    // Attach callbacks
    DW1000.attachReceivedHandler(handleReceived);
    Serial.println(F("#8"));
    DW1000.attachReceiveFailedHandler(handleReceiveFailed);
    Serial.println(F("#9"));
    DW1000.attachReceiveTimeoutHandler(handleReceiveTimeout);
    Serial.println(F("#10"));

    Serial.println(F("# DW1000 initialised. Waiting for frames..."));
    Serial.println(F("# Output: sample,real,imag,magnitude_sq"));

    // Start receiver
    DW1000.startReceive();
}

// ---- Main loop ----
void loop() {
    if (rxFailed) {
        rxFailed = false;
        // Restart receiver on error
        DW1000.startReceive();
        return;
    }

    if (!rxDone) {
        return;  // Nothing received yet
    }

    rxDone = false;
    frameCount++;

    // ================================================================
    // IMPORTANT: Read the CIR BEFORE calling any function that
    // re-enables the receiver or clears RX status.
    // The accumulator is valid from RXDFR/LDEDONE until TRXOFF or
    // a new RX enable.
    // ================================================================

    // Read CIR from accumulator
    int samplesRead = DW1000.readCIR(cirBuffer, CIR_START_SAMPLE, CIR_NUM_SAMPLES);

    if (samplesRead <= 0) {
        Serial.println(F("# ERROR: readCIR returned 0 or error"));
        DW1000.startReceive();
        return;
    }

    // Print header
    Serial.print(F("# Frame "));
    Serial.println(frameCount);
    Serial.println(F("sample,real,imag,magnitude_sq"));

    // Print CIR data
    for (int i = 0; i < samplesRead; i++) {
        int32_t I = (int32_t)cirBuffer[i].real;
        int32_t Q = (int32_t)cirBuffer[i].imag;
        int32_t magSq = I*I + Q*Q;  // magnitude squared (avoids sqrt)

        Serial.print(CIR_START_SAMPLE + i);
        Serial.print(',');
        Serial.print(cirBuffer[i].real);
        Serial.print(',');
        Serial.print(cirBuffer[i].imag);
        Serial.print(',');
        Serial.println(magSq);
    }

    Serial.println(F("# END"));

    // Re-enable receiver for next frame
    DW1000.startReceive();
}