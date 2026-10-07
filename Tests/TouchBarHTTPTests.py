#!/usr/bin/env python3
"""Exercise the real listener with a non-operating native provider."""
import http.client
import json
import pathlib
import subprocess
import sys
import socket
import time
import urllib.parse

root = pathlib.Path(__file__).resolve().parents[1]
executable = root / 'build' / 'TouchBarServiceTests'
executable.parent.mkdir(exist_ok=True)
subprocess.run(['xcrun', 'swiftc', '-swift-version', '5', str(root / 'Sources/TouchBarHTTP.swift'), str(root / 'Sources/TouchBarService.swift'), str(root / 'Tests/TouchBarServiceHarness.swift'), '-o', str(executable), '-framework', 'AppKit', '-framework', 'CoreImage'], check=True)
process = subprocess.Popen([str(executable)], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
try:
    status = json.loads(process.stdout.readline())
    port = urllib.parse.urlparse(status['url']).port
    host = f'127.0.0.1:{port}'
    def request(path, body=None, headers=None, method=None):
        connection = http.client.HTTPConnection('127.0.0.1', port, timeout=12)
        all_headers = {'Host': host, 'Content-Type': 'application/json'}
        all_headers.update(headers or {})
        connection.request(method or ('POST' if body is not None else 'GET'), path,
                           json.dumps(body) if isinstance(body, dict) else body, all_headers)
        response = connection.getresponse()
        data = response.read()
        connection.close()
        return response.status, json.loads(data) if data else {}
    def raw(message):
        with socket.create_connection(('127.0.0.1', port), timeout=12) as client:
            client.sendall(message)
            return client.recv(4096)
    assert b'400' in raw(f'GET / HTTP/1.1\r\nHost: {host}\r\nHost: {host}\r\n\r\n'.encode())
    assert b'400' in raw(f'POST /api/pair HTTP/1.1\r\nHost: {host}\r\nTransfer-Encoding: chunked\r\n\r\n0\r\n\r\n'.encode())
    assert b'400' in raw(f'GET /{"x" * 2049} HTTP/1.1\r\nHost: {host}\r\n\r\n'.encode())
    assert b'431' in raw(f'GET / HTTP/1.1\r\nHost: {host}\r\nX-Large: {"x" * 8200}\r\n\r\n'.encode())
    slow = socket.create_connection(('127.0.0.1', port), timeout=12)
    slow.sendall(b'GET / HTTP/1.1\r\n')
    started = time.monotonic()
    assert slow.recv(10) == b''
    assert time.monotonic() - started < 12
    slow.close()
    assert request('/api/state')[0] == 401
    assert request('/api/pair', {'code': 'bad'})[0] == 401
    assert request('/api/pair', {'code': status['code']}, {'Host': 'evil.example'})[0] == 403
    assert request('/api/pair', {'code': status['code']}, {'Origin': 'http://evil.example'})[0] == 403
    assert request('/api/pair', '{broken')[0] == 400
    assert request('/api/pair', 'x' * 5000)[0] == 413
    code, paired = request('/api/pair', {'code': status['code']})
    assert code == 200
    auth = {'Authorization': 'Bearer ' + paired['token']}
    assert request('/api/state', headers=auth)[0] == 200
    assert request('/api/command', {'action': 'shell.exec'}, auth)[0] == 400
    assert request('/api/command', {'action': 'volume.set', 'value': -1}, auth)[0] == 400
    assert request('/api/command', {'action': 'volume.set', 'value': True}, auth)[0] == 400
    assert request('/api/command', headers=auth)[0] == 404
    assert request('/api/command', {'action': 'volume.set', 'value': 40}, auth)[0] == 200
    for _ in range(4): assert request('/api/pair', {'code': 'bad'})[0] == 401
    assert request('/api/pair', {'code': status['code']})[0] == 429
    process.stdin.write('reset\n'); process.stdin.flush()
    renewed = json.loads(process.stdout.readline())
    assert renewed['code'] != status['code']
    assert request('/api/state', headers=auth)[0] == 401
    process.stdin.write('disable\n'); process.stdin.flush()
    assert json.loads(process.stdout.readline())['enabled'] is False
    try:
        request('/api/state')
        raise AssertionError('Listener survived shutdown')
    except (ConnectionError, OSError): pass
    print('PASS: pairing, authentication, revocation, rate limits, request validation, commands and shutdown')
finally:
    process.stdin.close()
    process.wait(timeout=15)
