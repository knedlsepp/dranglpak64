"""
drangl-dashboard — Live "Hall of Shame" for the dranglpak64 drink dispenser.

Receives JSON notifications via UDP (sent by drink-dispenser):
    {"event": "hit_banana", "playerIndex": 2, "duration": 1.5}  (dispensed drink)
    {"event": "race_start"}
    {"event": "race_finish", "playerIndex": 2, "place": 1}
    {"event": "battle_out", "playerIndex": 2, "place": 3}
    {"event": "battle_win", "playerIndex": 1}
race_start is also sent at the start of a battle.

Serves a dashboard page on HTTP_PORT that updates live via Server-Sent
Events. Daily stats are persisted, so they survive restarts.

Usage: drangl-dashboard <web dir>
"""

import http.server
import json
import logging
import os
import queue
import socket
import sys
import threading
import time
from pathlib import Path

logging.basicConfig(level=logging.INFO)

UDP_ADDR: tuple[str, int] = ("127.0.0.1", 6464)
HTTP_PORT: int = 80
# FIXME: Calibrate: measure how many ml one pump delivers per second.
ML_PER_SECOND: float = 10.0
# Rounds are separated by race_start. As a fallback (e.g. a race was quit),
# a round also counts as finished after this many seconds without any event.
ROUND_IDLE_TIMEOUT: float = 300.0
TICKER_LENGTH: int = 12
# Dispense a drink, but are a reward rather than a hit.
NOT_A_HIT: set[str] = {"negroni_code"}

STATE_FILE: Path = Path(os.environ.get("STATE_DIRECTORY", ".")) / "stats.json"


def empty_stats() -> dict:
    return {
        "totalHits": 0,
        "totalMl": 0.0,
        "byEvent": {},
        "ticker": [],
        "record": None,
    }


class Dashboard:
    """Aggregates events and broadcasts snapshots to all connected browsers."""

    def __init__(self) -> None:
        self._lock = threading.Lock()
        self._clients: list[queue.Queue] = []
        self._stats = self._load()
        self._round: dict[str, dict] = {}
        self._last_event = 0.0
        self._latest: dict | None = None
        self._seq = 0

    def _load(self) -> dict:
        try:
            return {**empty_stats(), **json.loads(STATE_FILE.read_text())}
        except (OSError, json.JSONDecodeError):
            return empty_stats()

    def _save_locked(self) -> None:
        tmp = STATE_FILE.with_suffix(".tmp")
        tmp.write_text(json.dumps(self._stats))
        os.replace(tmp, STATE_FILE)

    def _snapshot_locked(self) -> dict:
        return {**self._stats, "round": self._round, "latest": self._latest}

    def _finish_round_locked(self) -> None:
        self._round = {}

    def _next_entry_locked(self, event: str, player: int) -> dict:
        self._seq += 1
        return {
            "t": time.strftime("%H:%M:%S"),
            "player": player,
            "event": event,
            "id": self._seq,
        }

    def start_race(self) -> None:
        with self._lock:
            self._finish_round_locked()
            self._last_event = time.monotonic()
            self._latest = None
            self._broadcast_locked()

    def finish_race(self, event: str, player: int, place: int) -> None:
        with self._lock:
            self._last_event = time.monotonic()
            p = self._round.setdefault(str(player), {"hits": 0, "ml": 0.0})
            p["place"] = place
            self._latest = {**self._next_entry_locked(event, player), "place": place}
            self._broadcast_locked()

    def handle_drink(self, event: str, player: int, duration: float) -> None:
        ml = round(duration * ML_PER_SECOND, 1)
        now = time.monotonic()
        with self._lock:
            entry = {**self._next_entry_locked(event, player), "ml": ml}
            if now - self._last_event > ROUND_IDLE_TIMEOUT:
                self._finish_round_locked()
            self._last_event = now

            is_hit = event not in NOT_A_HIT
            stats = self._stats
            stats["totalHits"] += is_hit
            stats["totalMl"] = round(stats["totalMl"] + ml, 1)
            stats["byEvent"][event] = stats["byEvent"].get(event, 0) + 1
            stats["ticker"] = [entry, *stats["ticker"]][:TICKER_LENGTH]

            p = self._round.setdefault(str(player), {"hits": 0, "ml": 0.0})
            p["hits"] += is_hit
            p["ml"] = round(p["ml"] + ml, 1)

            record = stats["record"]
            if record is None or p["hits"] > record["hits"]:
                stats["record"] = {"hits": p["hits"], "player": player, "at": time.strftime("%H:%M")}

            self._latest = entry
            self._save_locked()
            self._broadcast_locked()

    def check_round_timeout(self) -> None:
        with self._lock:
            idle = time.monotonic() - self._last_event > ROUND_IDLE_TIMEOUT
            if self._round and idle:
                self._finish_round_locked()
                self._latest = None
                self._broadcast_locked()

    def _broadcast_locked(self) -> None:
        snapshot = self._snapshot_locked()
        for q in list(self._clients):
            try:
                q.put_nowait(snapshot)
            except queue.Full:
                # Client stopped reading; drop it.
                self._clients.remove(q)

    def subscribe(self) -> queue.Queue:
        q: queue.Queue = queue.Queue(maxsize=100)
        with self._lock:
            # Don't replay an old flash animation to a freshly opened page.
            q.put_nowait({**self._snapshot_locked(), "latest": None})
            self._clients.append(q)
        return q

    def unsubscribe(self, q: queue.Queue) -> None:
        with self._lock:
            if q in self._clients:
                self._clients.remove(q)


def udp_listener(dashboard: Dashboard) -> None:
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.bind(UDP_ADDR)
    logging.info(f"Listening for events on udp://{UDP_ADDR[0]}:{UDP_ADDR[1]}")
    while True:
        raw, _ = sock.recvfrom(4096)
        try:
            data = json.loads(raw)
            event = str(data["event"])
            if event == "race_start":
                dashboard.start_race()
            elif event in ("race_finish", "battle_out"):
                dashboard.finish_race(event, int(data["playerIndex"]), int(data["place"]))
            elif event == "battle_win":
                dashboard.finish_race(event, int(data["playerIndex"]), 1)
            else:
                dashboard.handle_drink(event, int(data["playerIndex"]), float(data["duration"]))
        except (ValueError, KeyError, TypeError):
            logging.info(f"Ignoring malformed event: {raw!r}")


def round_watchdog(dashboard: Dashboard) -> None:
    while True:
        time.sleep(2)
        dashboard.check_round_timeout()


CONTENT_TYPES: dict[str, str] = {
    ".html": "text/html; charset=utf-8",
    ".ttf": "font/ttf",
    ".txt": "text/plain; charset=utf-8",
}


def load_web_files(web_dir: Path) -> dict[str, tuple[str, bytes]]:
    return {
        f"/{f.name}": (CONTENT_TYPES.get(f.suffix, "application/octet-stream"), f.read_bytes())
        for f in web_dir.iterdir()
        if f.is_file()
    }


def make_handler(dashboard: Dashboard, files: dict[str, tuple[str, bytes]]) -> type:
    class Handler(http.server.BaseHTTPRequestHandler):
        def do_GET(self) -> None:
            if self.path == "/events":
                self._stream()
                return
            # Any unknown path gets the dashboard, so captive portal checks of
            # phones land there too.
            content_type, body = files.get(self.path, files["/index.html"])
            self.send_response(200)
            self.send_header("Content-Type", content_type)
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def _stream(self) -> None:
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.send_header("Cache-Control", "no-cache")
            self.end_headers()
            q = dashboard.subscribe()
            try:
                while True:
                    try:
                        chunk = f"data: {json.dumps(q.get(timeout=15))}\n\n"
                    except queue.Empty:
                        chunk = ": keepalive\n\n"
                    self.wfile.write(chunk.encode())
                    self.wfile.flush()
            except (BrokenPipeError, ConnectionResetError):
                pass
            finally:
                dashboard.unsubscribe(q)

        def log_message(self, format: str, *args) -> None:
            pass

    return Handler


def main() -> None:
    files = load_web_files(Path(sys.argv[1]))
    dashboard = Dashboard()
    threading.Thread(target=udp_listener, args=[dashboard], daemon=True).start()
    threading.Thread(target=round_watchdog, args=[dashboard], daemon=True).start()
    server = http.server.ThreadingHTTPServer(
        ("", HTTP_PORT), make_handler(dashboard, files)
    )
    logging.info(f"Dashboard at http://0.0.0.0:{HTTP_PORT}/")
    server.serve_forever()


if __name__ == "__main__":
    main()
