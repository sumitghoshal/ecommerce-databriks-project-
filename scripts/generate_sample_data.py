"""
Generate sample batch data (CSV) for the raw zone, and optionally upload it.

The schema here is the contract the Glue ETL job expects:
    order_id, customer_id, product_id, quantity, amount, order_date

Usage:
    python generate_sample_data.py --rows 5000 --out ./data
    python generate_sample_data.py --rows 5000 --upload s3://my-raw-bucket
"""

import argparse
import csv
import os
import random
import subprocess
import sys
import uuid
from datetime import date, timedelta

CATEGORIES = ["electronics", "apparel", "home", "books", "sports", "beauty"]
CITIES = ["Hyderabad", "Bengaluru", "Mumbai", "Delhi", "Chennai", "Pune"]


def generate_orders(rows, days_back=180):
    """Generate order rows spread over the past `days_back` days."""
    today = date.today()
    orders = []

    for _ in range(rows):
        order_date = today - timedelta(days=random.randint(0, days_back))
        quantity = random.randint(1, 5)
        unit_price = round(random.uniform(5.0, 300.0), 2)

        orders.append({
            "order_id": f"ORD-{uuid.uuid4().hex[:12].upper()}",
            "customer_id": random.randint(1, 500),
            "product_id": random.randint(1, 100),
            "quantity": quantity,
            "amount": round(unit_price * quantity, 2),
            "order_date": order_date.isoformat(),
        })

    return orders


def generate_products(count=100):
    return [
        {
            "product_id": pid,
            "product_name": f"Product {pid}",
            "category": random.choice(CATEGORIES),
            "unit_price": round(random.uniform(5.0, 300.0), 2),
        }
        for pid in range(1, count + 1)
    ]


def generate_customers(count=500):
    today = date.today()
    return [
        {
            "customer_id": cid,
            "customer_name": f"Customer {cid}",
            "email": f"customer{cid}@example.com",
            "city": random.choice(CITIES),
            "signup_date": (today - timedelta(days=random.randint(0, 900))).isoformat(),
        }
        for cid in range(1, count + 1)
    ]


def write_csv(path, rows):
    if not rows:
        return
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(handle, fieldnames=list(rows[0].keys()))
        writer.writeheader()
        writer.writerows(rows)
    print(f"  wrote {len(rows):>6} rows -> {path}")


def upload(local_dir, bucket_uri):
    """Upload each dataset to the prefix the Glue crawler/job expects."""
    targets = {
        "orders.csv": f"{bucket_uri}/batch/orders/orders.csv",
        "products.csv": f"{bucket_uri}/batch/products/products.csv",
        "customers.csv": f"{bucket_uri}/batch/customers/customers.csv",
    }

    for filename, destination in targets.items():
        source = os.path.join(local_dir, filename)
        if not os.path.exists(source):
            continue
        print(f"  uploading {filename} -> {destination}")
        result = subprocess.run(
            ["aws", "s3", "cp", source, destination],
            capture_output=True, text=True,
        )
        if result.returncode != 0:
            print(f"  ERROR: {result.stderr.strip()}", file=sys.stderr)
            sys.exit(1)


def main():
    parser = argparse.ArgumentParser(description="Generate sample e-commerce data")
    parser.add_argument("--rows", type=int, default=5000, help="number of orders")
    parser.add_argument("--out", default="./data", help="local output directory")
    parser.add_argument("--upload", help="s3://bucket-name to upload to (optional)")
    parser.add_argument("--seed", type=int, help="random seed for reproducibility")
    args = parser.parse_args()

    if args.seed is not None:
        random.seed(args.seed)

    print(f"Generating {args.rows} orders…")
    write_csv(os.path.join(args.out, "orders.csv"), generate_orders(args.rows))
    write_csv(os.path.join(args.out, "products.csv"), generate_products())
    write_csv(os.path.join(args.out, "customers.csv"), generate_customers())

    if args.upload:
        bucket_uri = args.upload.rstrip("/")
        if not bucket_uri.startswith("s3://"):
            bucket_uri = f"s3://{bucket_uri}"
        print(f"\nUploading to {bucket_uri}…")
        upload(args.out, bucket_uri)
        print("\nDone. Next: run the raw crawler, then the Glue ETL job.")
    else:
        print(f"\nDone. Upload with:\n  python {sys.argv[0]} --upload s3://<raw-bucket>")


if __name__ == "__main__":
    main()
