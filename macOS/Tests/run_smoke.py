#!/usr/bin/env python3
"""Exercise legacy and required-header paths against explicit loopback fixtures."""
import os
import pathlib
import subprocess
import sys
import urllib.error
import urllib.request
from protocol_fixture import Fixture, FIXTURE_HEADERS, start, start_redirect_pair

binary = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else '.build/debug/Hermex').resolve()
env = {key: os.environ[key] for key in ('HOME', 'PATH', 'TMPDIR') if key in os.environ}
for require_headers in (False, True):
    server = start(require_headers=require_headers)
    Fixture.fail_next_stream = True
    address = f'http://127.0.0.1:{server.server_port}'
    try:
        if require_headers:
            # A missing token must be rejected even on /health, before fixture detection.
            try:
                urllib.request.urlopen(address + '/health')
                raise AssertionError('Header gate did not protect /health')
            except urllib.error.HTTPError as error:
                assert error.code == 403
        flag = '--protocol-smoke-headers' if require_headers else '--protocol-smoke'
        result = subprocess.run([str(binary), flag, address], text=True, capture_output=True, timeout=45, env=env)
        print(result.stdout)
        print(result.stderr, file=sys.stderr)
        assert result.returncode == 0, f'Smoke exited {result.returncode}'
        assert 'FIXTURE SMOKE PASSED' in result.stdout, 'App did not run its pipeline'
        assert Fixture.starts == 1, f'Reattach resent a message ({Fixture.starts} starts)'
        assert Fixture.chat_profiles == ['default'], 'New-session profile leaked into an existing conversation'
        assert Fixture.uploaded, 'Multipart upload was not exercised'
        assert not Fixture.sessions, 'Disposable fixture session was not cleaned up'
        if require_headers:
            seen = set(Fixture.header_paths)
            required = {('GET', '/health'), ('GET', '/api/auth/status'), ('POST', '/api/auth/login'), ('GET', '/api/sessions'), ('POST', '/api/upload'), ('GET', '/api/chat/stream'), ('GET', '/api/chat/cancel'), ('POST', '/api/approval/respond'), ('POST', '/api/clarify/respond'), ('POST', '/api/auth/logout')}
            assert required <= seen, f'Missing required-header routes: {required - seen}'
            assert Fixture.header_paths.count(('GET', '/api/chat/stream')) == 2, 'Initial/replay SSE did not both pass the header gate'
        mode = 'required Service Token + custom headers' if require_headers else 'legacy no-header compatibility'
        print(f'PASS ({mode}): real app auth/session/upload/SSE interrupt+replay/panels/logout; exactly one chat start; fixture cleaned.')
    finally:
        server.shutdown()
        server.server_close()

servers = start_redirect_pair()
try:
    addresses = [f'http://127.0.0.1:{server.server_port}' for server in servers]
    result = subprocess.run([str(binary), '--header-redirect-smoke', *addresses], text=True, capture_output=True, timeout=45, env=env)
    print(result.stdout)
    print(result.stderr, file=sys.stderr)
    assert result.returncode == 0, f'Redirect smoke exited {result.returncode}'
    assert 'FIXTURE REDIRECT SMOKE PASSED' in result.stdout
    same = [event for event in servers[0].events if event['path'].startswith('/capture/')]
    cross = [event for event in servers[1].events if event['path'].startswith('/capture/')]
    expected = {'/capture/health', '/capture/api/file/raw', '/capture/media', '/capture/api/chat/stream'}
    assert {event['path'] for event in same} == expected | {'/capture/api/auth/login'}
    assert {event['path'] for event in cross} == expected | {'/capture/external-media'}
    for event in same:
        fields = {key.lower(): value for key, value in event['headers'].items()}
        assert all(fields.get(name.lower()) == value for name, value in FIXTURE_HEADERS.items()), f'Same-origin headers missing at {event["path"]}'
        if event['path'].endswith('/health'):
            assert fields.get('accept') == 'application/json'
        if event['path'].endswith('/api/chat/stream'):
            assert fields.get('accept') == 'text/event-stream'
        if event['method'] == 'POST':
            assert fields.get('content-type') == 'application/json'
            assert b'fixture-only-password' in event['body']
    for event in cross:
        fields = {key.lower(): value for key, value in event['headers'].items()}
        assert all(name.lower() not in fields for name in FIXTURE_HEADERS), f'Custom headers leaked to second origin at {event["path"]}'
        assert event['method'] == 'GET' and not event['body'], 'Credential POST reached second origin'
    print('PASS (two real loopback origins): same-origin headers preserved; JSON, bounded/media, SSE and external media stripped off-origin; 307 password POST blocked; built-in Accept/Content-Type win.')
finally:
    for server in servers:
        server.shutdown()
        server.server_close()
