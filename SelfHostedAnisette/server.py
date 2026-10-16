"""Private, single-user Windows Anisette v3 bridge. No Apple account login code.
ADI blobs exist in RAM during requests; AutoSign persists the returned blob in Keychain.
"""
import asyncio
import base64
import binascii
import json
import os
import re
from pathlib import Path
from aiohttp import web, WSMsgType

ADI_DIR = Path(os.environ['WINEPREFIX']) / 'drive_c/ProgramData/Apple Computer/iTunes/adi'
LOCK = asyncio.Lock()
MAX_SIZE = 1_048_576
CLIENT_INFO = '<PC> <Windows;6.2(0,0);9200> <com.apple.AuthKit/1 (com.apple.iTunes/12.13.11.1)>'
USER_AGENT = 'akd/1.0 CFNetwork/808.1.4'


def validate_identifier(value):
    if not isinstance(value, str) or len(base64.b64decode(value, validate=True)) != 16:
        raise ValueError('invalid identifier')


def clear_blob():
    ADI_DIR.mkdir(parents=True, exist_ok=True, mode=0o700)
    for path in ADI_DIR.iterdir():
        if path.is_file():
            path.unlink()


def export_blob(identifier):
    files = {}
    for path in ADI_DIR.iterdir():
        if path.is_file() and re.fullmatch(r'[A-Za-z0-9_.-]{1,128}', path.name):
            data = path.read_bytes()
            if data:
                files[path.name] = base64.b64encode(data).decode()
    if not files:
        raise ValueError('no provisioning data')
    data = json.dumps({'version': 1, 'identifier': identifier, 'files': files}, separators=(',', ':')).encode()
    if len(data) > MAX_SIZE // 2:
        raise ValueError('provisioning data too large')
    return base64.b64encode(data).decode()


def import_blob(identifier, encoded):
    validate_identifier(identifier)
    if not isinstance(encoded, str) or len(encoded) > MAX_SIZE:
        raise ValueError('invalid blob')
    value = json.loads(base64.b64decode(encoded, validate=True))
    if value.get('version') != 1 or value.get('identifier') != identifier:
        raise ValueError('identity mismatch')
    files = value.get('files', {})
    if not isinstance(files, dict) or not 1 <= len(files) <= 16:
        raise ValueError('invalid files')
    decoded = {}
    for name, encoded in files.items():
        if not re.fullmatch(r'[A-Za-z0-9_.-]{1,128}', name) or name in ('.', '..'):
            raise ValueError('invalid filename')
        decoded[name] = base64.b64decode(encoded, validate=True)
        if len(decoded[name]) > MAX_SIZE // 2:
            raise ValueError('file too large')
    for name, data in decoded.items():
        path = ADI_DIR / name
        path.write_bytes(data)
        path.chmod(0o600)


class Helper:
    async def __aenter__(self):
        self.process = await asyncio.create_subprocess_exec(
            '/usr/lib/wine/wine64', '/opt/autosign/coreadi-helper.exe',
            stdin=asyncio.subprocess.PIPE, stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.DEVNULL, limit=MAX_SIZE)
        return self

    async def __aexit__(self, *args):
        self.process.stdin.close()
        try:
            await asyncio.wait_for(self.process.wait(), 5)
        except asyncio.TimeoutError:
            self.process.kill()
            await self.process.wait()

    async def call(self, *parts):
        if any(not isinstance(p, str) or any(c.isspace() for c in p) for p in parts):
            raise ValueError('invalid command')
        line = ' '.join(parts).encode() + b'\n'
        if len(line) > MAX_SIZE // 2:
            raise ValueError('command too large')
        self.process.stdin.write(line)
        await self.process.stdin.drain()
        value = json.loads(await asyncio.wait_for(self.process.stdout.readline(), 30))
        if not isinstance(value.get('status'), int):
            raise ValueError('invalid helper response')
        return value


@web.middleware
async def private_requests(request, handler):
    # Browsers must not use a website to drive the loopback authentication service.
    if request.headers.get('Origin'):
        raise web.HTTPForbidden()
    return await handler(request)


async def client_info(request):
    return web.json_response({'client_info': CLIENT_INFO, 'user_agent': USER_AGENT})


async def provision(request):
    socket = web.WebSocketResponse(max_msg_size=MAX_SIZE, heartbeat=20)
    await socket.prepare(request)
    async with LOCK:
        clear_blob()
        stage = 'identifier'
        try:
            async with asyncio.timeout(90), Helper() as helper:
                async def receive():
                    message = await socket.receive()
                    if message.type != WSMsgType.TEXT:
                        raise ValueError('unexpected message')
                    return json.loads(message.data)

                await socket.send_json({'result': 'GiveIdentifier'})
                identifier = (await receive())['identifier']
                validate_identifier(identifier)
                stage = 'start'
                await socket.send_json({'result': 'GiveStartProvisioningData'})
                spim = (await receive())['spim']
                value = await helper.call('start', spim)
                if value['status'] < 0:
                    print('windows-start-status', value['status'], flush=True)
                    raise ValueError('provisioning start failed')
                await socket.send_json({'result': 'GiveEndProvisioningData', 'cpim': value['cpim']})
                stage = 'finish'
                end = await receive()
                routing = end.get('X-Apple-I-MD-RINFO')
                if not isinstance(routing, str) or not routing.isdecimal():
                    raise ValueError('missing Apple routing info')
                value = await helper.call('finish', str(value['session']), end['ptm'], end['tk'], routing)
                if value['status'] < 0:
                    print('windows-finish-status', value['status'], flush=True)
                    raise ValueError('provisioning finish failed')
                blob = export_blob(identifier)
                await socket.send_json({'result': 'ProvisioningSuccess', 'adi_pb': blob})
        except (ValueError, KeyError, TypeError, binascii.Error, asyncio.TimeoutError, BrokenPipeError) as error:
            print('windows-provisioning-failure', stage, type(error).__name__, flush=True)
            await socket.send_json({'result': 'ProvisioningError'})
        finally:
            clear_blob()
    await socket.close()
    return socket


async def get_headers(request):
    async with LOCK:
        clear_blob()
        try:
            value = await request.json()
            identifier = value['identifier']
            import_blob(identifier, value['adi_pb'])
            async with asyncio.timeout(45), Helper() as helper:
                parts = ['headers']
                if value.get('sim'):
                    parts.append(value['sim'])
                result = await helper.call(*parts)
                if result['status'] < 0:
                    return web.json_response({'result': 'GetHeadersError', 'message': str(result['status'])})
                result.pop('status')
                if value.get('sim'):
                    result['adi_pb'] = export_blob(identifier)
                return web.json_response(result)
        except (ValueError, KeyError, TypeError, binascii.Error, asyncio.TimeoutError, BrokenPipeError):
            return web.json_response({'result': 'GetHeadersError'}, status=400)
        finally:
            clear_blob()


app = web.Application(client_max_size=MAX_SIZE, middlewares=[private_requests])
app.add_routes([web.get('/v3/client_info', client_info), web.get('/v3/provisioning_session', provision),
                web.post('/v3/get_headers', get_headers)])
if __name__ == '__main__':
    web.run_app(app, host='0.0.0.0', port=6969, access_log=None, print=None)
