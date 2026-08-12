"""Read/write handler for the multi-region order table.

One function, two routes — the course ships two nearly identical files.

Corrections to the course code, all of them real defects:
  1. Runtime: the guide says Python 3.9, which is EOL in Lambda. This runs 3.12.
  2. Decimal: json.dumps() on a DynamoDB scan raises TypeError the moment any
     attribute is numeric, because boto3 returns Decimal. Handled below.
  3. CORS: the guide returns Access-Control-Allow-Origin on the read path but
     not the write path, so preflight passes and the real POST fails.
  4. IAM: the guide attaches AmazonDynamoDBFullAccess. The deploy script grants
     four actions on one table ARN.
  5. Input validation: the guide indexes body['ItemId'] unguarded, so a
     malformed POST is a 500 instead of a 400.
"""
import json
import os
import time
from decimal import Decimal

import boto3

TABLE = os.environ["TABLE_NAME"]
REGION = os.environ.get("AWS_REGION", "unknown")
ROLE = os.environ.get("REGION_ROLE", "unknown")  # PRIMARY | SECONDARY

table = boto3.resource("dynamodb").Table(TABLE)

CORS = {
    "Content-Type": "application/json",
    "Access-Control-Allow-Origin": "*",
    "Access-Control-Allow-Headers": "*",
    "Access-Control-Allow-Methods": "*",
}


class DecimalEncoder(json.JSONEncoder):
    """DynamoDB returns numbers as Decimal, which json.dumps cannot serialise."""

    def default(self, o):
        if isinstance(o, Decimal):
            return int(o) if o % 1 == 0 else float(o)
        return super().default(o)


def reply(status, payload):
    return {
        "statusCode": status,
        "headers": CORS,
        "body": json.dumps(payload, cls=DecimalEncoder),
    }


def handler(event, context):
    method = (
        event.get("requestContext", {}).get("http", {}).get("method")
        or event.get("httpMethod")
        or "GET"
    )

    try:
        if method == "POST":
            raw = event.get("body") or "{}"
            body = json.loads(raw) if isinstance(raw, str) else raw

            item_id = body.get("ItemId")
            data = body.get("Data")
            if not item_id or data is None:
                return reply(400, {"error": "ItemId and Data are required"})

            table.put_item(
                Item={
                    "ItemId": str(item_id),
                    "Data": str(data),
                    "WrittenInRegion": REGION,
                    # TTL: this is a public demo, so writes self-delete after
                    # 24h. Epoch SECONDS — milliseconds would mean year 56000
                    # and nothing would ever be removed, silently. DynamoDB
                    # replicates the deletion to the other region too.
                    "expiresAt": int(time.time()) + 86400,
                }
            )
            return reply(
                200,
                {"message": "saved", "ItemId": item_id, "writtenIn": REGION},
            )

        items = table.scan().get("Items", [])
        return reply(
            200,
            {
                "servedBy": REGION,
                "role": ROLE,
                "count": len(items),
                "items": sorted(items, key=lambda i: i.get("ItemId", "")),
            },
        )

    except Exception as exc:  # noqa: BLE001 - surface the reason to the caller
        return reply(500, {"error": str(exc), "servedBy": REGION})
