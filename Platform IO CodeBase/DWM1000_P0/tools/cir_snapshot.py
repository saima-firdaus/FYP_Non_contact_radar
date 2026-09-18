"""On-demand CIR amplitude snapshot, aligned to the first path.

Unlike cir_live_mti.py's continuously-scrolling waterfall, this plots a
single line (mean amplitude vs excess path length, +/-1 SD band) - the same
alignment and non-coherent magnitude averaging as panel 2 of the batch
MATLAB script (include/cir_cap3.m), but redrawn on demand instead of once
after a fixed capture window.

The anchor is always streaming frames in the background into a rolling
window of the last --frames arrivals. Press Enter in this terminal to plot
whatever is currently in that window; type 'q' + Enter to quit. Re-running a
snapshot after changing a setting (AGC, TX power, antenna position, ...)
lets you compare the shape/noise floor directly instead of re-running MATLAB.

Frame count is a real tradeoff, not just a default to leave alone:
averaging N frames reduces random noise in the mean amplitude by roughly
sqrt(N), but also blends together whatever RXPWR/AGC gain-state drift
happened across those N frames (see cir_live_mti.py's docstring - the
DW1000's AGC has no documented freeze/disable control) and makes each
snapshot staler. At ~10 fps (the default tag TX rate after the
DW1000Ranging fix in src/setup_tag.cpp), the default of 15 frames is
about 1.5s - few enough that AGC drift within one snapshot is rarely
visible, but enough to smooth out per-frame jitter. Lower --frames for
faster feedback while sweeping a setting; raise it once you've settled on
a value and want a cleaner noise-floor estimate.

Usage:
    pip install -r tools/requirements.txt
    python tools/cir_snapshot.py --port COM4 --frames 15
"""

import argparse
import queue
import signal
import sys
import threading
from collections import deque

import numpy as np
import matplotlib.pyplot as plt

from dw1000_cir import TAP_TO_METRES, build_grid, open_serial, SerialReaderThread


def draw_snapshot(ax, fig, window, excess, n_frames_target):
    ax.clear()
    frames = list(window)

    if not frames:
        ax.set_title("No frames captured yet - waiting...")
        ax.set_xlabel("Excess path length relative to first path (m)")
        ax.set_ylabel("Amplitude / RXPACC")
        fig.canvas.draw_idle()
        return

    # Non-coherent (magnitude) averaging: the carrier phase of each path
    # rotates frame to frame, so averaging I/Q would cancel real energy -
    # average the per-frame magnitudes instead (matches include/cir_cap3.m).
    mags = np.stack([np.hypot(real_col, imag_col) for _, real_col, imag_col in frames])
    mean_amp = np.nanmean(mags, axis=0)
    std_amp = np.nanstd(mags, axis=0)
    valid = ~np.isnan(mean_amp)

    if np.any(valid):
        lower = np.clip(mean_amp[valid] - std_amp[valid], 0, None)
        upper = mean_amp[valid] + std_amp[valid]
        ax.fill_between(excess[valid], lower, upper, color=(0.2, 0.4, 0.8), alpha=0.18,
                         label="±1 SD")
        ax.plot(excess[valid], mean_amp[valid], "b-", linewidth=1.6,
                 label=f"Mean of {len(frames)} frames")

    ax.axvline(0, color="k", linestyle="--", linewidth=1, label="first path")
    ax.set_xlabel("Excess path length relative to first path (m)")
    ax.set_ylabel("Amplitude / RXPACC")
    ax.legend(loc="upper right")
    ax.grid(True, alpha=0.3)

    rxpwrs = [meta["RXPWR"] for meta, _, _ in frames]
    rxpaccs = [meta["RXPACC"] for meta, _, _ in frames]
    staleness = "" if len(frames) >= n_frames_target else f" (window still filling, wanted {n_frames_target})"
    ax.set_title(
        f"CIR amplitude aligned to first path - {len(frames)} frames{staleness}\n"
        f"RXPWR {min(rxpwrs):.1f} to {max(rxpwrs):.1f} dBm   "
        f"RXPACC {min(rxpaccs):.0f} to {max(rxpaccs):.0f}"
    )
    fig.canvas.draw_idle()

    print(
        f"Snapshot: {len(frames)} frames   RXPWR {min(rxpwrs):.1f} to {max(rxpwrs):.1f} dBm   "
        f"RXPACC {min(rxpaccs):.0f} to {max(rxpaccs):.0f}"
    )


def input_worker(cmd_queue, stop_event):
    while not stop_event.is_set():
        try:
            line = input()
        except EOFError:
            cmd_queue.put("quit")
            return
        if line.strip().lower() in ("q", "quit"):
            cmd_queue.put("quit")
            return
        cmd_queue.put("snapshot")


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--port", default="COM4",
                         help="Anchor serial port (default: COM4, matches platformio.ini's uwb_anchor env)")
    parser.add_argument("--baud", type=int, default=921600)
    parser.add_argument("--frames", type=int, default=15,
                         help="Frames averaged per snapshot - see the module docstring for the "
                              "noise-vs-staleness tradeoff (default: 15, ~1.5s at 10fps)")
    parser.add_argument("--taps-before", type=float, default=48.0,
                         help="Taps before the first path to resample onto (firmware captures CIR_BEFORE_FP=50)")
    parser.add_argument("--taps-after", type=float, default=98.0,
                         help="Taps after the first path to resample onto (firmware captures CIR_AFTER_FP=100)")
    parser.add_argument("--grid-step", type=float, default=0.5, help="Resampling grid step, in taps")
    parser.add_argument("--debug", action="store_true",
                         help="Print every raw serial line and resample failures to the console")
    args = parser.parse_args(argv)

    grid = build_grid(args.taps_before, args.taps_after, args.grid_step)
    excess = grid * TAP_TO_METRES

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

    window = deque(maxlen=args.frames)

    plt.ion()
    fig, ax = plt.subplots(figsize=(9, 5))
    fig.show()

    def on_close(_event):
        stop_event.set()

    fig.canvas.mpl_connect("close_event", on_close)

    def handle_sigint(_signum, _frame):
        stop_event.set()

    signal.signal(signal.SIGINT, handle_sigint)

    cmd_queue = queue.Queue()
    threading.Thread(target=input_worker, args=(cmd_queue, stop_event), daemon=True).start()

    print(
        f"Listening on {args.port}. Press Enter for a snapshot averaged over the last "
        f"{args.frames} frames, or 'q' + Enter to quit."
    )

    try:
        while not stop_event.is_set():
            while True:
                try:
                    meta, real_col, imag_col = out_queue.get_nowait()
                except queue.Empty:
                    break
                window.append((meta, real_col, imag_col))

            try:
                cmd = cmd_queue.get_nowait()
            except queue.Empty:
                cmd = None

            if cmd == "quit":
                break
            if cmd == "snapshot":
                draw_snapshot(ax, fig, window, excess, args.frames)

            plt.pause(0.05)  # keeps the GUI event loop alive between commands
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
            f"Stopped. frame headers seen={reader.frames_seen} kept={reader.frames_kept} "
            f"resample failed={reader.resample_failed} "
            f"rejected data lines={reader.assembler.rejected_count}{dropped_summary}"
        )


if __name__ == "__main__":
    main()
