"""Real stdio SDK handshake and tool/resource calls against a controlled HTTP archive."""
import asyncio
import json
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import sys
from threading import Thread

from mcp import ClientSession, StdioServerParameters
from mcp.client.stdio import stdio_client

ID = '00000000-0000-4000-8000-000000000001'


def test_stdio_session_exposes_only_read_tools_and_quotes(tmp_path):
    seen = []
    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *args): pass
        def do_GET(self): self.respond()
        def do_POST(self): self.respond()
        def respond(self):
            assert self.headers['Authorization'] == 'Bearer omilocal_archive_' + 'R' * 43
            body = json.loads(self.rfile.read(int(self.headers.get('Content-Length', 0))) or b'{}')
            seen.append((self.command, self.path, body))
            assert self.path in {'/v1/local/archive/recordings', '/v1/local/archive/read', '/v1/local/conversations/search'}
            if self.path.endswith('/read'):
                assert body['id'] == ID
                result = {'id': ID, 'revision': 'revision', 'citations': [{'segment_id': 'line',
                          'text': 'The agreed budget was 24000 euros.', 'start_seconds': 12}], 'next': None}
            else:
                result = {'items': [{'id': ID, 'title': 'Budget meeting'}], 'next_cursor': None}
            payload = json.dumps(result).encode()
            self.send_response(200)
            self.send_header('Content-Length', str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)
    http = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
    thread = Thread(target=http.serve_forever, daemon=True)
    thread.start()
    config = tmp_path / 'client.json'
    config.write_text(json.dumps({'version': 1, 'origin': f'http://127.0.0.1:{http.server_port}', 'archive_read_key': 'omilocal_archive_' + 'R' * 43}))
    config.chmod(0o600)
    async def exercise():
        params = StdioServerParameters(command=sys.executable,
            args=[str(Path(__file__).with_name('server.py')), '--config', str(config)])
        async with stdio_client(params) as (read, write):
            async with ClientSession(read, write) as session:
                await session.initialize()
                tools = (await session.list_tools()).tools
                assert {tool.name for tool in tools} == {'get_conversations', 'get_conversation_by_id', 'search_conversations', 'get_quote'}
                assert all(tool.annotations.read_only_hint and not tool.annotations.destructive_hint for tool in tools)
                for name, arguments in [
                    ('get_conversations', {}), ('search_conversations', {'query': 'budget'}),
                    ('get_conversation_by_id', {'recording_id': ID}),
                    ('get_quote', {'recording_id': ID, 'segment_id': 'line'}),
                ]:
                    result = await session.call_tool(name, arguments)
                    assert not result.is_error, result
                    assert 'R' * 43 not in result.model_dump_json()
                resource = await session.read_resource(f'omi-local://recording/{ID}')
                assert '24000' in resource.model_dump_json()
                rejected = await session.call_tool('get_quote', {'recording_id': '../admin', 'segment_id': 'line'})
                assert rejected.is_error and 'Bearer' not in rejected.model_dump_json()
                unknown = await session.call_tool('delete_recording', {'recording_id': ID})
                assert unknown.is_error
    try:
        asyncio.run(exercise())
        assert len(seen) == 5
    finally:
        http.shutdown()
        http.server_close()
        thread.join(2)
