"""The HTTP/1.1 server of the specs: an independent peer, Python's standard library only.

Usage: python3 peer.py [IDLE_MS]. It listens on 127.0.0.1, port 0, prints `port N` and serves until killed. A
keep-alive connection that stays idle for IDLE_MS (default 10000) is closed by the server.

Every response has `x-connection` (the number of the TCP connection it came on, from 1) and a body. The paths:

- /hello: 200 `hello`.
- /echo: 200 with `METHOD TARGET [BODY]`, then the request headers that start with `x-` as `name=value`, all
  joined by spaces.
- /status/N: status N.
- /slow-head?ms=N: waits N ms before the head.
- /slow-body?ms=N: sends the head and half the body, waits N ms, then the rest.
- /bytes?n=N: N bytes of `a`.
- /close: answers with `Connection: close` and closes.
- /keep-alive?s=N: answers with `Keep-Alive: timeout=N`.
"""

import http.server
import sys
import threading
import time
import urllib.parse

lock = threading.Lock()
accepted = 0


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def setup(self):
        global accepted
        super().setup()
        with lock:
            accepted += 1
            self.connection_number = accepted

    def log_message(self, format, *args):
        pass

    def do_GET(self):
        self.answer()

    do_HEAD = do_GET
    do_POST = do_GET
    do_PUT = do_GET
    do_PATCH = do_GET
    do_DELETE = do_GET

    def answer(self):
        url = urllib.parse.urlsplit(self.path)
        query = dict(urllib.parse.parse_qsl(url.query))
        length = int(self.headers.get("content-length") or 0)
        body = self.rfile.read(length) if length else b""
        path = url.path
        if path == "/hello":
            self.send(200, b"hello")
        elif path == "/echo":
            lines = [f"{self.command} {self.path} [{body.decode()}]"]
            lines += [f"{name.lower()}={value}" for name, value in self.headers.items() if name.lower().startswith("x-")]
            self.send(200, " ".join(lines).encode())
        elif path.startswith("/status/"):
            self.send(int(path.split("/")[2]), b"status")
        elif path == "/slow-head":
            time.sleep(int(query.get("ms", "0")) / 1000)
            self.send(200, b"slow head")
        elif path == "/slow-body":
            self.send_response(200)
            self.send_header("content-length", "10")
            self.send_header("x-connection", str(self.connection_number))
            self.end_headers()
            self.wfile.write(b"first")
            self.wfile.flush()
            time.sleep(int(query.get("ms", "0")) / 1000)
            self.wfile.write(b"later")
        elif path == "/bytes":
            self.send(200, b"a" * int(query.get("n", "0")))
        elif path == "/close":
            self.close_connection = True
            self.send(200, b"closing", [("connection", "close")])
        elif path == "/keep-alive":
            self.send(200, b"kept", [("keep-alive", f"timeout={query.get('s', '1')}")])
        else:
            self.send(404, b"not found")

    def send(self, status, body, headers=()):
        self.send_response(status)
        self.send_header("content-length", str(len(body)))
        self.send_header("x-connection", str(self.connection_number))
        for name, value in headers:
            self.send_header(name, value)
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)


def main():
    idle_ms = int(sys.argv[1]) if len(sys.argv) > 1 else 10000
    Handler.timeout = idle_ms / 1000
    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    server.daemon_threads = True
    print(f"port {server.server_address[1]}", flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
