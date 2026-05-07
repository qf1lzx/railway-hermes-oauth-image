import http.server
import os
import socketserver

PORT = int(os.environ.get("PORT", "8080"))

class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path in {"/", "/health"}:
            self.send_response(200)
            self.end_headers()
            self.wfile.write(b"hermes gateway container ok")
            return
        self.send_response(404)
        self.end_headers()
        self.wfile.write(b"not found")

    def log_message(self, fmt, *args):
        print(f"[health] {self.address_string()} - {fmt % args}", flush=True)

with socketserver.ThreadingTCPServer(("0.0.0.0", PORT), Handler) as httpd:
    print(f"[health] listening on 0.0.0.0:{PORT}", flush=True)
    httpd.serve_forever()
