#!/usr/bin/env python3
"""Explicit loopback protocol fixture, NOT a Hermes runtime or live verification.
Shapes follow upstream APIClient/Endpoints/models and webui 641878bd auth/routes.
Only in-memory fixture records are mutated. Never forwards requests elsewhere.
"""
import argparse
import http.server
import json
import threading
import urllib.parse
import uuid
from typing import cast

PASSWORD = 'hermex-fixture-only'
COOKIE = 'hermes_session=fixture-only'
FIXTURE_HEADERS = {'CF-Access-Client-Id': 'fixture-only-id', 'CF-Access-Client-Secret': 'fixture-only-secret', 'X-Fixture-Connection': 'fixture-only-generic'}

class Fixture(http.server.BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'
    sessions = {}
    starts = 0
    chat_profiles = []
    uploaded = False
    last_body = {}
    fail_next_stream = False
    require_headers = False
    header_paths = []

    def check_headers(self):
        if not type(self).require_headers:
            return True
        if any(self.headers.get(name) != value for name, value in FIXTURE_HEADERS.items()):
            data = b'<html>Cloudflare Access fixture: missing Service Token headers</html>'
            self.send_response(403)
            self.send_header('Server', 'cloudflare')
            self.send_header('Content-Type', 'text/html')
            self.send_header('Content-Length', str(len(data)))
            self.end_headers()
            self.wfile.write(data)
            return False
        type(self).header_paths.append((self.command, urllib.parse.urlparse(self.path).path))
        return True

    def log_message(self, *_):
        pass

    def reply(self, obj, status=200, headers=None):
        data = json.dumps(obj).encode()
        self.send_response(status)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(data)))
        for key, value in (headers or {}).items():
            self.send_header(key, value)
        self.end_headers()
        self.wfile.write(data)

    def session(self, sid):
        return self.sessions.get(sid)

    def do_GET(self):
        if not self.check_headers():
            return
        parsed = urllib.parse.urlparse(self.path)
        path = parsed.path
        qs = urllib.parse.parse_qs(parsed.query)
        sid = qs.get('session_id', [''])[0]
        logged = COOKIE in self.headers.get('Cookie', '')
        if path == '/health':
            return self.reply({'status': 'ok', 'sessions': len(self.sessions), 'fixture': 'hermex-mac-protocol-v1'})
        if path == '/api/auth/status':
            return self.reply({'auth_enabled': True, 'logged_in': logged, 'password_auth_enabled': True})
        if not logged:
            return self.reply({'error': 'Authentication required'}, 401)
        if path == '/api/sessions':
            rows = list(self.sessions.values())
            if qs.get('include_archived') != ['1']:
                rows = [x for x in rows if not x.get('archived')]
            return self.reply({'sessions': rows, 'archived_count': sum(bool(x.get('archived')) for x in self.sessions.values())})
        if path == '/api/sessions/search':
            query = qs.get('q', [''])[0].lower()
            return self.reply({'sessions': [x for x in self.sessions.values() if query in x['title'].lower()], 'query': query})
        if path == '/api/session':
            item = self.session(sid)
            return self.reply({'session': item}) if item else self.reply({'error': 'Session not found'}, 404)
        if path == '/api/session/status':
            item = self.session(sid) or {}
            return self.reply({'session_id': sid, 'is_streaming': bool(item.get('active_stream_id')), 'active_stream_id': item.get('active_stream_id')})
        if path == '/api/chat/stream/status':
            return self.reply({'active': True, 'stream_id': qs.get('stream_id', [''])[0], 'replay_available': True})
        if path == '/api/chat/cancel':
            for item in self.sessions.values():
                item['active_stream_id'] = None
            return self.reply({'ok': True, 'cancelled': True})
        if path == '/api/chat/stream':
            stream = qs.get('stream_id', [''])[0]
            item = next((x for x in self.sessions.values() if x.get('active_stream_id') == stream), None)
            if not item:
                return self.reply({'error': 'No stream'}, 404)
            events = [
                ('reasoning', {'text': 'Fixture reasoning, no model was called.'}),
                ('tool', {'name': 'read_file', 'tid': 'fixture-tool', 'preview': 'README.md'}),
                ('tool_complete', {'name': 'read_file', 'tid': 'fixture-tool', 'preview': 'fixture file read', 'duration': 0.01}),
                ('token', {'text': 'Fixture **streamed** response.\n\n```swift\nprint("hello")\n```'}),
                ('done', {}),
                ('stream_end', {})
            ]
            after = int(qs.get('after_seq', ['0'])[0])
            frames = ''.join(f'id: {stream}:{index}\nevent: {kind}\ndata: {json.dumps(body)}\n\n' for index, (kind, body) in enumerate(events, 1) if index > after)
            # One deliberately cut connection proves reattach without another start.
            cut = type(self).fail_next_stream and not qs.get('replay')
            if cut:
                type(self).fail_next_stream = False
                frames = ''.join(frames.splitlines(keepends=True)[:16])
            else:
                item['messages'].append({'role': 'assistant', 'content': events[3][1]['text'], 'reasoning': events[0][1]['text']})
                item['message_count'] = len(item['messages'])
                item['active_stream_id'] = None
            data = frames.encode()
            self.send_response(200)
            self.send_header('Content-Type', 'text/event-stream')
            self.send_header('Content-Length', str(len(data)))
            self.end_headers()
            self.wfile.write(data)
            self.wfile.flush()
            return
        if path == '/api/workspaces':
            return self.reply({'workspaces': [{'path': '/fixture/workspace', 'name': 'Fixture Workspace'}], 'last': '/fixture/workspace'})
        if path == '/api/models':
            return self.reply({'groups': [{'provider_id': 'fixture', 'provider': 'fixture', 'name': 'Fixture', 'models': [{'id': 'fixture-model', 'name': 'Fixture Model'}]}], 'default_model': 'fixture-model', 'active_provider': 'fixture'})
        if path == '/api/providers':
            return self.reply({'providers': [{'id': 'fixture', 'display_name': 'Fixture', 'has_key': True, 'models': [{'id': 'fixture-model', 'label': 'Fixture Model'}]}], 'active_provider': 'fixture'})
        if path == '/api/profiles':
            return self.reply({'profiles': [{'name': 'default', 'is_active': True}, {'name': 'research'}], 'active': 'default'})
        if path == '/api/list':
            return self.reply({'entries': [{'name': 'README.md', 'path': 'README.md', 'type': 'file', 'size': 55}, {'name': 'src', 'path': 'src', 'type': 'directory', 'is_directory': True}], 'path': qs.get('path', [''])[0], 'workspace': '/fixture/workspace'})
        if path == '/api/file':
            return self.reply({'content': '# Fixture workspace\n\nRead-only native file preview.', 'path': qs.get('path', [''])[0], 'language': 'markdown'})
        if path == '/api/skills':
            return self.reply({'skills': [{'name': 'fixture-skill', 'description': 'Explicit fixture skill', 'category': 'testing', 'disabled': False}]})
        if path == '/api/skills/content':
            return self.reply({'name': 'fixture-skill', 'content': '# Fixture skill\nProtocol test only.'})
        if path == '/api/memory':
            return self.reply({'memory': '# Fixture memory', 'user': 'Fixture user', 'soul': 'Fixture soul'})
        if path == '/api/crons':
            return self.reply({'jobs': [{'id': 'fixture-job', 'name': 'Fixture scheduled task', 'prompt': 'Fixture only', 'schedule': '0 9 * * *', 'enabled': True}], 'server_time': 1792200000})
        if path == '/api/crons/output':
            return self.reply({'job_id': qs.get('job_id', ['fixture-job'])[0], 'outputs': [{'filename': 'fixture-run.txt', 'content': 'Explicit fixture output. No scheduled task actually ran.'}]})
        if path == '/api/insights':
            return self.reply({'period_days': 30, 'total_sessions': 1, 'total_messages': 2, 'total_input_tokens': 24, 'total_output_tokens': 12, 'total_tokens': 36, 'total_cost': 0.0, 'daily_tokens': [], 'models': []})
        if path == '/api/approval/pending' or path == '/api/clarify/pending':
            return self.reply({'pending': None, 'pending_count': 0})
        if path == '/fixture/assertions':
            return self.reply({'starts': type(self).starts, 'uploaded': type(self).uploaded, 'sessions': len(self.sessions)})
        return self.reply({'error': 'Unsupported fixture route: ' + path}, 404)

    def do_POST(self):
        path = urllib.parse.urlparse(self.path).path
        data = self.rfile.read(int(self.headers.get('Content-Length', '0')))
        if not self.check_headers():
            return
        if path == '/api/auth/login':
            body = json.loads(data)
            if body.get('password') != PASSWORD:
                return self.reply({'error': 'Invalid password'}, 401)
            return self.reply({'ok': True}, headers={'Set-Cookie': COOKIE + '; Path=/; HttpOnly; SameSite=Strict'})
        if COOKIE not in self.headers.get('Cookie', ''):
            return self.reply({'error': 'Authentication required'}, 401)
        if path == '/api/auth/logout':
            return self.reply({'ok': True}, headers={'Set-Cookie': 'hermes_session=; Path=/; Max-Age=0'})
        if path == '/api/upload':
            if not self.headers.get('Content-Type', '').startswith('multipart/form-data; boundary='):
                return self.reply({'error': 'Wrong multipart Content-Type'}, 400)
            if b'name="session_id"' not in data or b'name="file"' not in data:
                return self.reply({'error': 'Wrong multipart fields'}, 400)
            type(self).uploaded = True
            return self.reply({'filename': 'fixture.txt', 'path': '/fixture/uploads/fixture.txt', 'mime': 'text/plain', 'size': 12, 'is_image': False})
        body = json.loads(data or '{}')
        type(self).last_body = body
        sid = body.get('session_id', '')
        item = self.session(sid)
        if path == '/api/session/new':
            sid = 'fixture-' + uuid.uuid4().hex[:12]
            item = {'session_id': sid, 'title': 'Untitled', 'messages': [], 'message_count': 0, 'pinned': False, 'archived': False, 'workspace': body.get('workspace') or '/fixture/workspace', 'model': body.get('model') or 'fixture-model', 'model_provider': body.get('model_provider') or 'fixture', 'profile': body.get('profile') or 'default'}
            self.sessions[sid] = item
            return self.reply({'session': item})
        if path == '/api/chat/start' and item:
            if not body.get('message'):
                return self.reply({'error': 'Message required'}, 400)
            type(self).starts += 1
            type(self).chat_profiles.append(body.get('profile'))
            item['active_stream_id'] = 'stream-' + uuid.uuid4().hex[:8]
            item['messages'].append({'role': 'user', 'content': body['message'], 'attachments': body.get('attachments', [])})
            item['message_count'] = len(item['messages'])
            return self.reply({'stream_id': item['active_stream_id'], 'session_id': sid})
        if path == '/api/session/rename' and item:
            item['title'] = body['title']
        elif path == '/api/session/pin' and item:
            item['pinned'] = body['pinned']
        elif path == '/api/session/archive' and item:
            item['archived'] = body['archived']
        elif path == '/api/session/update' and item:
            item.update({k: v for k, v in body.items() if k in ('model', 'model_provider', 'workspace')})
            return self.reply({'session': item})
        elif path == '/api/session/delete' and item:
            del self.sessions[sid]
            return self.reply({'ok': True})
        elif path == '/api/approval/respond' or path == '/api/clarify/respond':
            return self.reply({'ok': True})
        else:
            return self.reply({'error': 'Unsupported fixture mutation'}, 404)
        return self.reply({'ok': True, 'session': item})

class RedirectServer(http.server.ThreadingHTTPServer):
    events: list[dict]
    other_origin: str


class RedirectFixture(http.server.BaseHTTPRequestHandler):
    """Two loopback origins exercise the real Foundation redirect delegate."""
    protocol_version = 'HTTP/1.1'


    def log_message(self, format, *args):
        pass

    def respond(self, data, content_type='application/json', status=200, location=None):
        self.send_response(status)
        self.send_header('Content-Type', content_type)
        self.send_header('Content-Length', str(len(data)))
        if location:
            self.send_header('Location', location)
        self.end_headers()
        self.wfile.write(data)
        self.wfile.flush()

    def handle_request(self, body=b''):
        server = cast(RedirectServer, self.server)
        path = urllib.parse.urlparse(self.path).path
        server.events.append({'path': path, 'method': self.command, 'headers': dict(self.headers), 'body': body})
        if path == '/health':
            return self.respond(b'{"fixture":"hermex-mac-redirect-v1"}')
        if path.startswith('/same/') or path.startswith('/cross/'):
            prefix, suffix = path[1:].split('/', 1)
            origin = server.other_origin if prefix == 'cross' else ''
            return self.respond(b'', status=307, location=origin + '/capture/' + suffix)
        if path.endswith('/api/chat/stream'):
            return self.respond(b'id: fixture:1\nevent: stream_end\ndata: {}\n\n', 'text/event-stream')
        if path.endswith('/health'):
            return self.respond(b'{"status":"ok"}')
        if path.endswith('/api/auth/login'):
            return self.respond(b'{"ok":true}')
        return self.respond(b'fixture-only-media', 'application/octet-stream')

    def do_GET(self):
        self.handle_request()

    def do_POST(self):
        self.handle_request(self.rfile.read(int(self.headers.get('Content-Length', '0'))))


def start_redirect_pair():
    servers = [RedirectServer(('127.0.0.1', 0), RedirectFixture) for _ in range(2)]
    for index, server in enumerate(servers):
        server.events = []
        server.other_origin = f'http://127.0.0.1:{servers[1 - index].server_port}'
        threading.Thread(target=server.serve_forever, daemon=True).start()
    return servers


def start(port=0, seed=False, require_headers=False):
    Fixture.sessions = {}
    Fixture.starts = 0
    Fixture.uploaded = False
    Fixture.chat_profiles = []
    Fixture.header_paths = []
    Fixture.require_headers = require_headers
    if seed:
        Fixture.sessions['fixture-welcome'] = {'session_id': 'fixture-welcome', 'title': 'Welcome to the protocol fixture', 'workspace': '/fixture/workspace', 'model': 'fixture-model', 'model_provider': 'fixture', 'messages': [{'role': 'assistant', 'content': '# Native Hermex for Mac\n\nThis is an **explicit test fixture**, not a live Hermes agent.\n\n```swift\nprint("Hello, Mac")\n```'}], 'message_count': 1}
        for sid, title, parent in [
            ('fixture-worker', 'Fixture worker: research', 'fixture-welcome'),
            ('fixture-nested', 'Fixture nested worker: citations', 'fixture-worker'),
            ('fixture-sibling', 'Fixture worker: validation', 'fixture-welcome'),
            ('fixture-orphan', 'Fixture orphan: owner unavailable', 'fixture-missing-owner'),
        ]:
            Fixture.sessions[sid] = {
                'session_id': sid, 'title': title, 'parent_session_id': parent,
                'relationship_type': 'child_session', 'source_tag': 'subagent',
                'raw_source': 'subagent', 'session_source': 'subagent', 'read_only': True,
                'is_streaming': sid == 'fixture-nested',
                'messages': [{'role': 'assistant', 'content': 'Explicit fixture subagent history. No model was called.'}],
                'message_count': 1,
            }
    server = http.server.ThreadingHTTPServer(('127.0.0.1', port), Fixture)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    return server

if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--port', type=int, default=18787)
    parser.add_argument('--require-headers', action='store_true', help='Require public fixture-only Service Token headers on every route')
    args = parser.parse_args()
    server = start(args.port, seed=True, require_headers=args.require_headers)
    print(f'Explicit protocol fixture: http://127.0.0.1:{server.server_port}; password: {PASSWORD}', flush=True)
    try:
        threading.Event().wait()
    except KeyboardInterrupt:
        server.shutdown()
