from __future__ import annotations

import pytest
from fastapi import FastAPI
from fastapi.testclient import TestClient
from starlette.websockets import WebSocketDisconnect

from utils.offline_route_policy import OfflineRoutePolicyMiddleware


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
