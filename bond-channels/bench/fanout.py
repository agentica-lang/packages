"""Measures the cable: the memory of the server per open WebSocket, and the fan-out of its hub.

    python3 bench/fanout.py [--sockets N] [--messages M] [--payload BYTES]

It starts specs/fixtures/server.agc, opens N WebSockets that subscribe to one room (one raw-socket client, one asyncio
task each), and reads the resident memory of the server before and after (memory per socket). Then it broadcasts M
messages through `GET /say` and times how long it takes for every socket to read all of them (frames per second, and
messages per second for the hub, which is one task). It also prints the CPU time of the server per frame, which does
not depend on the speed of this client. It is run by hand: the numbers depend on the machine.
"""
import argparse
import asyncio
import base64
import os
import struct
import subprocess
import time

ROOM = '{"channel":"RoomChannel","room":"1"}'
MARK = b'"message":"'


def rss_kib(pid):
    with open("/proc/%d/status" % pid) as status:
        return next(int(line.split()[1]) for line in status if line.startswith("VmRSS:"))


def cpu_seconds(pid):
    """User plus system CPU time of a process: the cost of the server, whatever the speed of this client."""
    with open("/proc/%d/stat" % pid) as stat:
        fields = stat.read().rsplit(")", 1)[1].split()
    return (int(fields[11]) + int(fields[12])) / os.sysconf("SC_CLK_TCK")


def frame(opcode, payload):
    key = os.urandom(4)
    head = bytes([128 | opcode, 128 | len(payload)]) if len(payload) < 126 else bytes([128 | opcode, 254]) + struct.pack(">H", len(payload))
    return head + key + bytes(byte ^ key[place % 4] for place, byte in enumerate(payload))


async def client(port, user, ready, counts, index, errors):
    reader, writer = await asyncio.open_connection("127.0.0.1", port)
    key = base64.b64encode(os.urandom(16)).decode()
    writer.write(("GET /cable HTTP/1.1\r\nHost: 127.0.0.1\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
                  "Sec-WebSocket-Version: 13\r\nSec-WebSocket-Key: %s\r\nSec-WebSocket-Protocol: actioncable-v1-json\r\n"
                  "Cookie: user=%s\r\n\r\n" % (key, user)).encode())
    await reader.readuntil(b"\r\n\r\n")
    command = '{"command":"subscribe","identifier":%s}' % ('"' + ROOM.replace('"', '\\"') + '"')
    writer.write(frame(1, command.encode()))
    confirmed = False
    try:
        while True:
            first, second = await reader.readexactly(2)
            size = second & 127
            if size == 126:
                size = struct.unpack(">H", await reader.readexactly(2))[0]
            elif size == 127:
                size = struct.unpack(">Q", await reader.readexactly(8))[0]
            payload = await reader.readexactly(size)
            opcode = first & 15
            if opcode == 9:
                writer.write(frame(10, payload))
            elif opcode == 1 and b"confirm_subscription" in payload and not confirmed:
                confirmed = True
                ready.append(index)
            elif opcode == 1 and MARK in payload:
                counts[index] += 1
    except (asyncio.IncompleteReadError, ConnectionError) as error:
        errors.append(repr(error))


async def main():
    arguments = argparse.ArgumentParser()
    arguments.add_argument("--sockets", type=int, default=500)
    arguments.add_argument("--messages", type=int, default=200)
    arguments.add_argument("--payload", type=int, default=200)
    options = arguments.parse_args()
    here = os.path.dirname(os.path.abspath(__file__))
    env = dict(os.environ, MAX_CONNECTIONS=str(options.sockets + 16))
    server = subprocess.Popen(["agentica", os.path.join(here, "..", "specs", "fixtures", "server.agc")], env=env,
                              stdout=subprocess.PIPE, text=True)
    port = int(server.stdout.readline().split()[-1])
    try:
        await asyncio.sleep(0.5)
        before = rss_kib(server.pid)
        ready, counts, errors = [], [0] * options.sockets, []
        tasks = [asyncio.create_task(client(port, "u%d" % n, ready, counts, n, errors)) for n in range(options.sockets)]
        while len(ready) < options.sockets and not errors:
            await asyncio.sleep(0.05)
        await asyncio.sleep(1)
        after = rss_kib(server.pid)
        print("sockets %d: RSS %d KiB -> %d KiB, %.1f KiB per socket" % (
            options.sockets, before, after, (after - before) / options.sockets))
        body = "x" * options.payload
        cpu_before = cpu_seconds(server.pid)
        started = time.monotonic()
        reader, writer = await asyncio.open_connection("127.0.0.1", port)
        for number in range(options.messages):
            writer.write(("GET /say?topic=room:1&text=%s%d HTTP/1.1\r\nHost: x\r\n\r\n" % (body, number)).encode())
            await writer.drain()
            await reader.readuntil(b"sent")
        while min(counts) < options.messages and not errors:
            await asyncio.sleep(0.01)
        elapsed = time.monotonic() - started
        total = sum(counts)
        cpu = cpu_seconds(server.pid) - cpu_before
        print("%d messages x %d sockets in %.2f s: %.0f messages/s, %.0f frames/s, errors %d" % (
            options.messages, options.sockets, elapsed, options.messages / elapsed, total / elapsed, len(errors)))
        print("server CPU %.2f s for the broadcasts: %.1f us per frame" % (cpu, cpu * 1e6 / max(total, 1)))
        writer.write(b"GET /stats HTTP/1.1\r\nHost: x\r\n\r\n")
        await writer.drain()
        stats = (await reader.readuntil(b"}")).decode()
        print("stats %s" % stats[stats.index("{"):])
        for task in tasks:
            task.cancel()
    finally:
        server.terminate()


asyncio.run(main())
