"""Serial console logger for the Kobra S1 host board (RV1106 debug UART on J1).

Usage:
  .venv\\Scripts\\python.exe tools\\uart_log.py --list
  .venv\\Scripts\\python.exe tools\\uart_log.py COM5                 # 1500000 baud, log to logs/
  .venv\\Scripts\\python.exe tools\\uart_log.py COM5 --autobaud      # guess baud from incoming data
  .venv\\Scripts\\python.exe tools\\uart_log.py COM5 --interactive   # also send typed lines to the board

Every received byte is written raw to logs/uart_<timestamp>.log and echoed to stdout.
In --interactive mode a line typed on stdin is sent followed by '\\n'; type '^C' alone
on a line to send Ctrl+C (e.g. to stop U-Boot autoboot).
"""
import argparse
import datetime
import pathlib
import sys
import threading
import time

import serial
import serial.tools.list_ports

CANDIDATE_BAUDS = [1500000, 115200, 921600, 1000000, 2000000, 460800, 230400, 57600]
LOG_DIR = pathlib.Path(__file__).resolve().parent.parent / "logs"


def list_ports():
    for p in serial.tools.list_ports.comports():
        print(f"{p.device:8} {p.description}  [{p.hwid}]")


def printable_ratio(data: bytes) -> float:
    if not data:
        return 0.0
    ok = sum(1 for b in data if b in (9, 10, 13) or 32 <= b < 127)
    return ok / len(data)


def autobaud(port: str, window: float) -> int:
    print(f"Autobaud: power-cycle or reset the board now, sampling {window}s per rate...")
    best = (0.0, 0, CANDIDATE_BAUDS[0])
    for baud in CANDIDATE_BAUDS:
        with serial.Serial(port, baud, timeout=0.1) as s:
            s.reset_input_buffer()
            end = time.time() + window
            buf = b""
            while time.time() < end:
                buf += s.read(4096)
        ratio = printable_ratio(buf)
        print(f"  {baud:>8}: {len(buf):6} bytes, printable {ratio:.0%}")
        if len(buf) >= 32 and (ratio, len(buf)) > best[:2]:
            best = (ratio, len(buf), baud)
    print(f"Picked {best[2]} baud")
    return best[2]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("port", nargs="?")
    ap.add_argument("--baud", type=int, default=1500000)
    ap.add_argument("--autobaud", action="store_true")
    ap.add_argument("--window", type=float, default=4.0, help="autobaud sampling time per rate")
    ap.add_argument("--interactive", action="store_true")
    ap.add_argument("--list", action="store_true")
    ap.add_argument("--seconds", type=float, default=0, help="stop after N seconds (0 = until Ctrl+C)")
    args = ap.parse_args()

    if args.list or not args.port:
        list_ports()
        return

    baud = autobaud(args.port, args.window) if args.autobaud else args.baud
    LOG_DIR.mkdir(exist_ok=True)
    log_path = LOG_DIR / f"uart_{datetime.datetime.now():%Y%m%d_%H%M%S}_{baud}.log"
    print(f"Logging {args.port} @ {baud} to {log_path}  (Ctrl+C to stop)")

    ser = serial.Serial(args.port, baud, timeout=0.1)
    stop = threading.Event()

    def reader():
        with open(log_path, "ab") as log:
            while not stop.is_set():
                data = ser.read(4096)
                if data:
                    log.write(data)
                    log.flush()
                    sys.stdout.write(data.decode("utf-8", errors="replace"))
                    sys.stdout.flush()

    t = threading.Thread(target=reader, daemon=True)
    t.start()
    try:
        if args.interactive:
            for line in sys.stdin:
                line = line.rstrip("\r\n")
                ser.write(b"\x03" if line == "^C" else line.encode() + b"\n")
        else:
            deadline = time.time() + args.seconds if args.seconds else None
            while deadline is None or time.time() < deadline:
                time.sleep(0.5)
    except KeyboardInterrupt:
        pass
    finally:
        stop.set()
        t.join(1)
        ser.close()
        print(f"\nSaved {log_path}")


if __name__ == "__main__":
    main()
