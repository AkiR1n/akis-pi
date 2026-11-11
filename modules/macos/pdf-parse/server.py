#!/usr/bin/env python3
"""Local PDF -> Markdown endpoint for pi-web-access (`pdf.endpointUrl`).

Deterministic, offline, no LLM: PyMuPDF text in visual order plus detected
tables as Markdown. Responds 422 when a PDF has no usable text layer, so the
extension's `pdf.provider: "auto"` chain can fall through to Gemini for
scanned documents.

POST /parse  multipart/form-data with a `file` field
             optional `max_pages`
          -> 200 {"markdown": "..."}
          -> 422 {"error": "..."}   no text layer / unreadable
GET  /health -> 200 {"ok": true}
"""

import json
import os
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import pymupdf

PORT = int(os.environ.get("PI_PDF_PARSE_PORT", "8791"))
HOST = os.environ.get("PI_PDF_PARSE_HOST", "127.0.0.1")
MAX_BYTES = 64 * 1024 * 1024
DEFAULT_MAX_PAGES = 200
MIN_TEXT_CHARS = 200


def parse_multipart(body: bytes, content_type: str) -> dict[str, bytes]:
    marker = "boundary="
    idx = content_type.find(marker)
    if idx < 0:
        raise ValueError("not multipart/form-data")
    boundary = content_type[idx + len(marker) :].split(";")[0].strip().strip('"')
    sep = b"--" + boundary.encode()
    parts: dict[str, bytes] = {}
    for chunk in body.split(sep):
        if not chunk or chunk in (b"--\r\n", b"--"):
            continue
        head, _, data = chunk.partition(b"\r\n\r\n")
        if not _:
            continue
        name = None
        for line in head.split(b"\r\n"):
            if b"content-disposition" in line.lower() and b"name=" in line.lower():
                frag = line.split(b"name=", 1)[1].strip()
                name = frag.split(b";")[0].strip().strip(b'"').decode("utf-8", "replace")
                break
        if name:
            parts[name] = data[:-2] if data.endswith(b"\r\n") else data
    return parts


def table_markdown(tab) -> str:
    try:
        md = tab.to_markdown()
    except Exception:
        return ""
    return md.strip()


def pdf_to_markdown(data: bytes, max_pages: int) -> str:
    doc = pymupdf.open(stream=data, filetype="pdf")
    try:
        out: list[str] = []
        total = doc.page_count
        limit = min(total, max_pages)
        for i in range(limit):
            page = doc[i]
            parts: list[str] = []
            try:
                text = page.get_text("text", sort=True).strip()
            except Exception:
                text = page.get_text().strip()
            if text:
                parts.append(text)
            try:
                tables = page.find_tables()
                for tab in tables.tables:
                    md = table_markdown(tab)
                    if md:
                        parts.append(md)
            except Exception:
                pass
            if parts:
                out.append(f"<!-- Page {i + 1} -->\n\n" + "\n\n".join(parts))
        if limit < total:
            out.append(f"<!-- truncated at {limit} of {total} pages -->")
        return "\n\n".join(out)
    finally:
        doc.close()


class Handler(BaseHTTPRequestHandler):
    server_version = "pi-pdf-parse/1.0"

    def log_message(self, fmt, *args):  # keep the launchd log quiet
        sys.stderr.write("%s - %s\n" % (self.address_string(), fmt % args))

    def _send(self, code: int, payload: dict) -> None:
        body = json.dumps(payload, ensure_ascii=False).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self) -> None:
        if self.path.split("?")[0] == "/health":
            self._send(200, {"ok": True})
            return
        self._send(404, {"error": "not found"})

    def do_POST(self) -> None:
        if self.path.split("?")[0] != "/parse":
            self._send(404, {"error": "not found"})
            return
        try:
            length = int(self.headers.get("Content-Length") or 0)
        except ValueError:
            length = 0
        if length <= 0:
            self._send(400, {"error": "empty body"})
            return
        if length > MAX_BYTES:
            self._send(413, {"error": "file too large"})
            return
        body = self.rfile.read(length)
        ctype = self.headers.get("Content-Type") or ""
        try:
            parts = parse_multipart(body, ctype)
        except Exception as err:
            self._send(400, {"error": f"malformed multipart: {err}"})
            return
        data = parts.get("file")
        if not data:
            self._send(400, {"error": "missing file field"})
            return
        max_pages = DEFAULT_MAX_PAGES
        raw_pages = parts.get("max_pages")
        if raw_pages:
            try:
                max_pages = max(1, min(int(raw_pages.decode().strip()), 2000))
            except Exception:
                pass
        try:
            markdown = pdf_to_markdown(data, max_pages)
        except Exception as err:
            self._send(422, {"error": f"cannot read PDF: {err}"})
            return
        stripped = "".join(ch for ch in markdown if not ch.isspace())
        if len(stripped) < MIN_TEXT_CHARS:
            self._send(422, {"error": "no usable text layer (scanned PDF?); use a vision/OCR engine"})
            return
        self._send(200, {"markdown": markdown})


class Server(ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = True


if __name__ == "__main__":
    httpd = Server((HOST, PORT), Handler)
    sys.stderr.write(f"pi-pdf-parse listening on http://{HOST}:{PORT}\n")
    httpd.serve_forever()
