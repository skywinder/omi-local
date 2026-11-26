from __future__ import annotations

import pytest
from fastapi import FastAPI
from fastapi.testclient import TestClient
from starlette.websockets import WebSocketDisconnect

from utils.offline_route_policy import OfflineRoutePolicyMiddleware, is_offline_http_route_allowed


def test_offline_detail_contract_does_not_open_other_conversation_actions():
    path = '/v1/conversations/00000000-0000-0000-0000-000000000001'
    assert is_offline_http_route_allowed('GET', path)
    assert is_offline_http_route_allowed('GET', '/v1/conversations/{conversation_id}')
    assert is_offline_http_route_allowed('POST', '/v1/local/conversations/search')
    assert not is_offline_http_route_allowed('GET', '/v1/local/conversations/search')
    assert is_offline_http_route_allowed('POST', '/v1/local/conversations/semantic-search')
    assert not is_offline_http_route_allowed('GET', '/v1/local/conversations/semantic-search')
    recording_chat = '/v1/local/conversations/00000000-0000-4000-8000-000000000001/chat'
    assert is_offline_http_route_allowed('GET', recording_chat)
    assert is_offline_http_route_allowed('POST', recording_chat)
    assert not is_offline_http_route_allowed('DELETE', recording_chat)
    assert not is_offline_http_route_allowed('POST', recording_chat + '/extra')
    assert is_offline_http_route_allowed('GET', '/v1/local/conversations/chat')
    assert is_offline_http_route_allowed('POST', '/v1/local/conversations/chat')
    assert not is_offline_http_route_allowed('DELETE', '/v1/local/conversations/chat')
    recording_edit = '/v1/local/conversations/00000000-0000-4000-8000-000000000001/edit'
    assert is_offline_http_route_allowed('PATCH', recording_edit)
    assert not is_offline_http_route_allowed('POST', recording_edit)
    retry = recording_edit.removesuffix('/edit') + '/retry-processing'
    assert is_offline_http_route_allowed('POST', retry)
    assert not is_offline_http_route_allowed('GET', retry)
    assert not is_offline_http_route_allowed('POST', retry + '/extra')
    assert is_offline_http_route_allowed('GET', '/v1/local/folders')
    assert is_offline_http_route_allowed('POST', '/v1/local/folders')
    assert is_offline_http_route_allowed('PATCH', '/v1/local/folders/fixture-folder')
    assert is_offline_http_route_allowed('DELETE', '/v1/local/folders/fixture-folder')
    assert is_offline_http_route_allowed('POST', '/v1/local/folders/move')
    assert is_offline_http_route_allowed('POST', '/v1/local/folders/reorder')
    assert is_offline_http_route_allowed('GET', '/v1/local/people')
    assert is_offline_http_route_allowed('POST', '/v1/local/people')
    assert not is_offline_http_route_allowed('POST', '/v1/users/people')
    assert is_offline_http_route_allowed('POST', '/v1/local/action-items')
    assert is_offline_http_route_allowed('PATCH', '/v1/local/action-items/task-1')
    assert not is_offline_http_route_allowed('POST', '/v1/action-items')
    assert not is_offline_http_route_allowed('DELETE', '/v1/folders/fixture-folder')
    assert not is_offline_http_route_allowed('PATCH', '/v1/conversations/00000000-0000-4000-8000-000000000001/title')
    assert not is_offline_http_route_allowed('POST', path)
    assert not is_offline_http_route_allowed('GET', path + '/share')
    assert not is_offline_http_route_allowed('GET', '/v1/conversations/count')


def test_processing_routes_are_exact_not_a_general_admin_proxy():
    assert is_offline_http_route_allowed('GET', '/v1/local/processing')
    for operation in ('save', 'probe', 'models', 'activate'):
        assert is_offline_http_route_allowed('POST', '/v1/local/processing/' + operation)
    assert is_offline_http_route_allowed('DELETE', '/v1/local/processing/profiles/synthetic-profile')
    for method, path in [('POST', '/v1/local/processing/delete'), ('GET', '/v1/local/processing/save'),
                         ('DELETE', '/v1/local/processing/profiles/../settings'), ('GET', '/api/settings')]:
        assert not is_offline_http_route_allowed(method, path)


def _client(monkeypatch) -> TestClient:
    monkeypatch.setenv("OMI_ENV_STAGE", "offline")
    app = FastAPI()

    @app.get("/v1/health")
    def health():
        return {"status": "ok"}

    @app.post("/v2/realtime/session")
    def realtime():
        raise AssertionError("blocked handler must not run")

    app.add_middleware(OfflineRoutePolicyMiddleware)
    return TestClient(app)


def test_offline_allowlist_and_early_503(monkeypatch) -> None:
    monkeypatch.setenv("OPENAI_API_KEY", "must-not-enable-route")
    client = _client(monkeypatch)
    assert client.get("/v1/health").status_code == 200
    response = client.post("/v2/realtime/session", content=b"must-not-be-read")
    assert response.status_code == 503
    assert response.json()["reason"] == "offline_route_blocked"


def test_offline_rejects_non_listen_websocket_with_policy_violation(monkeypatch) -> None:
    client = _client(monkeypatch)
    with pytest.raises(WebSocketDisconnect) as exc_info:
        with client.websocket_connect("/v2/realtime"):
            pass
    assert exc_info.value.code == 1008


def test_standard_runtime_keeps_routes(monkeypatch) -> None:
    monkeypatch.setenv("OMI_ENV_STAGE", "local")
    app = FastAPI()

    @app.get("/standard")
    def standard():
        return {"ok": True}

    app.add_middleware(OfflineRoutePolicyMiddleware)
    assert TestClient(app).get("/standard").status_code == 200
