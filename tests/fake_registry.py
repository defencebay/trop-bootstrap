#!/usr/bin/env python3
import base64
from hashlib import sha256
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
from pathlib import Path
import sys
from urllib.parse import urlparse


BUNDLE = Path(sys.argv[1]).read_bytes()
USERNAME = sys.argv[2]
SECRET = sys.argv[3]
MODE = sys.argv[4]
PORT_FILE = Path(sys.argv[5])
TOKEN = "test-registry-bearer-token"


class Handler(BaseHTTPRequestHandler):
    def log_message(self, _format, *_args):
        return

    def send_bytes(self, status, content, content_type="application/octet-stream"):
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(content)))
        self.end_headers()
        self.wfile.write(content)

    def do_GET(self):
        path = urlparse(self.path).path
        if path == "/service/token":
            expected = "Basic " + base64.b64encode(
                f"{USERNAME}:{SECRET}".encode()
            ).decode()
            if self.headers.get("Authorization") != expected:
                self.send_bytes(401, b'{"error":"unauthorized"}', "application/json")
                return
            self.send_bytes(200, json.dumps({"token": TOKEN}).encode(), "application/json")
            return

        if self.headers.get("Authorization") != f"Bearer {TOKEN}":
            self.send_bytes(401, b'{"error":"unauthorized"}', "application/json")
            return

        if "/manifests/" in path:
            digest = sha256(BUNDLE).hexdigest()
            manifest = {
                "schemaVersion": 2,
                "mediaType": "application/vnd.oci.image.manifest.v1+json",
                "artifactType": "application/vnd.defencebay.trop.bootstrap.bundle.v1",
                "config": {
                    "mediaType": "application/vnd.defencebay.trop.bootstrap.config.v1+json",
                    "digest": "sha256:" + "0" * 64,
                    "size": 2,
                },
                "layers": [
                    {
                        "mediaType": "application/vnd.defencebay.trop.bootstrap.layer.v1.tar+gzip",
                        "digest": "sha256:" + ("f" * 64 if MODE == "bad-digest" else digest),
                        "size": len(BUNDLE),
                    }
                ],
            }
            self.send_bytes(200, json.dumps(manifest).encode(), manifest["mediaType"])
            return

        if "/blobs/" in path:
            self.send_bytes(200, BUNDLE)
            return

        self.send_bytes(404, b'{"error":"not found"}', "application/json")


server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
PORT_FILE.write_text(str(server.server_port), encoding="utf-8")
server.serve_forever()
