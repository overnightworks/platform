# ruff: noqa: T201 - the program's one output owner
"""An app's S3 client for the app-garage job: boto3 with no endpoint, region or key argument, addressed by path, putting,
getting, listing and deleting one object in the bucket that BUCKET names."""

import os

import boto3
from botocore.config import Config

client = boto3.client("s3", config=Config(s3={"addressing_style": "path"}))
bucket = os.environ["BUCKET"]
client.put_object(Bucket=bucket, Key="probe/object", Body=b"payload")
assert client.get_object(Bucket=bucket, Key="probe/object")["Body"].read() == b"payload"
assert [item["Key"] for item in client.list_objects_v2(Bucket=bucket)["Contents"]] == ["probe/object"]
client.delete_object(Bucket=bucket, Key="probe/object")
assert "Contents" not in client.list_objects_v2(Bucket=bucket)
print("put, get, list and delete passed")
