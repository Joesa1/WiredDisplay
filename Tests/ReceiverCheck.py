"""Run against a locally started receiver; the pairing code is never logged."""
import argparse
import json
import socket
import struct
import time

parser = argparse.ArgumentParser()
parser.add_argument('address')
parser.add_argument('code')
args = parser.parse_args()

def connect():
    return socket.create_connection((args.address, 54321), timeout=7)

def packet(sock, kind, payload=b''):
    sock.sendall(struct.pack('!I', len(payload) + 1) + bytes([kind]) + payload)

def exact(sock, count):
    result = b''
    while len(result) < count:
        chunk = sock.recv(count - len(result))
        assert chunk, 'Unexpected EOF'
        result += chunk
    return result

def read(sock):
    count, = struct.unpack('!I', exact(sock, 4))
    assert 0 < count <= 16 * 1024 * 1024
    body = exact(sock, count)
    return body[0], body[1:]

def hello(sock, code, probe, version=1):
    packet(sock, 1, json.dumps(dict(version=version, code=code, appVersion='0.2.0', probe=probe)).encode())

def probe():
    with connect() as sock:
        hello(sock, args.code, True)
        kind, data = read(sock)
        assert kind == 2, (kind, data)
        profile = json.loads(data)
        assert profile['width'] >= 640 and profile['height'] >= 480
        assert sock.recv(1) == b''
    return profile

with connect() as sock:
    hello(sock, 'invalid', False)
    kind, data = read(sock)
    assert kind == 8 and '配对码' in data.decode()
print('PASS: wrong code returns explicit rejection')
with connect() as sock:
    hello(sock, args.code, True, version=999)
    kind, data = read(sock)
    assert kind == 8 and '协议' in data.decode()
print('PASS: incompatible protocol rejected')
idle = connect()
with connect() as malformed:
    malformed.sendall(b'\xff\xff\xff\xff')
    assert malformed.recv(1) == b''
profile = probe()
print('PASS: valid probe after malformed and idle connections', profile)
time.sleep(5.3)
assert idle.recv(1) == b''
idle.close()
print('PASS: idle candidate expires without stopping listener')
with connect() as active:
    hello(active, args.code, False)
    assert read(active)[0] == 2
    # A malformed/early cursor is best-effort and must not end the video session.
    packet(active, 6, b'{"x":9999}')
    packet(active, 7)
    assert read(active)[0] == 7
    print('PASS: invalid early cursor does not interrupt the session')
    probe()
    packet(active, 7)
    assert read(active)[0] == 7
    print('PASS: diagnostic probe preserves active session')
    with connect() as replacement:
        hello(replacement, args.code, False)
        assert read(replacement)[0] == 2
        assert active.recv(1) == b''
        packet(replacement, 7)
        assert read(replacement)[0] == 7
        print('PASS: authenticated newcomer replaces old connection')
probe()
print('PASS: listener survives disconnect and accepts reconnection')
