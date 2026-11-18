# ruff: noqa: T201 - the program's one output owner
"""An app's S3 client for the app-garage job: boto3 with no endpoint, region or key argument, addressed by path,
putting, getting, listing and deleting one object in the bucket that BUCKET names."""

import os

import boto3
from botocore.config import Config


def require(condition: bool, failure: str) -> None:
    if not condition:
        raise SystemExit(failure)


client = boto3.client("s3", config=Config(s3={"addressing_style": "path"}))
bucket = os.environ["BUCKET"]
client.put_object(Bucket=bucket, Key="probe/object", Body=b"payload")
require(
    client.get_object(Bucket=bucket, Key="probe/object")["Body"].read() == b"payload", "the object read back differs"
)
require(
    [item["Key"] for item in client.list_objects_v2(Bucket=bucket)["Contents"]] == ["probe/object"],
    "the bucket does not list exactly the object",
)
client.delete_object(Bucket=bucket, Key="probe/object")
require("Contents" not in client.list_objects_v2(Bucket=bucket), "the bucket still lists the deleted object")
print("put, get, list and delete passed")
