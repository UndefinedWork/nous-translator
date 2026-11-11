#!/usr/bin/env python3
"""Measure local GGUF process startup and real SSE latency; never calls a cloud API."""
import argparse
import json
import os
from pathlib import Path
import socket
import subprocess
import tempfile
import time
import urllib.error
import urllib.request
import uuid


def benchmark(binary, model, runs, extra_arguments):
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    results = []
    prompts = [("zh-en", "请将以下文本翻译为英语，直接输出翻译结果，不要进行任何解释。\n\n我们明天下午三点开会。"),
               ("en-zh", "请将以下文本翻译为简体中文，直接输出翻译结果，不要进行任何解释。\n\nCould you send me the updated design before Friday?")]
    for run in range(runs):
        with socket.socket() as listener:
            listener.bind(('127.0.0.1', 0))
            port = listener.getsockname()[1]
        key = uuid.uuid4().hex
        base = f'http://127.0.0.1:{port}'
        args = [str(binary), '-m', str(model), '--host', '127.0.0.1', '--port', str(port),
                '--alias', 'Index-Translate-2B', '--api-key', key, '-ngl', '99', '-c', '16384',
                '--parallel', '1', '--jinja', '--chat-template-kwargs', '{"enable_thinking":false}',
                *extra_arguments]
        with tempfile.TemporaryFile(mode='w+') as log:
            started = time.monotonic()
            process = subprocess.Popen(args, stdout=log, stderr=subprocess.STDOUT,
                                       env={**os.environ, 'GGML_BACKEND_PATH': str(binary.parent)})
            record = {'run': run + 1, 'requests': []}
            try:
                while time.monotonic() - started < 150:
                    if process.poll() is not None:
                        log.seek(0)
                        raise RuntimeError('Runtime exited: ' + log.read()[-3000:])
                    try:
                        with opener.open(urllib.request.Request(base + '/health', headers={'Authorization': 'Bearer ' + key}), timeout=1) as response:
                            if response.status == 200:
                                break
                    except (OSError, urllib.error.HTTPError):
                        time.sleep(0.05)
                else:
                    raise TimeoutError('Runtime did not become healthy')
                record['health_ready_seconds'] = round(time.monotonic() - started, 3)
                for index, (direction, prompt) in enumerate(prompts):
                    sent = time.monotonic()
                    request = urllib.request.Request(base + '/v1/chat/completions',
                        data=json.dumps({'model': 'Index-Translate-2B', 'messages': [{'role': 'user', 'content': prompt}],
                                         'stream': True, 'temperature': 0, 'max_tokens': 256,
                                         'chat_template_kwargs': {'enable_thinking': False}}).encode(),
                        headers={'Authorization': 'Bearer ' + key, 'Content-Type': 'application/json'})
                    first = None
                    text = ''
                    done = False
                    with opener.open(request, timeout=120) as response:
                        headers = time.monotonic() - sent
                        for raw in response:
                            line = raw.decode().strip()
                            if line == 'data: [DONE]':
                                done = True
                                break
                            if not line.startswith('data: '):
                                continue
                            event = json.loads(line[6:])
                            for choice in event.get('choices', []):
                                chunk = choice.get('delta', {}).get('content') or ''
                                if chunk and first is None:
                                    first = time.monotonic() - sent
                                text += chunk
                    if not done or not text.strip():
                        raise RuntimeError('Incomplete response')
                    record['requests'].append({'direction': direction, 'request': 'first' if index == 0 else 'warm',
                        'headers_seconds': round(headers, 3), 'first_token_seconds': round(first, 3),
                        'total_seconds': round(time.monotonic() - sent, 3), 'text': text.strip()})
            finally:
                if process.poll() is None:
                    process.terminate()
                try:
                    process.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait()
            record['owned_process_stopped'] = True
            results.append(record)
    return {'binary': str(binary), 'model': model.name, 'context_tokens': 16384,
            'note': 'Fresh processes; filesystem/Metal caches are intentionally not purged.',
            'runs': results}


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary', required=True, type=Path)
    parser.add_argument('--model', type=Path, default=Path.home() / 'Library/Application Support/Nous Translator/Index-Translate-2B.Q4_K_M.gguf')
    parser.add_argument('--runs', type=int, default=2)
    parser.add_argument('--output', type=Path)
    parser.add_argument('--no-warmup', action='store_true', help='Diagnostic comparison only; does not change app settings')
    args = parser.parse_args()
    result = benchmark(args.binary.resolve(), args.model.resolve(), args.runs, ['--no-warmup'] if args.no_warmup else [])
    text = json.dumps(result, ensure_ascii=False, indent=2) + '\n'
    if args.output:
        args.output.write_text(text)
    print(text)
