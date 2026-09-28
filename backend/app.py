"""
E-Commerce Backend API (Flask)

Runs as a container on ECS Fargate behind an ALB. The ALB routes /api/* here
(see terraform/ecs.tf aws_lb_listener_rule.backend_route) and / to the frontend.

Environment variables:
    MONGO_URI    MongoDB connection string. In production this is injected from
                 AWS Secrets Manager via the ECS task definition (see
                 terraform/ecs.tf + terraform/secrets.tf), not hardcoded.
    KINESIS_STREAM  Name of the Kinesis stream for real-time order events.
    AWS_REGION   AWS region for boto3 clients.
"""

import json
import logging
import os
from datetime import datetime, timezone

import boto3
from botocore.exceptions import BotoCoreError, ClientError
from flask import Flask, jsonify, request
from pymongo import MongoClient
from pymongo.errors import PyMongoError

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s %(name)s %(message)s",
)
logger = logging.getLogger(__name__)

app = Flask(__name__)

MONGO_URI = os.environ.get("MONGO_URI", "mongodb://localhost:27017")
KINESIS_STREAM = os.environ.get("KINESIS_STREAM", "ecommerce-orders-stream")
AWS_REGION = os.environ.get("AWS_REGION", "ap-south-1")

# Lazy singletons so the container starts even if a dependency is briefly down.
_mongo_client = None
_kinesis_client = None


def get_db():
    """Return the MongoDB database handle, connecting on first use."""
    global _mongo_client
    if _mongo_client is None:
        _mongo_client = MongoClient(MONGO_URI, serverSelectionTimeoutMS=5000)
    return _mongo_client.ecommerce


def get_kinesis():
    """Return the Kinesis client, creating it on first use."""
    global _kinesis_client
    if _kinesis_client is None:
        _kinesis_client = boto3.client("kinesis", region_name=AWS_REGION)
    return _kinesis_client


def emit_event(event_type, payload):
    """
    Publish a real-time event to Kinesis (feeds Firehose -> S3 raw zone -> Glue).

    Failures here are logged but never break the API response: analytics
    ingestion must not take down order processing.
    """
    try:
        event = {
            "event_type": event_type,
            "timestamp": datetime.now(timezone.utc).isoformat(),
            **payload,
        }
        get_kinesis().put_record(
            StreamName=KINESIS_STREAM,
            Data=json.dumps(event),
            PartitionKey=str(payload.get("customer_id", "unknown")),
        )
    except (BotoCoreError, ClientError) as exc:
        logger.warning("Kinesis emit failed (non-fatal): %s", exc)


@app.route("/health")
@app.route("/api/health")
def health():
    """
    Liveness probe.

    Exposed on two paths deliberately:
      /health      - hit by the ALB target group health check, which talks to
                     the task IP directly and so is not subject to routing rules.
      /api/health  - hit by the browser, which can only reach the backend
                     through the ALB's /api/* listener rule. A browser request
                     to /health would be routed to the frontend nginx instead.
    """
    return jsonify(status="ok"), 200


@app.route("/ready")
def ready():
    """Readiness probe that actually verifies the MongoDB connection."""
    try:
        get_db().command("ping")
        return jsonify(status="ready"), 200
    except PyMongoError as exc:
        logger.error("Readiness check failed: %s", exc)
        return jsonify(status="not ready", error=str(exc)), 503


@app.route("/api/products", methods=["GET"])
def list_products():
    """Return the product catalog."""
    try:
        products = list(get_db().products.find({}, {"_id": 0}))
        return jsonify(products), 200
    except PyMongoError as exc:
        logger.error("list_products failed: %s", exc)
        return jsonify(error="database unavailable"), 503


@app.route("/api/orders", methods=["GET"])
def list_orders():
    """Return all orders, newest first, capped to avoid unbounded responses."""
    try:
        limit = min(int(request.args.get("limit", 100)), 500)
        orders = list(
            get_db().orders.find({}, {"_id": 0}).sort("order_date", -1).limit(limit)
        )
        return jsonify(orders), 200
    except ValueError:
        return jsonify(error="limit must be an integer"), 400
    except PyMongoError as exc:
        logger.error("list_orders failed: %s", exc)
        return jsonify(error="database unavailable"), 503


@app.route("/api/orders/<order_id>", methods=["GET"])
def get_order(order_id):
    """Return a single order by its business key."""
    try:
        order = get_db().orders.find_one({"order_id": order_id}, {"_id": 0})
        if order is None:
            return jsonify(error="order not found"), 404
        return jsonify(order), 200
    except PyMongoError as exc:
        logger.error("get_order failed: %s", exc)
        return jsonify(error="database unavailable"), 503


@app.route("/api/orders", methods=["POST"])
def create_order():
    """
    Create an order.

    Writes to MongoDB (operational store) and emits a Kinesis event
    (analytics pipeline). Validates required fields before either.
    """
    order = request.get_json(silent=True)
    if not order:
        return jsonify(error="request body must be JSON"), 400

    required = ["order_id", "customer_id", "product_id", "quantity", "amount"]
    missing = [field for field in required if field not in order]
    if missing:
        return jsonify(error=f"missing required fields: {', '.join(missing)}"), 400

    try:
        order["quantity"] = int(order["quantity"])
        order["amount"] = float(order["amount"])
    except (TypeError, ValueError):
        return jsonify(error="quantity must be an int and amount a number"), 400

    if order["quantity"] <= 0 or order["amount"] < 0:
        return jsonify(error="quantity must be > 0 and amount >= 0"), 400

    order.setdefault("order_date", datetime.now(timezone.utc).isoformat())

    try:
        if get_db().orders.find_one({"order_id": order["order_id"]}):
            return jsonify(error="order_id already exists"), 409
        get_db().orders.insert_one(dict(order))
    except PyMongoError as exc:
        logger.error("create_order failed: %s", exc)
        return jsonify(error="database unavailable"), 503

    emit_event("purchase", order)
    logger.info("Created order %s", order["order_id"])
    return jsonify(status="created", order_id=order["order_id"]), 201


@app.errorhandler(404)
def not_found(_):
    return jsonify(error="not found"), 404


@app.errorhandler(500)
def server_error(_):
    return jsonify(error="internal server error"), 500


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=5000)
