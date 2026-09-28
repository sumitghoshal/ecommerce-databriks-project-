"""
Unit tests for the backend API.

Uses mongomock so tests need no real MongoDB, and stubs Kinesis so they need
no AWS credentials. This is what the Jenkins "Build & Unit Test" stage runs.
"""

import sys
from pathlib import Path

import mongomock
import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

import app as app_module  # noqa: E402


@pytest.fixture
def client(monkeypatch):
    """Flask test client wired to an in-memory Mongo and a no-op Kinesis."""
    fake_mongo = mongomock.MongoClient()
    monkeypatch.setattr(app_module, "_mongo_client", fake_mongo)
    monkeypatch.setattr(app_module, "emit_event", lambda *a, **k: None)

    app_module.app.config["TESTING"] = True
    with app_module.app.test_client() as test_client:
        yield test_client


def sample_order(order_id="ORD-1"):
    return {
        "order_id": order_id,
        "customer_id": 42,
        "product_id": 7,
        "quantity": 2,
        "amount": 99.50,
    }


def test_health_returns_ok(client):
    response = client.get("/health")
    assert response.status_code == 200
    assert response.get_json()["status"] == "ok"


def test_create_order_succeeds(client):
    response = client.post("/api/orders", json=sample_order())
    assert response.status_code == 201
    assert response.get_json()["order_id"] == "ORD-1"


def test_create_order_rejects_missing_fields(client):
    response = client.post("/api/orders", json={"order_id": "ORD-2"})
    assert response.status_code == 400
    assert "missing required fields" in response.get_json()["error"]


def test_create_order_rejects_non_json(client):
    response = client.post("/api/orders", data="not json")
    assert response.status_code == 400


def test_create_order_rejects_bad_quantity(client):
    bad = sample_order("ORD-3")
    bad["quantity"] = 0
    response = client.post("/api/orders", json=bad)
    assert response.status_code == 400


def test_create_order_rejects_duplicate_id(client):
    client.post("/api/orders", json=sample_order("ORD-DUP"))
    response = client.post("/api/orders", json=sample_order("ORD-DUP"))
    assert response.status_code == 409


def test_list_orders_returns_created_order(client):
    client.post("/api/orders", json=sample_order("ORD-LIST"))
    response = client.get("/api/orders")
    assert response.status_code == 200
    order_ids = [order["order_id"] for order in response.get_json()]
    assert "ORD-LIST" in order_ids


def test_get_order_returns_404_when_absent(client):
    response = client.get("/api/orders/DOES-NOT-EXIST")
    assert response.status_code == 404


def test_get_order_returns_the_order(client):
    client.post("/api/orders", json=sample_order("ORD-GET"))
    response = client.get("/api/orders/ORD-GET")
    assert response.status_code == 200
    assert response.get_json()["customer_id"] == 42
