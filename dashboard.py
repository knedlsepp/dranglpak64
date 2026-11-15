"""
drangl-dashboard — Live "Hall of Shame" for the dranglpak64 drink dispenser.

Receives JSON notifications via UDP (sent by drink-dispenser):
    {"event": "hit_banana", "playerIndex": 2, "duration": 1.5}  (dispensed drink)
    {"event": "race_start"}
    {"event": "race_finish", "playerIndex": 2, "place": 1}
    {"event": "battle_out", "playerIndex": 2, "place": 3}
    {"event": "battle_win", "playerIndex": 1}
race_start is also sent at the start of a battle.

Serves a dashboard page on HTTP_PORT that updates live via a WebSocket
(/ws). Where WebSockets don't get through, the page falls back to polling
/state. Daily stats are persisted, so they survive restarts.

Usage: drangl-dashboard <web dir>
"""

import base64
import hashlib
import http.server
import json
import logging
import os
import queue
import socket
import sys
import threading
import time
import urllib.parse
from pathlib import Path

logging.basicConfig(level=logging.INFO)

UDP_ADDR: tuple[str, int] = ("127.0.0.1", 6464)
HTTP_PORT: int = 80
# Pump flow rate: 500 ml/min
ML_PER_SECOND: float = 500 / 60
# Rounds are separated by race_start. As a fallback (e.g. a race was quit),
# a round also counts as finished after this many seconds without any event.
ROUND_IDLE_TIMEOUT: float = 300.0
TICKER_LENGTH: int = 12
# Dispense a drink, but are a reward rather than a hit.
NOT_A_HIT: set[str] = {"negroni_code"}
# Sent every frame while the buttons are held: one press counts once.
HELD_EVENTS: set[str] = {"negroni_code"}

WEBSOCKET_GUID: str = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
# Keeps idle WebSockets open (Cloudflare drops them after 100 s of silence).
WEBSOCKET_KEEPALIVE: float = 15.0

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
        # Mirror of the dispenser's pumps, to count actual pump time.
        self._pump_until: dict[int, float] = {}
        self._last_drink: dict[int, str] = {}
        self._seq = 0
        # Bumped on every change, lets polling clients skip unchanged state.
        self._version = 0

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
        return {**self._stats, "round": self._round, "latest": self._latest, "version": self._version}

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
        now = time.monotonic()
        with self._lock:
            until = self._pump_until.get(player, 0.0)
            pumping = now < until
            # The dispenser extends a running pump instead of restarting it.
            pump_time = max(0.0, now + duration - until) if pumping else duration
            self._pump_until[player] = max(until, now + duration)
            ml = round(pump_time * ML_PER_SECOND, 1)

            held = pumping and event in HELD_EVENTS and self._last_drink.get(player) == event
            self._last_drink[player] = event
            if held:
                self._extend_held_locked(event, player, ml)
                return

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

    def _extend_held_locked(self, event: str, player: int, ml: float) -> None:
        """Add the pump time of a held event without counting it again."""
        self._stats["totalMl"] = round(self._stats["totalMl"] + ml, 1)
        p = self._round.setdefault(str(player), {"hits": 0, "ml": 0.0})
        p["ml"] = round(p["ml"] + ml, 1)
        for entry in self._stats["ticker"]:
            if entry["player"] == player and entry["event"] == event:
                entry["ml"] = round(entry["ml"] + ml, 1)
                break
        # Not saved: arrives every frame while held, spare the SD card.
        self._broadcast_locked()

    def check_round_timeout(self) -> None:
        with self._lock:
            idle = time.monotonic() - self._last_event > ROUND_IDLE_TIMEOUT
            if self._round and idle:
                self._finish_round_locked()
                self._latest = None
                self._broadcast_locked()

    def _broadcast_locked(self) -> None:
        self._version += 1
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

    def poll(self, since: int) -> dict | None:
        """Current snapshot, or None if nothing changed since that version."""
        with self._lock:
            if since == self._version:
                return None
            return self._snapshot_locked()

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


def websocket_frame(opcode: int, payload: bytes) -> bytes:
    """A single unmasked (server to client) WebSocket frame."""
    n = len(payload)
    if n < 126:
        header = bytes([0x80 | opcode, n])
    elif n < 1 << 16:
        header = bytes([0x80 | opcode, 126]) + n.to_bytes(2, "big")
    else:
        header = bytes([0x80 | opcode, 127]) + n.to_bytes(8, "big")
    return header + payload


def make_handler(dashboard: Dashboard, files: dict[str, tuple[str, bytes]]) -> type:
    class Handler(http.server.BaseHTTPRequestHandler):
        # WebSocket upgrades require HTTP/1.1
        protocol_version = "HTTP/1.1"

        def do_GET(self) -> None:
            url = urllib.parse.urlsplit(self.path)
            if url.path == "/ws":
                self._websocket()
                return
            if url.path == "/state":
                self._state(url.query)
                return
            # Any unknown path gets the dashboard, so captive portal checks of
            # phones land there too.
            content_type, body = files.get(self.path, files["/index.html"])
            self.send_response(200)
            self.send_header("Content-Type", content_type)
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def _state(self, query: str) -> None:
            since = urllib.parse.parse_qs(query).get("since", ["-1"])[0]
            snapshot = dashboard.poll(int(since) if since.lstrip("-").isdigit() else -1)
            if snapshot is None:
                self.send_response(204)
                self.send_header("Cache-Control", "no-store")
                self.end_headers()
                return
            body = json.dumps(snapshot).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Cache-Control", "no-store")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def _websocket(self) -> None:
            key = self.headers.get("Sec-WebSocket-Key")
            if key is None or self.headers.get("Upgrade", "").lower() != "websocket":
                self.send_error(400)
                return
            accept = base64.b64encode(hashlib.sha1((key + WEBSOCKET_GUID).encode()).digest())
            self.send_response(101)
            self.send_header("Upgrade", "websocket")
            self.send_header("Connection", "Upgrade")
            self.send_header("Sec-WebSocket-Accept", accept.decode())
            self.end_headers()
            self.close_connection = True
            # Only ever sends: browsers send nothing but a close frame, and a
            # gone browser shows up as failing write.
            q = dashboard.subscribe()
            try:
                while True:
                    try:
                        frame = websocket_frame(0x1, json.dumps(q.get(timeout=WEBSOCKET_KEEPALIVE)).encode())
                    except queue.Empty:
                        # Unsolicited pong: a heartbeat browsers don't answer
                        frame = websocket_frame(0xA, b"")
                    self.wfile.write(frame)
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
