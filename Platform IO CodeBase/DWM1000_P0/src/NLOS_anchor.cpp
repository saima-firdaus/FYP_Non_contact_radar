#include <Arduino.h>

// ============================================================================
// ESP32_UWB_NLOS_anchor.ino
//
// DW1000 CIR capture, receiver side.
// Board: Makerfabs ESP32 UWB (DWM1000).
// Library: jremington / thotro arduino-dw1000 with the corrected readCIR().
//
// Output (CSV over serial, 921600 baud):
//   # FRAME,<n>,RX_TS,<ticks>,FP_INDEX,<x.xx>,FP_INT,<i>,RXPACC,<n>,RXPWR,<dBm>,START,<i>
//   sample,real,imag,amplitude,amplitude_norm
//   730,-412,183,450.83,0.7233
//   ...
//   # END
//
// The sample column is the ABSOLUTE accumulator index, so frames with
// different FP_INDEX values can still be overlaid correctly.
// ============================================================================

#include <SPI.h>
#include <DW1000.h>
#include <math.h>

// ---- Makerfabs ESP32 UWB pin map ----
const uint8_t PIN_RST = 27;
const uint8_t PIN_IRQ = 34;
const uint8_t PIN_SS  = 4;

// ---- CIR window ----
// The DW1000 arranges the accumulator so the LDE first path lands near tap 750.
// Reading from tap 0 gives you nothing but pre-arrival noise, so the window is
// anchored on FP_INDEX instead of on a fixed start.
const uint16_t CIR_BEFORE_FP = 50;    // was 20  -> starts ~tap 700
const uint16_t CIR_AFTER_FP  = 100;
const uint16_t CIR_LEN       = CIR_BEFORE_FP + CIR_AFTER_FP;

static CIRSample cirBuffer[CIR_LEN];

volatile boolean rxDone   = false;
volatile boolean rxFailed = false;
static uint32_t  frameCount = 0;

void handleReceived()       { rxDone   = true; }
void handleReceiveFailed()  { rxFailed = true; }
void handleReceiveTimeout() { rxFailed = true; }

void restartReceiver() {
    DW1000.newReceive();
    DW1000.startReceive();
}

void setup() {
    Serial.begin(921600);
    delay(200);

    Serial.println(F("# DW1000 CIR capture - initialising"));

    // Explicit SPI pins for the Makerfabs board (SCK, MISO, MOSI).
    SPI.begin(18, 19, 23);

    DW1000.begin(PIN_IRQ, PIN_RST);
    DW1000.select(PIN_SS);

    DW1000.newConfiguration();
    DW1000.setDefaults();

    // Must match the tag exactly - channel above all. If the tag and anchor
    // end up on different channels (e.g. only one board took a flash) they
    // cannot hear each other at all and you get zero frames, not weak ones.
    // The "# Mode:" line printed below reports the channel actually in the
    // chip - check it matches on BOTH boards before debugging anything else.
    DW1000.enableMode(DW1000.MODE_LONGDATA_RANGE_LOWPOWER);  // 110 kbps, 16 MHz PRF, 2048 preamble
    DW1000.setChannel(DW1000.CHANNEL_1);

    // ---------------------------------------------------------------------
    // IMPORTANT for CIR work: setDefaults() turns on RXAUTR (receiver
    // auto-re-enable). With it on, the receiver can restart preamble hunting
    // on its own and overwrite the accumulator while we are still reading it.
    // Turn it off and drive the receiver manually.
    // ---------------------------------------------------------------------
    DW1000.setReceiverAutoReenable(false);

    DW1000.commitConfiguration();

    DW1000.attachReceivedHandler(handleReceived);
    DW1000.attachReceiveFailedHandler(handleReceiveFailed);
    DW1000.attachReceiveTimeoutHandler(handleReceiveTimeout);

    // ---- One-off health check: SPI, DEV_ID, and the PMSC clock-enable ----
    DW1000.verifyAccumulatorAccess();

    char msg[128];
    DW1000.getPrintableDeviceMode(msg);
    Serial.print(F("# Mode: ")); Serial.println(msg);
    Serial.println(F("# Waiting for frames..."));

    restartReceiver();
}

void loop() {
    if (rxFailed) {
        rxFailed = false;
        restartReceiver();
        return;
    }
    if (!rxDone) return;
    rxDone = false;
    frameCount++;

    // ------------------------------------------------------------------
    // Read diagnostics BEFORE the accumulator read. FP_INDEX, RXPACC and
    // the RX timestamp all belong to the frame that just arrived, and
    // readCIR() forces TRXOFF, so nothing here disturbs them.
    // ------------------------------------------------------------------
    DW1000Time rxTime;
    DW1000.getReceiveTimestamp(rxTime);

    const uint16_t fpRaw  = DW1000.getFirstPathIndex();        // 1/64 sample units
    const uint16_t fpInt  = fpRaw >> 6;
    const uint16_t rxpacc = DW1000.getPreambleAccumulationCount();
    const float    rxPwr  = DW1000.getReceivePower();

    // ------------------------------------------------------------------
    // OPTIONAL: frame-dropout detection via the tag's own sequence number.
    //
    // frameCount above only counts what THIS anchor successfully processed
    // - it is always gap-free by construction and cannot show you what the
    // tag sent that never arrived at all (RF-level loss: too far, too weak,
    // AGC saturation, tag's TX_INTERVAL_MS outrunning the anchor's own
    // per-frame serial-print time, etc). That is different from a byte
    // getting corrupted mid-line on the serial link, which the sample-index
    // sanity check in the analysis scripts already catches.
    //
    // setup_tag.cpp's txData[] is {0xC0,0xFF,0xEE,<4-byte txCount>}. Reading
    // it back here and printing it as TAG_SEQ lets tools/dw1000_cir.py and
    // cir_cap3.m spot exact gaps in the tag's counter - both already parse
    // every key,value pair on the "# FRAME" line generically, so no parser
    // change is needed there once this field starts showing up.
    //
    // Must run here, BEFORE readCIRAroundFirstPath() below: that call forces
    // TRXOFF, and getData()/getDataLength() only return real values while
    // _deviceMode is still RX_MODE.
    //
    // Uncomment this block AND the matching Serial.print below together.
    // uint32_t tagSeq = 0;
    // byte payload[7];
    // if (DW1000.getDataLength() >= 7) {
    //     DW1000.getData(payload, 7);
    //     memcpy(&tagSeq, payload + 3, sizeof(tagSeq));
    // }

    uint16_t startIndex = 0;
    const int n = DW1000.readCIRAroundFirstPath(cirBuffer,
                                                CIR_BEFORE_FP,
                                                CIR_AFTER_FP,
                                                &startIndex);
    if (n <= 0) {
        Serial.println(F("# ERROR: readCIR failed"));
        restartReceiver();
        return;
    }

    // Normalisation: the accumulator is a coherent sum over RXPACC preamble
    // symbols, so dividing by RXPACC makes amplitudes comparable across frames.
    const float norm = (rxpacc > 0) ? (float)rxpacc : 1.0f;

    char tsBuf[24];
    snprintf(tsBuf, sizeof(tsBuf), "%lld", (long long)rxTime.getTimestamp());

    Serial.print(F("# FRAME,"));   Serial.print(frameCount);
    Serial.print(F(",RX_TS,"));    Serial.print(tsBuf);
    Serial.print(F(",FP_INDEX,")); Serial.print(fpRaw / 64.0f, 4);
    Serial.print(F(",FP_INT,"));   Serial.print(fpInt);
    Serial.print(F(",RXPACC,"));   Serial.print(rxpacc);
    Serial.print(F(",RXPWR,"));    Serial.print(rxPwr, 2);
    Serial.print(F(",START,"));    Serial.print(startIndex);
    // Serial.print(F(",TAG_SEQ,")); Serial.print(tagSeq);   // uncomment together with the read block above
    Serial.println();

    Serial.println(F("sample,real,imag,amplitude,amplitude_norm"));

    for (int i = 0; i < n; i++) {
        const float I = (float)cirBuffer[i].real;
        const float Q = (float)cirBuffer[i].imag;
        const float amplitude = sqrtf(I * I + Q * Q);

        Serial.print(startIndex + i);        Serial.print(',');
        Serial.print(cirBuffer[i].real);     Serial.print(',');
        Serial.print(cirBuffer[i].imag);     Serial.print(',');
        Serial.print(amplitude, 2);          Serial.print(',');
        Serial.println(amplitude / norm, 5);
    }

    Serial.println(F("# END"));

    restartReceiver();
}

