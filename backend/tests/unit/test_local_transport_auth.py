import hashlib
import json

import pytest
from fastapi import FastAPI, WebSocket
from fastapi.testclient import TestClient
from starlette.websockets import WebSocketDisconnect

from utils.local_transport_auth import LocalTransportAuthError, LocalTransportAuthMiddleware, verify_local_key
from utils.offline_route_policy import OfflineRoutePolicyMiddleware

KEY = "a" * 43


@pytest.fixture
def pairing(monkeypatch, tmp_path):
    path = tmp_path / "pairing.json"
    path.write_text(
        json.dumps(
            {"version": 1, "owner_uid": "synthetic-owner", "key_sha256": hashlib.sha256(KEY.encode()).hexdigest()}
        )
    )
    path.chmod(0o600)
    monkeypatch.setenv("OMI_ENV_STAGE", "offline")
    monkeypatch.setenv("OMI_LOCAL_TRANSPORT", "ngrok")
    monkeypatch.setenv("OMI_LOCAL_PAIRING_FILE", str(path))
    return path


def client():
    app = FastAPI()

    @app.get("/v1/users/profile")
    def profile():
        return {"uid": "synthetic-owner"}

    @app.websocket("/v4/listen")
    async def listen(ws: WebSocket):
        await ws.accept()
        await ws.send_json({"owner": ws.scope["omi.local_uid"]})
        await ws.close()

    app.add_middleware(OfflineRoutePolicyMiddleware)
    app.add_middleware(LocalTransportAuthMiddleware)
    return TestClient(app)


def test_http_ws_share_key_and_ignore_query_uid(pairing):
    headers = {"Authorization": f"Bearer {KEY}"}
    with client() as c:
        assert c.get("/v1/users/profile", headers=headers).status_code == 200
        with c.websocket_connect("/v4/listen?uid=attacker", headers=headers) as ws:
            assert ws.receive_json() == {"owner": "synthetic-owner"}
        assert c.post("/v2/sync", headers=headers, content=b"blocked").status_code == 503


@pytest.mark.parametrize("value", [None, "Bearer wrong", "Basic " + KEY, "Bearer " + KEY + " "])
def test_invalid_auth_rejected_before_handlers(pairing, value):
    headers = {} if value is None else {"Authorization": value}
    with client() as c:
        assert c.get("/v1/users/profile", headers=headers).status_code == 401
        with pytest.raises(WebSocketDisconnect) as exc:
            with c.websocket_connect("/v4/listen", headers=headers):
                pass
        assert exc.value.code == 1008


def test_rotation_revokes_previous_key_and_permissions_fail_closed(pairing):
    assert verify_local_key(KEY) == "synthetic-owner"
    data = json.loads(pairing.read_text())
    data["key_sha256"] = hashlib.sha256(("b" * 43).encode()).hexdigest()
    pairing.write_text(json.dumps(data))
    with pytest.raises(LocalTransportAuthError):
        verify_local_key(KEY)
    assert verify_local_key("b" * 43) == "synthetic-owner"
    pairing.chmod(0o644)
    with pytest.raises(LocalTransportAuthError):
        verify_local_key("b" * 43)


def test_missing_configuration_blocks_startup(monkeypatch):
    monkeypatch.setenv("OMI_ENV_STAGE", "offline")
    monkeypatch.setenv("OMI_LOCAL_TRANSPORT", "ngrok")
    monkeypatch.delenv("OMI_LOCAL_PAIRING_FILE", raising=False)
    with pytest.raises(LocalTransportAuthError):
        with client():
            pass


def test_existing_lan_client_remains_unchanged(monkeypatch):
    monkeypatch.setenv("OMI_ENV_STAGE", "offline")
    monkeypatch.setenv("OMI_LOCAL_TRANSPORT", "lan")
    with client() as c:
        assert c.get("/v1/users/profile").status_code == 200


def test_pairing_diagnostics_only_include_response_status(pairing, caplog):
    with client() as c:
        accepted = c.get("/v1/users/profile?private=synthetic-private", headers={"Authorization": f"Bearer {KEY}"})
        rejected = c.get(
            "/v1/users/profile?private=synthetic-private", headers={"Authorization": "Bearer rejected-secret"}
        )
        assert accepted.status_code == 200
        assert rejected.status_code == 401
        assert c.get("/openapi.json").status_code == 401
    messages = [record.getMessage() for record in caplog.records if record.name == "utils.local_transport_auth"]
    assert messages == ["Local Mac profile check: status=200", "Local Mac profile check: status=401"]


def test_listen_diagnostics_observe_frames_and_close_without_private_content(pairing, caplog):
    app = FastAPI()

    @app.websocket("/v4/listen")
    async def listen(ws: WebSocket):
        await ws.accept()
        assert await ws.receive_bytes() == b"synthetic-private-audio"
        await ws.send_text("received")
        await ws.receive()

    app.add_middleware(LocalTransportAuthMiddleware)
    with TestClient(app) as c:
        with c.websocket_connect(
            "/v4/listen?private=synthetic-private-query",
            headers={"Authorization": f"Bearer {KEY}", "X-Private": "synthetic-private-header"},
        ) as ws:
            ws.send_bytes(b"synthetic-private-audio")
            assert ws.receive_text() == "received"
            ws.close(code=1000, reason="synthetic-private-close")
    messages = [record.getMessage() for record in caplog.records if record.name == "utils.local_transport_auth"]
    assert messages == [
        "Local Mac listen: opened",
        "Local Mac listen: accepted",
        "Local Mac listen: first_binary_frame",
        "Local Mac listen: peer_closed code=1000 frames=1 bytes=23",
    ]


def test_listen_auth_rejection_is_observed_before_accept(pairing, caplog):
    with client() as c:
        with pytest.raises(WebSocketDisconnect):
            with c.websocket_connect("/v4/listen?private=synthetic-private", headers={"Authorization": "Bearer wrong"}):
                pass
    messages = [record.getMessage() for record in caplog.records if record.name == "utils.local_transport_auth"]
    assert messages == ["Local Mac listen: opened", "Local Mac listen: server_closed code=1008"]
