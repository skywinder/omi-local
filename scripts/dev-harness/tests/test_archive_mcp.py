"""MCP adapter read boundary and explicit credential lifecycle, without SDK dependencies."""
import hashlib
import json
import os
from pathlib import Path
import sys

import httpx
import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[3] / 'tools' / 'archive-mcp'))
from archive_client import ArchiveClient, ArchiveError, origin, private_json
from archive_access import grant, revoke


@pytest.fixture
def config(tmp_path):
    path = tmp_path / 'client.json'
    path.write_text(json.dumps({'version': 1, 'origin': 'http://100.64.0.1:20000', 'archive_read_key': 'omilocal_archive_' + 'R' * 43}))
    path.chmod(0o600)
    return path


def test_client_uses_only_fixed_read_paths_no_redirects_and_no_secret_errors(config):
    calls = []
    def handle(request):
        calls.append(request)
        assert request.headers['Authorization'] == 'Bearer omilocal_archive_' + 'R' * 43
        assert 'R' * 43 not in str(request.url)
        return httpx.Response(200, json={'items': [], 'next_cursor': 'continue'})
    client = ArchiveClient(config, transport=httpx.MockTransport(handle))
    assert client.list()['next_cursor'] == 'continue'
    client.search('test', after='cursor')
    client.read('00000000-0000-4000-8000-000000000001')
    assert [(req.method, req.url.path) for req in calls] == [
        ('GET', '/v1/local/archive/recordings'), ('POST', '/v1/local/conversations/search'), ('POST', '/v1/local/archive/read')]
    with pytest.raises(ArchiveError): client.read('../admin')
    with pytest.raises(ArchiveError): client.read('00000000-0000-4000-8000-000000000001', start_segment=1)
    with pytest.raises(ArchiveError): client.search('test', mode='delete')
    payload = private_json(config)
    config.write_text(json.dumps({**payload, 'archive_read_key': 'A' * 43}))
    with pytest.raises(ArchiveError): client.list()
    config.write_text(json.dumps(payload))
    redirect = ArchiveClient(config, transport=httpx.MockTransport(lambda req:
        httpx.Response(302, headers={'Location': 'https://elsewhere.invalid'}, text='R' * 43)))
    with pytest.raises(ArchiveError) as error: redirect.list()
    assert 'R' * 43 not in str(error.value) and 'elsewhere' not in str(error.value)


def test_private_config_and_origin_restrictions(config, tmp_path):
    config.chmod(0o644)
    with pytest.raises(ArchiveError): private_json(config)
    config.chmod(0o600)
    link = tmp_path / 'link'
    link.symlink_to(config)
    with pytest.raises(ArchiveError): private_json(link)
    fifo = tmp_path / 'fifo'
    os.mkfifo(fifo, 0o600)
    with pytest.raises(ArchiveError): private_json(fifo)
    for value in ['http://public.example', 'https://key@private.example', 'https://private.example/path',
                  'file:///etc/passwd', 'http://192.168.1.2', 'https://private.example?token=secret']:
        with pytest.raises(ArchiveError): origin(value)
    assert origin('https://private.example/') == 'https://private.example'


def test_grant_rotate_revoke_never_changes_phone_key_or_owner(tmp_path):
    pairing = tmp_path / 'pairing.json'
    original = {'version': 1, 'owner_uid': 'synthetic', 'key_sha256': 'a' * 64, 'retained': 'metadata'}
    pairing.write_text(json.dumps(original))
    pairing.chmod(0o600)
    config = tmp_path / 'client.json'
    grant(pairing, config, 'https://archive.invalid')
    client = private_json(config)
    state = private_json(pairing)
    assert {key: state[key] for key in original} == original
    assert state['archive_read_key_sha256'] == hashlib.sha256(client['archive_read_key'].encode()).hexdigest()
    assert client['archive_read_key'] not in pairing.read_text()
    with pytest.raises(ArchiveError): grant(pairing, config, 'https://archive.invalid')
    grant(pairing, config, 'https://archive.invalid', replace=True)
    assert private_json(config)['archive_read_key'] != client['archive_read_key']
    revoke(pairing)
    assert private_json(pairing) == original
