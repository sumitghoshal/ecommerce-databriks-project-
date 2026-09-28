"""
Kinesis producer — simulates real-time e-commerce clickstream/order events.

Events flow: producer -> Kinesis Data Stream -> Firehose -> S3 raw/streaming/
             -> Glue ETL -> curated -> Athena/QuickSight/Redshift

Usage:
    python producer.py --stream ecommerce-devops-orders-stream --rate 2 --duration 300
    python producer.py --stream ecommerce-devops-orders-stream --count 500

Requires AWS credentials (aws configure) with kinesis:PutRecord on the stream.
"""

import argparse
import json
import random
import signal
import sys
import time
import uuid
from datetime import datetime, timezone

import boto3
from botocore.exceptions import BotoCoreError, ClientError

EVENT_TYPES = ["view", "add_to_cart", "purchase"]
EVENT_WEIGHTS = [0.65, 0.25, 0.10]  # realistic funnel shape

_running = True


def _handle_sigint(signum, frame):
    global _running
    _running = False
    print("\nStopping producer…")


signal.signal(signal.SIGINT, _handle_sigint)


def generate_event():
    """Build one synthetic event matching the ETL job's expected schema."""
    event_type = random.choices(EVENT_TYPES, weights=EVENT_WEIGHTS, k=1)[0]
    quantity = random.randint(1, 5)
    unit_price = round(random.uniform(5.0, 300.0), 2)

    return {
        "event_id": f"EVT-{uuid.uuid4().hex[:12].upper()}",
        "event_type": event_type,
        "customer_id": random.randint(1, 500),
        "product_id": random.randint(1, 100),
        "quantity": quantity,
        "amount": round(unit_price * quantity, 2),
        "timestamp": datetime.now(timezone.utc).isoformat(),
        "session_id": f"SES-{uuid.uuid4().hex[:8]}",
        "channel": random.choice(["web", "mobile_app", "partner"]),
    }


def send_batch(client, stream_name, events):
    """
    Send events with put_records (batched) and retry only failed records.

    put_records can partially succeed — checking FailedRecordCount is required,
    a 200 response alone does not mean every record landed.
    """
    records = [
        {"Data": json.dumps(e), "PartitionKey": str(e["customer_id"])} for e in events
    ]

    try:
        response = client.put_records(StreamName=stream_name, Records=records)
    except (BotoCoreError, ClientError) as exc:
        print(f"  ERROR: put_records failed: {exc}", file=sys.stderr)
        return 0

    failed = response.get("FailedRecordCount", 0)
    if failed:
        print(f"  WARNING: {failed}/{len(records)} records failed; retrying once")
        retry = [
            records[i]
            for i, r in enumerate(response["Records"])
            if "ErrorCode" in r
        ]
        time.sleep(1)
        try:
            client.put_records(StreamName=stream_name, Records=retry)
        except (BotoCoreError, ClientError) as exc:
            print(f"  ERROR: retry failed: {exc}", file=sys.stderr)
            return len(records) - failed

    return len(records)


def main():
    parser = argparse.ArgumentParser(description="Kinesis event producer")
    parser.add_argument("--stream", required=True, help="Kinesis stream name")
    parser.add_argument("--region", default="ap-south-1")
    parser.add_argument("--rate", type=float, default=2.0, help="events per second")
    parser.add_argument("--duration", type=int, default=0, help="seconds (0 = forever)")
    parser.add_argument("--count", type=int, default=0, help="total events (0 = unlimited)")
    parser.add_argument("--batch-size", type=int, default=5)
    args = parser.parse_args()

    client = boto3.client("kinesis", region_name=args.region)

    # Fail fast with a clear message if the stream is missing or inactive
    try:
        desc = client.describe_stream_summary(StreamName=args.stream)
        status = desc["StreamDescriptionSummary"]["StreamStatus"]
        if status != "ACTIVE":
            print(f"Stream '{args.stream}' is {status}, not ACTIVE. Wait and retry.")
            sys.exit(1)
    except ClientError as exc:
        print(f"Cannot access stream '{args.stream}': {exc}", file=sys.stderr)
        print("Check the name (terraform output kinesis_stream_name) and your credentials.")
        sys.exit(1)

    print(f"Producing to '{args.stream}' at ~{args.rate} events/sec. Ctrl-C to stop.")

    sent = 0
    started = time.time()
    interval = args.batch_size / args.rate if args.rate > 0 else 1.0

    while _running:
        if args.count and sent >= args.count:
            break
        if args.duration and (time.time() - started) >= args.duration:
            break

        size = args.batch_size
        if args.count:
            size = min(size, args.count - sent)

        events = [generate_event() for _ in range(size)]
        sent += send_batch(client, args.stream, events)

        elapsed = int(time.time() - started)
        print(f"  [{elapsed:>4}s] sent {sent} events "
              f"(latest: {events[-1]['event_type']} ${events[-1]['amount']})")

        time.sleep(interval)

    print(f"\nDone. Sent {sent} events in {int(time.time() - started)}s.")
    print("Firehose buffers for 60s before writing to S3 — wait, then check:")
    print(f"  aws s3 ls s3://<raw-bucket>/streaming/orders/ --recursive")


if __name__ == "__main__":
    main()
