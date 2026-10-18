#!/usr/bin/env python3
"""Explicit disposable loopback-only MEDIA contract fixture, not a live server."""
import hashlib
import json
import os
from pathlib import Path
import socket
import tempfile
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlsplit, parse_qs
import zipfile

root = tempfile.TemporaryDirectory(prefix='hermex-media-wire-', dir=os.environ['TMPDIR'])
archive = Path(root.name) / 'fixture.zip'
with zipfile.ZipFile(archive, 'w', compression=zipfile.ZIP_STORED) as zipped:
    with zipped.open('fixture.bin', 'w') as out:
        for _ in range(256):
            out.write(bytes(range(256)) * 256)
digest = hashlib.sha256(archive.read_bytes()).hexdigest()
events = []
lock = threading.Lock()

class Handler(BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'
    def log_message(self, *args):
        pass
    def reply(self, status, body=b'', headers=None):
        self.send_response(status)
        self.send_header('Content-Length', str(len(body)))
        for key, value in (headers or {}).items():
            self.send_header(key, value)
        self.end_headers()
        self.wfile.write(body)
    def do_POST(self):
        self.rfile.read(int(self.headers.get('Content-Length', 0)))
        self.reply(200, b'{"ok":true}', {'Set-Cookie': 'hermex_fixture=fixture-only-cookie; Path=/; HttpOnly'})
    def do_GET(self):
        parsed = urlsplit(self.path)
        if parsed.path == '/events':
            with lock:
                self.reply(200, json.dumps(events).encode())
            return
        if parsed.path == '/health':
            self.reply(200, b'{"fixture":"hermex-mac-media-v1"}')
            return
        if parsed.path == '/api/auth/status':
            logged_in = 'hermex_fixture=fixture-only-cookie' in self.headers.get('Cookie', '')
            self.reply(200, json.dumps({'auth_enabled': True, 'logged_in': logged_in}).encode())
            return
        if parsed.path in ('/api/sessions', '/api/models', '/api/providers', '/api/profiles', '/api/workspaces'):
            self.reply(200, b'{}')
            return
        if parsed.path == '/api/session':
            session_id = parse_qs(parsed.query).get('session_id', [''])[0]
            self.reply(200, json.dumps({'session': {'session_id': session_id, 'messages': []}}).encode())
            return
        with lock:
            events.append({'origin': getattr(self.server, 'tag'), 'path': parsed.path, 'query': parse_qs(parsed.query), 'headers': dict(self.headers)})
        if parsed.path == '/api/media':
            if self.headers.get('CF-Access-Client-Secret') != 'fixture-only-secret' or 'hermex_fixture=fixture-only-cookie' not in self.headers.get('Cookie', ''):
                self.reply(401, b'echo fixture-only-secret must never be shown')
                return
            source = parse_qs(parsed.query).get('path', [''])[0]
            if source in ('/srv/401', '/srv/403', '/srv/404'):
                self.reply(int(source[-3:]), b'echo fixture-only-secret must never be shown')
                return
            if source == '/srv/redirect':
                self.reply(302, headers={'Location': second_url + '/capture'})
                return
            if source == '/srv/same-redirect':
                self.reply(302, headers={'Location': '/same-capture'})
                return
            if source == '/srv/disconnect':
                self.send_response(200)
                self.send_header('Content-Length', '9999999')
                self.end_headers()
                self.wfile.write(b'incomplete')
                self.wfile.flush()
                self.connection.shutdown(socket.SHUT_RDWR)
                self.connection.close()
                return
        if parsed.path in ('/api/media', '/external', '/same-capture', '/capture'):
            self.send_response(200)
            self.send_header('Content-Type', 'application/zip')
            self.send_header('Content-Length', str(archive.stat().st_size))
            self.end_headers()
            with archive.open('rb') as inp:
                while chunk := inp.read(65536):
                    self.wfile.write(chunk)
            return
        self.reply(404)

first = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
second = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
first.tag, second.tag = 'authenticated', 'public'
second_url = f'http://127.0.0.1:{second.server_port}'
threading.Thread(target=first.serve_forever, daemon=True).start()
threading.Thread(target=second.serve_forever, daemon=True).start()
print(json.dumps({'first': f'http://127.0.0.1:{first.server_port}', 'second': second_url, 'sha256': digest, 'size': archive.stat().st_size}), flush=True)
# Parent closes stdin to cleanly stop both servers and remove fixture data.
try:
    while input():
        pass
except EOFError:
    pass
first.shutdown()
second.shutdown()
first.server_close()
second.server_close()
root.cleanup()
