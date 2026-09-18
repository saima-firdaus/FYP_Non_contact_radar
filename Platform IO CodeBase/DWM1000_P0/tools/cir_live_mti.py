"""Live adjacent-frame coherent MTI viewer for the DW1000 CIR anchor stream.

Each completed frame is resampled onto a common tap-offset-from-first-path
grid (RXPACC-normalized I/Q), then subtracted from the previous frame to get
a coherent moving-target-indication (MTI) residual: a static reflector
cancels between two adjacent frames sharing this session's phase reference,
a moving target does not. Residuals are shown as a scrolling waterfall so
you can watch clutter cancellation live, instead of re-running the batch
MATLAB capture (include/cir_cap3.m) after every change.

The DW1000's receive AGC has no documented disable/freeze control (its
AGC_CTRL1:DIS_AM bit only gates an unrelated one-shot noise-scan feature),
so its gain state can still drift slightly frame to frame even for a static
scene. RXPWR is the only per-frame proxy for that drift, so a transition
where RXPWR jumps by more than --rxpwr-threshold dB is treated as a likely
gain-state shift rather than real motion and rendered as a gap.

The uwb_anchor PlatformIO environment (platformio.ini) is COM4 at 921600
baud; uwb_tag is a separate COM3 stream with unrelated output and is not
what this script expects to read.

The waterfall's y-axis is physical distance, not raw taps: tap offset from
the first path is converted to "reflector offset from the tag-anchor
midline" via the same ellipse-geometry formula include/cir_cap3.m uses,
given the straight-line tag-anchor separation (--tag-anchor-dist, measure
this for your setup).

See also cir_snapshot.py for a non-scrolling, on-demand aligned-amplitude
view (press Enter for a fresh averaged snapshot instead of a live waterfall).

Usage:
    pip install -r tools/requirements.txt
    python tools/cir_live_mti.py --port COM4 --tag-anchor-dist 0.7
"""

import argparse
import queue
import signal
import sys
import threading
import time
from collections import deque

import numpy as np
import matplotlib.pyplot as plt
from matplotlib.animation import FuncAnimation

from dw1000_cir import build_grid, build_distance_axis, open_serial, SerialReaderThread


class MTIWaterfall:
    """Rolling buffer of adjacent-frame coherent MTI amplitude columns.

    The DW1000's receive AGC has no documented disable/freeze control (only
    an unrelated one-shot noise-scan bit lives in AGC_CTRL1) - its gain state
    can still shift slightly frame to frame even for a static scene, which
    shows up as spurious amplitude jumps that coherent subtraction can't
    tell apart from a real moving target. RXPWR is the only per-frame signal
    available to catch this indirectly: a transition where RXPWR jumps more
    than rxpwr_threshold dB is flagged as an unreliable gain-state change
    rather than motion, and rendered as a gap instead of a false detection.
    """

    def __init__(self, history_len, rxpwr_threshold, b_valid, valid_mask, b_display):
        self.buffer = deque(maxlen=history_len)
        self.prev_z = None
        self.prev_meta = None
        self.transition_counter = 0
        self.rejected_transitions = 0
        self.rxpwr_threshold = rxpwr_threshold
        # Ellipse-geometry conversion (build_distance_axis): mti values live
        # on the uniform tap grid, but are resampled onto b_display (uniform
        # in physical distance) before storage, so the waterfall's rows are
        # evenly spaced in metres rather than in taps.
        self.b_valid = b_valid
        self.valid_mask = valid_mask
        self.b_display = b_display

    def push_frame(self, meta, real_col, imag_col):
        z = real_col + 1j * imag_col
        if self.prev_z is not None:
            rxpwr_delta = abs(meta["RXPWR"] - self.prev_meta["RXPWR"])
            if rxpwr_delta > self.rxpwr_threshold:
                col = np.full(self.b_display.size, np.nan)
                self.rejected_transitions += 1
            else:
                mti_taps = np.abs(z - self.prev_z)
                col = np.interp(
                    self.b_display, self.b_valid, mti_taps[self.valid_mask],
                    left=np.nan, right=np.nan,
                )
            self.buffer.append(col)
            self.transition_counter += 1
        self.prev_z = z
        self.prev_meta = meta

    def as_matrix(self):
        return np.column_stack(self.buffer)


def make_figure(b_display, history_len, tag_anchor_dist):
    fig, ax = plt.subplots(figsize=(9, 6))
    init = np.full((len(b_display), max(history_len, 1)), np.nan)
    im = ax.imshow(
        init, origin="lower", aspect="auto", cmap="viridis",
        extent=[0, history_len, b_display[0], b_display[-1]],
    )
    ax.axhline(0, color="white", linestyle="--", linewidth=1)
    ax.set_xlabel("Frame transition # (scrolling)")
    ax.set_ylabel("Reflector offset from tag-anchor midline (m)")
    ax.set_title(f"Live adjacent-frame coherent MTI  (D = {tag_anchor_dist:.2f} m)")
    fig.colorbar(im, ax=ax, label="MTI amplitude |ΔZ| (RXPACC-normalized)")
    diag_text = ax.text(
        0.01, 0.99, "Waiting for frames...", transform=ax.transAxes,
        va="top", ha="left", color="white", fontsize=9,
        bbox=dict(facecolor="black", alpha=0.5, pad=3),
    )
    return fig, ax, im, diag_text


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--port", default="COM4",
                         help="Anchor serial port (default: COM4, matches platformio.ini's uwb_anchor env)")
    parser.add_argument("--baud", type=int, default=921600)
    parser.add_argument("--history", type=int, default=300,
                         help="Frame transitions kept in the scrolling waterfall")
    parser.add_argument("--taps-before", type=float, default=48.0,
                         help="Taps before the first path to resample onto (firmware captures CIR_BEFORE_FP=50)")
    parser.add_argument("--taps-after", type=float, default=98.0,
                         help="Taps after the first path to resample onto (firmware captures CIR_AFTER_FP=100)")
    parser.add_argument("--grid-step", type=float, default=0.5, help="Resampling grid step, in taps")
    parser.add_argument("--interval-ms", type=int, default=75, help="Plot redraw interval in milliseconds")
    parser.add_argument("--rxpwr-threshold", type=float, default=2.0,
                         help="Reject an MTI transition when RXPWR differs by more than this many dB "
                              "between the two frames (likely an AGC gain-state shift, not real motion)")
    parser.add_argument("--tag-anchor-dist", type=float, default=0.7,
                         help="Straight-line distance between tag and anchor, in metres. "
                              "MEASURE THIS for your setup - it's the baseline for the ellipse-geometry "
                              "conversion from tap offset to reflector distance (default: 0.7m)")
    parser.add_argument("--debug", action="store_true",
                         help="Print every raw serial line and resample failures to the console")
    args = parser.parse_args(argv)

    grid = build_grid(args.taps_before, args.taps_after, args.grid_step)
    b_valid, valid_mask, b_display = build_distance_axis(grid, args.tag_anchor_dist)
    if b_display.size < 2:
        print("Taps-after-fp/grid-step leave no valid distance points - widen --taps-after.", file=sys.stderr)
        sys.exit(1)

    try:
        ser = open_serial(args.port, args.baud)
    except Exception as exc:
        print(
            f"Could not open {args.port}: {exc}\n"
            "Is the anchor connected, and not already open in the Arduino/PlatformIO "
            "Serial Monitor or MATLAB?",
            file=sys.stderr,
        )
        sys.exit(1)

    out_queue = queue.Queue()
    stop_event = threading.Event()
    reader = SerialReaderThread(ser, grid, out_queue, stop_event, debug=args.debug)
    reader.start()

    waterfall = MTIWaterfall(args.history, args.rxpwr_threshold, b_valid, valid_mask, b_display)
    fig, ax, im, diag_text = make_figure(b_display, args.history, args.tag_anchor_dist)

    state = {
        "last_vmax_update": 0.0,
        "last_console_print": 0.0,
        "start_time": time.monotonic(),
        "last_meta": None,
    }

    def update(_frame):
        drained = 0
        while True:
            try:
                meta, real_col, imag_col = out_queue.get_nowait()
            except queue.Empty:
                break
            waterfall.push_frame(meta, real_col, imag_col)
            state["last_meta"] = meta
            drained += 1

        now = time.monotonic()

        if drained and waterfall.buffer:
            matrix = waterfall.as_matrix()
            n_cols = matrix.shape[1]
            im.set_data(matrix)
            im.set_extent([
                waterfall.transition_counter - n_cols, waterfall.transition_counter,
                b_display[0], b_display[-1],
            ])

            if now - state["last_vmax_update"] > 1.0:
                finite = matrix[np.isfinite(matrix)]
                if finite.size:
                    vmax = float(np.nanpercentile(finite, 95))
                    if vmax > 0:
                        im.set_clim(0, vmax)
                state["last_vmax_update"] = now

        meta = state["last_meta"]
        if meta is not None:
            # Windowed rate over the last few arrivals, not an average since
            # start - frames can arrive in irregular bursts, so a since-start
            # average keeps decaying between arrivals instead of reflecting
            # the current rate.
            times = reader.frame_times
            if len(times) >= 2:
                span = times[-1] - times[0]
                fps = (len(times) - 1) / span if span > 0 else 0.0
            else:
                fps = 0.0
            dropped_str = (
                f"   dropped (RF): {reader.dropped_frames}  header anomalies: {reader.header_anomalies}"
                if reader.tag_seq_available
                else "   dropped (RF): n/a (uncomment TAG_SEQ in NLOS_anchor.cpp)"
            )
            text = (
                f"RXPWR: {meta['RXPWR']:.1f} dBm   RXPACC: {int(meta['RXPACC'])}   "
                f"FP_INDEX: {meta['FP_INDEX']:.2f}\n"
                f"frames: {reader.frames_kept} kept / {reader.frames_seen} seen "
                f"({fps:.1f} fps)   rejected lines: {reader.assembler.rejected_count}   "
                f"queue backlog: {out_queue.qsize()}{dropped_str}\n"
                f"gain-shift rejected: {waterfall.rejected_transitions} / "
                f"{waterfall.transition_counter} transitions "
                f"(>{args.rxpwr_threshold:.1f} dB RXPWR jump)"
            )
        else:
            text = (
                f"Waiting for frames...  raw lines: {reader.raw_lines_seen}   "
                f"frame headers seen: {reader.frames_seen}   "
                f"resample failed: {reader.resample_failed}   "
                f"rejected data lines: {reader.assembler.rejected_count}"
            )
        diag_text.set_text(text)

        if now - state["last_console_print"] > 1.0:
            print(text.replace("\n", "  |  "))
            state["last_console_print"] = now

        return [im, diag_text]

    def on_close(_event):
        stop_event.set()

    fig.canvas.mpl_connect("close_event", on_close)

    # Ctrl+C raises KeyboardInterrupt on the main thread, but Tkinter's
    # mainloop only lets Python service pending signals between its own
    # internal callbacks - it can sit for a long time before noticing.
    # Force the window closed directly instead of waiting for that.
    def handle_sigint(_signum, _frame):
        stop_event.set()
        plt.close("all")

    signal.signal(signal.SIGINT, handle_sigint)

    ani = FuncAnimation(fig, update, interval=args.interval_ms, cache_frame_data=False)

    try:
        plt.show()
    except KeyboardInterrupt:
        pass
    finally:
        stop_event.set()
        reader.join(timeout=2.0)
        try:
            ser.close()
        except Exception:
            pass
        dropped_summary = (
            f" dropped(RF)={reader.dropped_frames} header_anomalies={reader.header_anomalies}"
            if reader.tag_seq_available else ""
        )
        print(
            f"Stopped. raw lines={reader.raw_lines_seen} frame headers seen={reader.frames_seen} "
            f"kept={reader.frames_kept} resample failed={reader.resample_failed} "
            f"rejected data lines={reader.assembler.rejected_count}{dropped_summary}"
        )


if __name__ == "__main__":
    main()
