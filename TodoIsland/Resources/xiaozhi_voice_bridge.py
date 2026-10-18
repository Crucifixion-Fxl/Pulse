#!/usr/bin/env python3
"""Pulse's private stdio voice worker. Requires the user's bound py-xiaozhi runtime.

No listening TCP port, transcript persistence, tool execution, or credentials on
stdout. Closing stdin or terminating the parent closes the microphone and socket.
"""
import asyncio
import fcntl
import json
import logging
import math
import os
from pathlib import Path
import signal
import sys
import time


def emit(kind, **fields):
    print(json.dumps({"type": kind, **fields}, ensure_ascii=False), flush=True)


def normalized_level(rms):
    if not math.isfinite(rms) or rms <= 0.003:
        return 0.0
    return min(1.0, max(0.0, (20 * math.log10(rms) + 50) / 35))


async def run(runtime, data_dir):
    # Import only the transport and audio components, never the client's MCP or UI.
    sys.path.insert(0, str(runtime))
    os.environ['XIAOZHI_DATA_DIR'] = str(data_dir)
    logging.disable(logging.CRITICAL)
    from src.utils.opus_loader import setup_opus
    setup_opus()
    from src.utils.config_manager import initialize_config
    from src.activation.service import ActivationService
    from src.protocols.websocket_protocol import WebsocketProtocol
    from src.audio_codecs.audio_codec import AudioCodec
    from src.constants.constants import ListeningMode
    import numpy as np

    class MeteredCodec(AudioCodec):
        input_rms = 0.0
        output_rms = 0.0

        def on_audio_data(self, samples):
            self.input_rms = float(np.sqrt(np.mean(samples * samples)))

        def _output_callback(self, outdata, frames, timing, status):
            super()._output_callback(outdata, frames, timing, status)
            # Meter the PCM actually being played, not network arrival bursts.
            self.output_rms = float(np.sqrt(np.mean(outdata * outdata)))

    stop = asyncio.Event()
    loop = asyncio.get_running_loop()
    for sig in (signal.SIGTERM, signal.SIGINT):
        loop.add_signal_handler(sig, stop.set)
    loop.add_reader(sys.stdin.fileno(), lambda: stop.set() if not os.read(sys.stdin.fileno(), 4096) else None)
    config = initialize_config()
    codec = None
    protocol = None
    tasks = []
    state = 'connecting'
    ready = False
    shutting_down = False
    incoming = asyncio.Queue(maxsize=300)
    outgoing = asyncio.Queue(maxsize=25)  # At most half a second of microphone data.
    last_activity = time.monotonic()

    def set_state(value):
        nonlocal state
        if state != value:
            state = value
            emit('state', state=value)

    def fail(code):
        if not shutting_down:
            emit('error', code=code)
            stop.set()

    def enqueue_audio(packet):
        if not ready or stop.is_set():
            return
        if outgoing.full():
            outgoing.get_nowait()
        outgoing.put_nowait(packet)

    def receive(data):
        if incoming.full():
            fail('audio_backlog')
        else:
            incoming.put_nowait(data)

    async def consume():
        nonlocal last_activity
        while not stop.is_set():
            message = await incoming.get()
            if isinstance(message, bytes):
                await codec.write_audio(message)
                continue
            kind = message.get('type')
            if kind == 'mcp':
                payload = message.get('payload', {})
                ident = payload.get('id')
                method = payload.get('method')
                if ident is None:
                    continue
                response = {'jsonrpc': '2.0', 'id': ident}
                if method == 'initialize':
                    response['result'] = {'protocolVersion': '2024-11-05', 'capabilities': {'tools': {}},
                        'serverInfo': {'name': 'pulse-voice', 'version': '1'}}
                elif method == 'tools/list':
                    response['result'] = {'tools': []}
                else:
                    response['error'] = {'code': -32601, 'message': 'No tools exposed'}
                await protocol.send_text(json.dumps({'type': 'mcp', 'session_id': protocol.session_id, 'payload': response}))
            elif kind == 'stt':
                last_activity = time.monotonic()
                set_state('thinking')
            elif kind == 'tts':
                last_activity = time.monotonic()
                if message.get('state') == 'start':
                    await codec.clear_audio_queue()
                    set_state('speaking')
                elif message.get('state') == 'stop':
                    # Do not report listening until the final PCM is actually heard.
                    deadline = time.monotonic() + 12
                    while codec._tts_fifo.size and time.monotonic() < deadline and not stop.is_set():
                        await asyncio.sleep(.02)
                    await asyncio.sleep(.08)
                    if not stop.is_set():
                        set_state('listening')
                        await protocol.send_start_listening(ListeningMode.REALTIME if codec.aec_active else ListeningMode.AUTO_STOP)
            elif kind in ('alert', 'error'):
                # Server prose may contain private information; expose a stable UI code.
                fail('server_alert')
            elif kind == 'goodbye':
                fail('disconnected')

    async def send_audio():
        while not stop.is_set():
            packet = await outgoing.get()
            # AEC is required for simultaneous mic + speaker; otherwise half-duplex.
            if state == 'listening' or codec.aec_active:
                await protocol.send_audio(packet)

    async def meters():
        while not stop.is_set():
            emit('level', input=normalized_level(codec.input_rms), output=normalized_level(codec.output_rms))
            if time.monotonic() - last_activity > 180:
                fail('idle_timeout')
            await asyncio.sleep(1 / 30)

    async def setup():
        nonlocal codec, protocol, ready
        # Never create a replacement identity silently when setup is missing.
        if not config.get_config('SYSTEM_OPTIONS.DEVICE_ID'):
            fail('not_bound')
            return
        activation = await ActivationService.create()
        result = await activation.initialize()
        if not result.get('success') or result.get('need_activation_ui'):
            fail('not_bound')
            return
        codec = MeteredCodec()
        codec.add_audio_listener(codec)
        await codec.initialize()
        protocol = WebsocketProtocol()
        protocol.on_incoming_json(receive)
        protocol.on_incoming_audio(receive)
        protocol.on_audio_channel_closed(lambda: fail('disconnected'))
        async def network_error(_):
            fail('network')
        protocol.on_network_error(network_error)
        if not await protocol.connect():
            fail('network')
            return
        await protocol.send_start_listening(ListeningMode.REALTIME if codec.aec_active else ListeningMode.AUTO_STOP)
        ready = True
        codec.set_encoded_callback(lambda packet: loop.call_soon_threadsafe(enqueue_audio, packet))
        set_state('listening')
        tasks.extend(asyncio.create_task(fn()) for fn in (consume, send_audio, meters))
        for task in tasks:
            task.add_done_callback(lambda t: fail('audio') if not t.cancelled() and t.exception() else None)

    try:
        emit('state', state='connecting')
        setup_task = asyncio.create_task(setup())
        stop_task = asyncio.create_task(stop.wait())
        done, _ = await asyncio.wait([setup_task, stop_task], timeout=25, return_when=asyncio.FIRST_COMPLETED)
        if stop_task in done:
            setup_task.cancel()
        elif setup_task not in done:
            fail('timeout')
            setup_task.cancel()
        else:
            await setup_task
            await stop.wait()
        await asyncio.gather(setup_task, return_exceptions=True)
        stop_task.cancel()
        await asyncio.gather(stop_task, return_exceptions=True)
    except Exception:
        fail('unavailable')
    finally:
        shutting_down = True
        ready = False
        for task in tasks:
            task.cancel()
        await asyncio.gather(*tasks, return_exceptions=True)
        if codec:
            codec.set_encoded_callback(None)
            await codec.close()
        if protocol:
            await protocol.close_audio_channel()
        loop.remove_reader(sys.stdin.fileno())
        emit('state', state='stopped')


def main():
    if len(sys.argv) != 3:
        return 2
    runtime, data_dir = map(Path, sys.argv[1:])
    if not (data_dir / 'config' / 'config.json').is_file():
        emit('error', code='not_bound')
        return 1
    # Multiple wake invocations must never capture at the same time.
    with (data_dir / 'pulse-voice.lock').open('w') as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            emit('error', code='busy')
            return 1
        try:
            asyncio.run(run(runtime, data_dir))
        except (BrokenPipeError, KeyboardInterrupt):
            pass
        except Exception:
            emit('error', code='unavailable')
            return 1
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
