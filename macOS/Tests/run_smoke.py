#!/usr/bin/env python3
"""Run the actual app's headless pipeline against an explicit local fixture."""
import pathlib
import subprocess
import sys
from protocol_fixture import Fixture, PASSWORD, start

binary = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else '.build/debug/Hermex').resolve()
server = start()
Fixture.fail_next_stream = True
try:
    result = subprocess.run([str(binary), '--protocol-smoke', f'http://127.0.0.1:{server.server_port}'], text=True, capture_output=True, timeout=45)
    # The only password in this test is an explicit public fixture constant in Swift.
    print(result.stdout)
    print(result.stderr, file=sys.stderr)
    assert result.returncode == 0, f'Smoke exited {result.returncode}'
    assert 'FIXTURE SMOKE PASSED' in result.stdout, 'App did not run its pipeline'
    assert Fixture.starts == 1, f'Reattach resent a message ({Fixture.starts} starts)'
    assert Fixture.chat_profiles == ['default'], 'New-session profile leaked into an existing conversation'
    assert Fixture.uploaded, 'Multipart upload was not exercised'
    assert not Fixture.sessions, 'Disposable fixture session was not cleaned up'
    print('PASS: real app networking, auth, session lifecycle, upload, interrupted SSE/replay; exactly one chat start; fixture cleaned.')
finally:
    server.shutdown()
    server.server_close()
