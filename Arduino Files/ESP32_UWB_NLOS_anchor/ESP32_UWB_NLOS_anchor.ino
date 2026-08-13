// anchor #4 setup — CIR graph variant (minimal)
//
// Base ranging code unchanged from ESP32_UWB_setup_anchor.ino.
// Added: raw CIR capture, dumped every range so it can be watched live in
// Arduino's Serial Plotter. No baseline subtraction, no peak-picking, no
// calibration — just the raw accumulator, as-is, so you can look at the
// shape yourself and see where any peaks sit relative to the noise floor.
//
// REQUIRES the DW1000 library patch described in DW1000_library_patch.md
// (adds DW1000.getAccumulator() and DW1000.getStdNoise()), including the
// ACC_MEM define — see that file for where to put it.
//
// HOW TO VIEW: Tools > Serial Plotter, baud set to 460800 (must match
// Serial.begin() below). Two traces get plotted per sample: "mag" is the
// CIR magnitude curve itself, "noise" is a flat reference line at the
// hardware noise-floor level, so you can see directly which bumps in
// "mag" clear it and which don't.
//
// NOTE: dumping ~992 lines per range takes real time even at 460800 baud
// (roughly a third of a second). If ranging feels like it stalls or the
// tag drops out while this is running, that's why — this sketch trades
// ranging speed for a live graph. That's fine for observing peaks by eye;
// once you know what you're looking for you'll likely want to gate this
// behind an on-demand command again instead of dumping every range.

#include <SPI.h>
#include "DW1000Ranging.h"
#include "DW1000.h"

// ---------- existing anchor config (unchanged) ----------
char anchor_addr[] = "84:00:5B:D5:A9:9A:E2:9C"; //#4
uint16_t Adelay = 16580;
float dist_m = (285 - 1.75) * 0.0254; //meters

#define SPI_SCK 18
#define SPI_MISO 19
#define SPI_MOSI 23
#define DW_CS 4

const uint8_t PIN_RST = 27;
const uint8_t PIN_IRQ = 34;
const uint8_t PIN_SS = 4;

// ---------- CIR config ----------
// MODE_LONGDATA_RANGE_LOWPOWER uses TX_PULSE_FREQ_16MHZ -> 992 complex accumulator
// samples. If you switch to a 64 MHz PRF mode (the *_ACCURACY variants), this
// becomes 1016 and NUM_CIR_SAMPLES must change accordingly.
#define NUM_CIR_SAMPLES 992
#define ACC_BYTES (NUM_CIR_SAMPLES * 4)   // 4 bytes per complex sample (16-bit I + 16-bit Q)

static byte  rawAcc[ACC_BYTES + 1];   // +1 for the ACC_MEM dummy byte
static float cirMag[NUM_CIR_SAMPLES];

void setup()
{
  Serial.begin(460800);
  delay(1000);

  SPI.begin(SPI_SCK, SPI_MISO, SPI_MOSI);
  DW1000Ranging.initCommunication(PIN_RST, PIN_SS, PIN_IRQ);

  DW1000.setAntennaDelay(Adelay);

  DW1000Ranging.attachNewRange(newRange);
  DW1000Ranging.attachNewDevice(newDevice);
  DW1000Ranging.attachInactiveDevice(inactiveDevice);

  DW1000Ranging.startAsAnchor(anchor_addr, DW1000.MODE_LONGDATA_RANGE_LOWPOWER, false);

  // header row so Serial Plotter labels the two traces
  Serial.println("mag,noise");
}

void loop()
{
  DW1000Ranging.loop();
}

// pulls the CIR + noise floor for the most recently received frame and
// fills cirMag[]. Returns the noise floor value.
float captureCIR()
{
  float noise = DW1000.getStdNoise();
  DW1000.getAccumulator(rawAcc, ACC_BYTES, 0);

  // rawAcc[0] is the dummy byte; real samples start at rawAcc[1]
  for (int i = 0; i < NUM_CIR_SAMPLES; i++) {
    int off = 1 + i * 4;
    int16_t re = (int16_t)(rawAcc[off]     | (rawAcc[off + 1] << 8));
    int16_t im = (int16_t)(rawAcc[off + 2] | (rawAcc[off + 3] << 8));
    cirMag[i] = sqrtf((float)re * re + (float)im * im);
  }
  return noise;
}

void newRange()
{
  float noise = captureCIR();

  // one row per sample: mag = CIR magnitude at that delay bin, noise = flat
  // reference line at the hardware noise-floor level.
  for (int i = 0; i < NUM_CIR_SAMPLES; i++) {
    Serial.print(cirMag[i]);
    Serial.print(",");
    Serial.println(noise);
  }
}

void newDevice(DW1000Device *device)
{
  // kept quiet on purpose — text lines mixed into numeric CIR rows will
  // confuse Serial Plotter's parser. Uncomment if you need it for debugging,
  // then comment back out before watching the graph.
  // Serial.print("Device added: ");
  // Serial.println(device->getShortAddress(), HEX);
}

void inactiveDevice(DW1000Device *device)
{
  // Serial.print("Delete inactive device: ");
  // Serial.println(device->getShortAddress(), HEX);
}
