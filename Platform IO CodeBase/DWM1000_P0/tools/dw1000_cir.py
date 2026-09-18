"""Shared serial-protocol parsing for the DW1000 CIR anchor stream.

Used by cir_live_mti.py and cir_snapshot.py so the frame-parsing and
tap-to-distance conversion logic isn't duplicated (and doesn't drift) across
tools. Not meant to be run directly.

Reads the per-frame CIR dump that src/NLOS_anchor.cpp prints over serial:

    # FRAME,<n>,RX_TS,<ts>,FP_INDEX,<f>,FP_INT,<i>,RXPACC,<r>,RXPWR,<p>,START,<s>
    sample,real,imag,amplitude,amplitude_norm
    <sample>,<real>,<imag>,<amplitude>,<amplitude_norm>
    ...
    # END
"""

import threading
import time
from collections import deque

import numpy as np
import serial


def build_grid(taps_before, taps_after, step):
    return np.arange(-taps_before, taps_after + step * 0.5, step)


# One accumulator tap = 1.0016 ns = 30.028 cm of propagation (from include/cir_cap3.m).
TAP_TO_METRES = 0.30028


def build_distance_axis(grid, tag_anchor_dist):
    """Ellipse-geometry conversion from tap offset to physical distance.

    A multipath component arriving `excess` metres later than the direct
    path travelled tag -> reflector -> anchor = tag_anchor_dist + excess in
    total. Every point with that total path length lies on an ellipse whose
    foci are the tag and the anchor, with semi-major axis
    a = (tag_anchor_dist + excess) / 2; the semi-minor axis
    b = sqrt(a^2 - (tag_anchor_dist/2)^2) is the perpendicular distance from
    the midpoint of the tag-anchor line out to that ellipse - i.e. how far
    off the direct line the reflecting object is. Ported from the batch
    MATLAB version's panel-3 conversion (include/cir_cap3.m).

    b(excess) is monotonic but nonlinear (steep near excess=0), so it can't
    just relabel the uniform tap grid without distorting the near-field
    region - the caller resamples onto the uniform b_display returned here
    before plotting.
    """
    excess = grid * TAP_TO_METRES
    valid_mask = excess >= 0  # taps before the first path have no ellipse solution
    c = tag_anchor_dist / 2.0
    a = (excess[valid_mask] + tag_anchor_dist) / 2.0
    b_valid = np.sqrt(np.maximum(a * a - c * c, 0.0))
    b_display = np.linspace(0.0, b_valid[-1], num=b_valid.size) if b_valid.size else b_valid
    return b_valid, valid_mask, b_display


def parse_frame_header(line):
    parts = [p.strip() for p in line.split(",")]
    if len(parts) < 2 or len(parts) % 2 != 0:
        return None
    meta = {}
    for i in range(0, len(parts) - 1, 2):
        key = parts[i].lstrip("#").strip()
        try:
            meta[key] = float(parts[i + 1])
        except ValueError:
            return None
    if "FRAME" not in meta or "START" not in meta or "FP_INDEX" not in meta:
        return None
    return meta


class FrameAssembler:
    """Ports the parsing state machine from include/cir_cap3.m to Python."""

    def __init__(self):
        self.current_frame_num = None
        self.current_meta = None
        self.samples = []
        self.real = []
        self.imag = []
        self.rejected_count = 0

    def _reset(self):
        self.current_frame_num = None
        self.current_meta = None
        self.samples = []
        self.real = []
        self.imag = []

    def feed_line(self, line):
        if line.startswith("# FRAME"):
            meta = parse_frame_header(line)
            self._reset()
            if meta is not None:
                self.current_frame_num = meta["FRAME"]
                self.current_meta = meta
            return None

        if line.startswith("# END"):
            completed = None
            if self.current_frame_num is not None and self.samples:
                completed = {
                    "meta": self.current_meta,
                    "samples": np.array(self.samples, dtype=float),
                    "real": np.array(self.real, dtype=float),
                    "imag": np.array(self.imag, dtype=float),
                }
            self._reset()
            return completed

        if line.startswith("#") or line.startswith("sample,"):
            return None

        if self.current_frame_num is None:
            return None

        fields = line.split(",")
        if len(fields) != 5:
            self.rejected_count += 1
            return None
        try:
            vals = [float(f) for f in fields]
        except ValueError:
            self.rejected_count += 1
            return None
        if any(np.isnan(v) for v in vals):
            self.rejected_count += 1
            return None

        # A dropped byte at 921600 baud can splice two rows together and
        # still parse as five numbers, so check the absolute sample index
        # falls inside the window the firmware actually captured.
        sample = vals[0]
        start = self.current_meta["START"]
        if sample < start or sample > start + 1024 or sample != int(sample):
            self.rejected_count += 1
            return None

        self.samples.append(sample)
        self.real.append(vals[1])
        self.imag.append(vals[2])
        return None


def resample_frame(samples, real, imag, meta, grid):
    rxpacc = meta.get("RXPACC", 0.0)
    if not rxpacc:
        return None

    taps_from_fp = samples - meta["FP_INDEX"]
    real_norm = real / rxpacc
    imag_norm = imag / rxpacc

    u_taps, idx = np.unique(taps_from_fp, return_index=True)
    if u_taps.size < 2:
        return None

    # np.interp clamps to the boundary value outside its input range by
    # default; left/right=nan reproduces MATLAB's interp1(...,'linear',NaN)
    # so gaps show up as gaps instead of fabricated flat data.
    real_col = np.interp(grid, u_taps, real_norm[idx], left=np.nan, right=np.nan)
    imag_col = np.interp(grid, u_taps, imag_norm[idx], left=np.nan, right=np.nan)
    return real_col, imag_col


def open_serial(port, baud, settle_s=2.0):
    """Open the anchor's serial port and let the board finish booting.

    Opening a port asserts DTR/RTS by default on Windows, and on most ESP32
    boards those lines drive the auto-reset circuit (EN/GPIO0) - left
    asserted, the chip stays held in reset and never prints anything.
    Release them and wait before trusting incoming bytes.
    """
    ser = serial.Serial(port, baud, timeout=0.5)
    ser.dtr = False
    ser.rts = False
    time.sleep(settle_s)
    ser.reset_input_buffer()
    return ser


class SerialReaderThread(threading.Thread):
    """Reads and parses serial frames independently of the GUI redraw loop.

    Serial reads are blocking and GUI redraws are not instantaneous; if both
    ran on one thread, a slow redraw could stall reads long enough to
    overflow the OS serial buffer at 921600 baud and lose bytes.
    """

    def __init__(self, ser, grid, out_queue, stop_event, debug=False):
        super().__init__(daemon=True)
        self.ser = ser
        self.grid = grid
        self.out_queue = out_queue
        self.stop_event = stop_event
        self.debug = debug
        self.assembler = FrameAssembler()
        self.raw_lines_seen = 0
        self.frames_seen = 0
        self.frames_kept = 0
        self.resample_failed = 0
        self.last_frame_time = None
        self.frame_times = deque(maxlen=20)  # for a windowed fps estimate
        self.error = None

        # Frame-dropout detection via the tag's payload sequence number
        # (TAG_SEQ - see the commented-out block in src/NLOS_anchor.cpp).
        # frames_seen/frames_kept only count what arrived; they are gap-free
        # by construction and can't show what the tag sent that the anchor's
        # radio never received at all. A gap in TAG_SEQ can. Silently stays
        # at 0/False if the firmware isn't printing that field yet.
        self.last_tag_seq = None
        self.dropped_frames = 0
        self.header_anomalies = 0
        self.tag_seq_available = False

    def run(self):
        while not self.stop_event.is_set():
            try:
                raw = self.ser.readline()
            except serial.SerialException as exc:
                self.error = exc
                self.stop_event.set()
                break

            if not raw:
                continue  # read timeout, no data yet

            line = raw.decode("ascii", errors="replace").strip()
            if not line:
                continue

            self.raw_lines_seen += 1
            if self.debug:
                print(f"RAW: {line}")

            completed = self.assembler.feed_line(line)
            if completed is None:
                continue

            self.frames_seen += 1

            meta = completed["meta"]
            if "TAG_SEQ" in meta:
                self.tag_seq_available = True
                seq = int(meta["TAG_SEQ"])
                if self.last_tag_seq is not None:
                    if seq > self.last_tag_seq:
                        gap = seq - self.last_tag_seq - 1
                        if gap > 0:
                            self.dropped_frames += gap
                            if self.debug:
                                print(f"DEBUG: {gap} frame(s) dropped before TAG_SEQ={seq}")
                    elif self.last_tag_seq > 0xFFFFFFF0 and seq < 16:
                        # Genuine uint32 wraparound: only trust this when the
                        # previous value was actually near the top of the
                        # range - otherwise seq <= last_tag_seq almost always
                        # means a corrupted or duplicated header line (the
                        # header has no sample-index-style sanity check),
                        # and guessing a wrap would fabricate a huge bogus
                        # count instead of just flagging the anomaly.
                        gap = (seq + (2**32 - self.last_tag_seq)) - 1
                        if gap > 0:
                            self.dropped_frames += gap
                            if self.debug:
                                print(f"DEBUG: {gap} frame(s) dropped across wraparound, TAG_SEQ={seq}")
                    else:
                        self.header_anomalies += 1
                        if self.debug:
                            print(f"DEBUG: TAG_SEQ went backwards/repeated "
                                  f"({self.last_tag_seq} -> {seq}) - likely a corrupted "
                                  f"or duplicated header, not counted as a drop")
                self.last_tag_seq = seq

            result = resample_frame(
                completed["samples"], completed["real"], completed["imag"],
                completed["meta"], self.grid,
            )
            if result is None:
                self.resample_failed += 1
                if self.debug:
                    print(f"DEBUG: resample failed for frame meta={completed['meta']}")
                continue

            self.frames_kept += 1
            self.last_frame_time = time.monotonic()
            self.frame_times.append(self.last_frame_time)
            self.out_queue.put((completed["meta"], result[0], result[1]))
