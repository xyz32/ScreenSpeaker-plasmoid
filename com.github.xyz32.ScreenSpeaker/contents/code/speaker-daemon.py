#!/usr/bin/env python3
"""Speaker plasmoid audio daemon.

Captures STEREO audio from a PulseAudio/PipeWire sink monitor via `pw-record`
(marked as a sink-monitor capture so KDE shows no microphone indicator),
computes an FFT per channel, condenses into 3 logarithmic bands (bass, mid, treble)
plus a dedicated ultra-low band (20-80 Hz), and serves the latest snapshot over
localhost HTTP for the QML widget to poll.

Output format: the original 12 values followed by four ultra-low values:
  'Le_bass Le_mid Le_treble Re_bass Re_mid Re_treble
   La_bass La_mid La_treble Ra_bass Ra_mid Ra_treble
   Le_ultra Re_ultra La_ultra Ra_ultra'
energy drives vibration amplitude; activity (fraction of active bins) drives
vibration rate.

The ephemeral port is written to `<output>.port`.
Exits when heartbeat file (`<output>.alive`) is older than 30s.
"""

import argparse
import fcntl
import http.server
import os
import signal
import subprocess
import sys
import threading
import time

import numpy as np

_state_lock = threading.Lock()
_state = {"payload": ""}

# Held for the process lifetime so the flock is not released. Must outlive
# acquire_singleton_lock(); if it were closed the kernel would drop the lock.
_lock_fd = None


class _Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def do_GET(self):
        with _state_lock:
            body = _state["payload"].encode("ascii")
        self.send_response(200)
        self.send_header("Content-Type", "text/plain")
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *_a, **_kw):
        pass


def start_http_server(output_path):
    httpd = http.server.ThreadingHTTPServer(("127.0.0.1", 0), _Handler)
    port = httpd.server_address[1]
    port_path = output_path + ".port"
    tmp = port_path + ".tmp"
    with open(tmp, "w") as f:
        f.write(str(port))
    os.replace(tmp, port_path)
    threading.Thread(target=httpd.serve_forever, daemon=True).start()
    return httpd, port, port_path


def parse_args():
    p = argparse.ArgumentParser()
    p.add_argument("--device", required=True, help="pulse/pipewire monitor source")
    p.add_argument("--rate", type=int, default=44100)
    p.add_argument("--chunk", type=int, default=512)
    p.add_argument("--fft-size", type=int, default=4096)
    p.add_argument("--smoothing", type=float, default=0.7)
    p.add_argument("--sensitivity", type=float, default=1.2)
    p.add_argument("--output", required=True)
    p.add_argument("--daemonize", action="store_true")
    p.add_argument("--log", default=None)
    return p.parse_args()


def daemonize(log_path):
    if os.fork() > 0:
        os._exit(0)
    os.setsid()
    if os.fork() > 0:
        os._exit(0)
    os.chdir("/")
    os.umask(0o077)
    sys.stdout.flush()
    sys.stderr.flush()
    devnull = os.open(os.devnull, os.O_RDONLY)
    os.dup2(devnull, 0)
    os.close(devnull)
    if log_path:
        log_fd = os.open(log_path, os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o644)
    else:
        log_fd = os.open(os.devnull, os.O_WRONLY)
    os.dup2(log_fd, 1)
    os.dup2(log_fd, 2)
    os.close(log_fd)


def acquire_singleton_lock(output_path):
    """Ensure only ONE daemon serves a given output path.

    A second launch for the same output is a harmless no-op: the first daemon
    already serves the data for all plasmoid instances, so we simply exit(0).

    MUST be called AFTER daemonize() so the FINAL grandchild holds the lock;
    acquiring it before the double-fork would lose it when the intermediate
    parents _exit. The fd is stashed in the module global _lock_fd so it stays
    open (and the flock held) for the process lifetime.
    """
    global _lock_fd
    lock_path = output_path + ".lock"
    fd = os.open(lock_path, os.O_RDWR | os.O_CREAT, 0o644)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        os.close(fd)
        print("[speaker-daemon] another daemon already serves "
              f"{output_path}; exiting", flush=True)
        sys.exit(0)
    _lock_fd = fd
    return lock_path


def build_band_indices(freqs, fmin=30.0, fmax=16000.0):
    """3 logarithmic bands: bass (30-250Hz), mid (250-2kHz), treble (2k-16kHz)."""
    band_edges = [fmin, 250.0, 2000.0, fmax]
    out = []
    for i in range(3):
        lo = int(np.searchsorted(freqs, band_edges[i], side="left"))
        hi = int(np.searchsorted(freqs, band_edges[i + 1], side="left"))
        if hi <= lo:
            hi = lo + 1
        out.append((lo, min(hi, len(freqs))))
    return out


def build_ultra_low_indices(freqs, fmin=20.0, fmax=80.0):
    """Dedicated subwoofer band covering only 20-80 Hz."""
    lo = int(np.searchsorted(freqs, fmin, side="left"))
    hi = int(np.searchsorted(freqs, fmax, side="left"))
    if hi <= lo:
        hi = lo + 1
    return lo, min(hi, len(freqs))


def main():
    args = parse_args()
    if args.daemonize:
        daemonize(args.log)

    # Singleton guard: acquired AFTER the double-fork so the final grandchild
    # holds it. A second launch for the same output exits(0) harmlessly here.
    lock_path = acquire_singleton_lock(args.output)

    print(f"[speaker-daemon] starting pid={os.getpid()} device={args.device}", flush=True)

    chunk = max(256, 1 << (args.chunk - 1).bit_length())
    fft_size = max(chunk, 1 << (args.fft_size - 1).bit_length())
    # Stereo interleaved float32: L R L R ... -> chunk frames * 2 channels * 4 bytes
    bytes_per_frame = chunk * 2 * 4

    # Capture the sink's monitor with pw-record (PipeWire-native). Using
    # `stream.capture.sink=true` links to the playback sink's monitor rather
    # than a hardware mic. NOTE: KDE still shows a recording (microphone)
    # indicator in the system tray while this runs — that is expected. There
    # is no client-side property that both keeps the PCM flowing AND hides the
    # node from Plasma's indicator (every real capture registers as
    # Stream/Input/Audio, which the indicator is designed to show). The
    # node.name / node.description below at least label it clearly as this app
    # in the tray's recording list. Output is raw interleaved float32 stereo,
    # which the deinterleave/FFT logic below consumes directly.
    cmd = [
        "stdbuf", "-o0",
        "pw-record",
        "--target", args.device,
        "-P", ("{ stream.capture.sink=true"
               " node.name=speaker-visualizer"
               " node.description=\"Speaker Visualizer\" }"),
        "--rate", str(args.rate),
        "--channels", "2",
        "--format", "f32",
        "--raw",
        "-",
    ]

    _httpd, http_port, port_path = start_http_server(args.output)
    print(f"[speaker-daemon] http on 127.0.0.1:{http_port}", flush=True)

    proc_holder = {"proc": None}

    def cleanup(*_):
        p = proc_holder["proc"]
        if p:
            try:
                p.terminate()
            except Exception:
                pass
        for path in (args.output, port_path, lock_path):
            try:
                os.unlink(path)
            except OSError:
                pass
        sys.exit(0)

    signal.signal(signal.SIGTERM, cleanup)
    signal.signal(signal.SIGINT, cleanup)

    window = np.hanning(fft_size).astype(np.float32)
    freqs = np.fft.rfftfreq(fft_size, 1.0 / args.rate)
    bands = build_band_indices(freqs)
    ultra_low = build_ultra_low_indices(freqs)

    # Per-channel sliding-window ring buffers and smoothing state. The fourth
    # smoothing slot belongs to the independent 20-80 Hz subwoofer band.
    ring_l = np.zeros(fft_size, dtype=np.float32)
    ring_r = np.zeros(fft_size, dtype=np.float32)
    smooth_l = np.zeros(4, dtype=np.float32)
    smooth_r = np.zeros(4, dtype=np.float32)

    decay = float(np.clip(args.smoothing, 0.0, 0.98))
    sens = float(max(0.05, args.sensitivity))

    # Activity noise floor: a bin counts as "active" when its magnitude in dB
    # sits above this. Used to measure how BUSY a band is (how many frequencies
    # are sounding), independent of raw energy.
    activity_floor_db = -55.0

    def process_channel(ring, smooth):
        """FFT -> per band: (energy 0..1, activity 0..1).

        energy   = peak magnitude in the band, dB-normalized + smoothed
                   (rise fast, fall slow) -> drives vibration AMPLITUDE.
        activity = fraction of bins in the band above the noise floor -> how
                   many frequencies are sounding -> drives vibration RATE.
        """
        windowed = ring * window
        spec = np.abs(np.fft.rfft(windowed)) / fft_size
        spec_db = 20.0 * np.log10(spec + 1e-9)

        peaks = np.fromiter((spec[lo:hi].max() for lo, hi in bands),
                            dtype=np.float32, count=3)
        db = 20.0 * np.log10(peaks + 1e-9)
        norm = np.clip((db + 60.0) / 60.0, 0.0, 1.0) * sens
        norm = np.clip(norm, 0.0, 1.0)
        # rise fast, fall slowly
        smooth[:3] = np.maximum(norm, smooth[:3] * decay)

        activity = np.fromiter(
            (float(np.mean(spec_db[lo:hi] > activity_floor_db)) for lo, hi in bands),
            dtype=np.float32, count=3,
        )

        ulo, uhi = ultra_low
        ultra_peak = spec[ulo:uhi].max()
        ultra_db = 20.0 * np.log10(ultra_peak + 1e-9)
        ultra_norm = float(np.clip((ultra_db + 60.0) / 60.0, 0.0, 1.0) * sens)
        ultra_norm = float(np.clip(ultra_norm, 0.0, 1.0))
        smooth[3] = max(ultra_norm, smooth[3] * decay)
        ultra_activity = float(np.mean(spec_db[ulo:uhi] > activity_floor_db))
        return smooth[:3], activity, smooth[3], ultra_activity

    alive_path = args.output + ".alive"
    try:
        open(alive_path, "a").close()
        os.utime(alive_path, None)
    except OSError:
        pass

    def heartbeat_alive():
        try:
            return time.time() - os.path.getmtime(alive_path) <= 30
        except OSError:
            return False

    while True:
        try:
            proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
            proc_holder["proc"] = proc
        except Exception as e:
            print(f"[speaker-daemon] failed to spawn pw-record: {e}", flush=True)
            time.sleep(1.0)
            if not heartbeat_alive():
                cleanup()
            continue

        last_alive_check = time.monotonic()

        while True:
            raw = proc.stdout.read(bytes_per_frame)
            if not raw or len(raw) < bytes_per_frame:
                break

            interleaved = np.frombuffer(raw, dtype=np.float32)
            if interleaved.size != chunk * 2:
                continue
            # Deinterleave: even indices = left, odd = right
            left = interleaved[0::2]
            right = interleaved[1::2]

            ring_l[:-chunk] = ring_l[chunk:]
            ring_l[-chunk:] = left
            ring_r[:-chunk] = ring_r[chunk:]
            ring_r[-chunk:] = right

            sl, al, ul, aul = process_channel(ring_l, smooth_l)
            sr, ar, ur, aur = process_channel(ring_r, smooth_r)

            # Preserve the original 12-value prefix and append ultra-low stereo
            # energy/activity for Subwoofer mode.
            line = (f"{sl[0]:.3f} {sl[1]:.3f} {sl[2]:.3f} "
                    f"{sr[0]:.3f} {sr[1]:.3f} {sr[2]:.3f} "
                    f"{al[0]:.3f} {al[1]:.3f} {al[2]:.3f} "
                    f"{ar[0]:.3f} {ar[1]:.3f} {ar[2]:.3f} "
                    f"{ul:.3f} {ur:.3f} {aul:.3f} {aur:.3f}")
            with _state_lock:
                _state["payload"] = line

            now = time.monotonic()
            if now - last_alive_check > 2.0:
                last_alive_check = now
                if not heartbeat_alive():
                    cleanup()

        print("[speaker-daemon] pw-record ended; respawning", flush=True)
        try:
            proc.terminate()
            proc.wait(timeout=1.0)
        except Exception:
            pass
        proc_holder["proc"] = None
        smooth_l[:] = 0
        smooth_r[:] = 0
        ring_l[:] = 0
        ring_r[:] = 0
        with _state_lock:
            _state["payload"] = ""
        time.sleep(1.0)
        if not heartbeat_alive():
            cleanup()


if __name__ == "__main__":
    main()
