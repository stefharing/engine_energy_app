"""Tests met een nep-Ridder (geen netwerk nodig): draaien met `pytest`."""

import base64
import sys
from pathlib import Path

import httpx
import pytest
from fastapi.testclient import TestClient

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

import app as app_module  # noqa: E402
from app import app, get_client  # noqa: E402
from ridder import RidderClient, RidderConfig, RidderError  # noqa: E402

PDF = b"%PDF-1.4\n%fake\n"


def fake_ridder(request: httpx.Request) -> httpx.Response:
    assert request.headers["x-api-key"] == "sleutel"
    path = request.url.path
    assert path.startswith("/Engine%20Energy%20B.V./RIQ_TEST/v2/") or path.startswith(
        "/Engine Energy B.V./RIQ_TEST/v2/"
    )
    if path.endswith("/sales/salesinvoices"):
        assert request.url.params["page"] == "2"
        assert request.url.params["size"] == "5"
        return httpx.Response(200, json={"data": [{"id": 7, "invoicenumber": "F-7", "customer": {"id": 1}}]})
    if path.endswith("/sales/salesinvoices/7/documents"):
        if "page" not in request.url.params:
            return httpx.Response(400, text="A value for the 'page' parameter or property was not provided.")
        return httpx.Response(200, json={"data": [{"id": 99, "description": "Factuur F-7"}]})
    if path.endswith("/iqsystem/documents/99/document"):
        return httpx.Response(200, content=PDF, headers={"content-type": "application/pdf"})
    if path.endswith("/iqsystem/documents/98/document"):
        return httpx.Response(200, json={"content": base64.b64encode(PDF).decode() * 20})
    if path.endswith("/iqsystem/documents/97/document"):
        return httpx.Response(200, json={"content": base64.b64encode(PDF + b"x" * 200).decode()})
    return httpx.Response(404, text="onbekend")


@pytest.fixture
def client():
    config = RidderConfig("Engine Energy B.V.", "RIQ_TEST", "sleutel", "test")
    ridder = RidderClient(config, transport=httpx.MockTransport(fake_ridder))
    app.dependency_overrides[get_client] = lambda: ridder
    yield TestClient(app, raise_server_exceptions=False)
    app.dependency_overrides.clear()


def test_config_defaults_to_test_and_requires_keys():
    env = {"RIDDER_TEST_ADMINISTRATION": "RIQ_TEST", "RIDDER_TEST_API_KEY": "k"}
    cfg = RidderConfig.from_env(env)
    assert cfg.environment == "test"
    assert cfg.base_url == "https://api.eciridderiq.com/Engine%20Energy%20B.V./RIQ_TEST/v2"
    with pytest.raises(ValueError, match="RIDDER_LIVE_API_KEY"):
        RidderConfig.from_env({"RIDDER_ENV": "live", "RIDDER_LIVE_ADMINISTRATION": "x"})


def test_invoice_list(client):
    r = client.get("/api/invoices", params={"page": 2, "size": 5})
    assert r.status_code == 200
    assert r.json()["items"][0]["invoicenumber"] == "F-7"
    assert r.json()["count"] == 1


def test_documents_and_pdf(client):
    docs = client.get("/api/invoices/7/documents").json()["items"]
    assert docs[0]["id"] == 99
    pdf = client.get("/api/documents/99/pdf")
    assert pdf.status_code == 200
    assert pdf.content == PDF
    assert pdf.headers["content-type"] == "application/pdf"
    assert "document-99.pdf" in pdf.headers["content-disposition"]


def test_base64_wrapped_pdf_is_unwrapped(client):
    # Ridder zou het bestand ook als base64 in json kunnen leveren.
    r = client.get("/api/documents/97/pdf")
    assert r.content.startswith(b"%PDF")


def test_ridder_error_is_passed_on(client):
    r = client.get("/api/documents/1/pdf")
    assert r.status_code == 502
    assert r.json()["ridderStatus"] == 404
    assert "onbekend" in r.json()["body"]


def test_index_served(client):
    r = client.get("/")
    assert r.status_code == 200
    assert "Ridder factuur-debug" in r.text


def test_connection_error_becomes_ridder_error():
    def boom(_request):
        raise httpx.ConnectError("geen netwerk")

    ridder = RidderClient(
        RidderConfig("t", "a", "k", "test"), transport=httpx.MockTransport(boom)
    )
    with pytest.raises(RidderError) as exc:
        ridder.list_sales_invoices()
    assert exc.value.status == 0


@pytest.fixture
def plain(monkeypatch):
    for key in list(__import__("os").environ):
        if key.startswith("RIDDER_"):
            monkeypatch.delenv(key)
    monkeypatch.setenv("RIDDER_TEST_ADMINISTRATION", "RIQ_TEST")
    monkeypatch.setenv("RIDDER_TEST_API_KEY", "t")
    app_module._state.clear()
    app_module._clients.clear()
    yield TestClient(app, raise_server_exceptions=False)
    app_module._state.clear()
    app_module._clients.clear()


def test_starts_on_test_and_live_is_refused_when_not_configured(plain):
    c = plain.get("/api/config").json()
    assert c["environment"] == "test"
    assert c["available"] == ["test"]
    r = plain.post("/api/environment", json={"environment": "live"})
    assert r.status_code == 400
    assert "RIDDER_LIVE" in r.json()["error"]
    assert plain.get("/api/config").json()["environment"] == "test"


def test_switch_to_live_and_back(plain, monkeypatch):
    monkeypatch.setenv("RIDDER_LIVE_ADMINISTRATION", "RIQ_LIVE")
    monkeypatch.setenv("RIDDER_LIVE_API_KEY", "l")
    r = plain.post("/api/environment", json={"environment": "live"})
    assert r.status_code == 200
    assert r.json()["administration"] == "RIQ_LIVE"
    assert app_module.get_client().config.api_key == "l"
    back = plain.post("/api/environment", json={"environment": "test"}).json()
    assert back["administration"] == "RIQ_TEST"
    assert app_module.get_client().config.api_key == "t"
    assert plain.post("/api/environment", json={"environment": "x"}).status_code == 400
