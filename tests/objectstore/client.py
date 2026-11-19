# ruff: noqa: T201 - the program's one output owner
"""An app's S3 client for bucket_key_reaches_only_its_bucket.sh: botocore with only the environment the web's manifest
holds, the bucket named in the variable that argv names, addressed by path as the apps' adapters do.

client.py allowed <bucket variable> <other bucket>: everything the key may do on its bucket, and what it may not.
client.py denied <bucket variable>: every request on the bucket is refused with 403.
client.py put <bucket variable> <object key> and client.py delete <bucket variable> <object key>: a key with write rights
makes and removes the object that read-only reads.
client.py read-only <bucket variable> <object key> <other bucket>: list and get of the object succeed; put, delete, a
multipart create and a copy onto the bucket get 403, and so do list and get of the other bucket.
"""

import os
import sys
import uuid

import boto3
from botocore.config import Config
from botocore.exceptions import ClientError

MEBIBYTE = 1024 * 1024
SEED_BODY = b"read by the backup"


def status_of(error: ClientError) -> int:
    return error.response["ResponseMetadata"]["HTTPStatusCode"]


def require(condition: bool, description: str) -> None:
    if not condition:
        raise SystemExit(f"FAIL: {description}")


def refused_with(status: int, description: str, call) -> None:
    try:
        call()
    except ClientError as error:
        if status_of(error) != status:
            raise SystemExit(f"FAIL: {description}: answered {status_of(error)}, not {status}") from error
        print(f"ok: {description}: {status}")
        return
    raise SystemExit(f"FAIL: {description}: succeeded, not {status}")


def multipart_put(client, bucket: str, key: str) -> None:
    upload = client.create_multipart_upload(Bucket=bucket, Key=key)["UploadId"]
    parts = []
    for number, body in enumerate([b"a" * (5 * MEBIBYTE), b"b" * MEBIBYTE], start=1):
        etag = client.upload_part(Bucket=bucket, Key=key, UploadId=upload, PartNumber=number, Body=body)["ETag"]
        parts.append({"PartNumber": number, "ETag": etag})
    client.complete_multipart_upload(Bucket=bucket, Key=key, UploadId=upload, MultipartUpload={"Parts": parts})


def allowed(client, bucket: str, other_bucket: str) -> None:
    prefix = f"cell-{uuid.uuid4().hex}/"
    small, large = prefix + "small", prefix + "large"
    client.put_object(Bucket=bucket, Key=small, Body=b"0123456789")
    require(client.get_object(Bucket=bucket, Key=small)["Body"].read() == b"0123456789", "the small object came back changed")
    print("ok: put and get of a small object")
    multipart_put(client, bucket, large)
    require(client.head_object(Bucket=bucket, Key=large)["ContentLength"] == 6 * MEBIBYTE, "the multipart object has another size")
    print("ok: multipart put of 6 MiB in two parts, and head")
    ranged = client.get_object(Bucket=bucket, Key=large, Range=f"bytes={5 * MEBIBYTE - 2}-{5 * MEBIBYTE + 1}")
    require(ranged["ResponseMetadata"]["HTTPStatusCode"] == 206, "a ranged get did not answer 206")
    require(ranged["Body"].read() == b"aabb", "a ranged get across the part boundary returned other bytes")
    print("ok: ranged get answers 206 with the bytes across the boundary of two parts")
    listed = [item["Key"] for item in client.list_objects_v2(Bucket=bucket, Prefix=prefix).get("Contents", [])]
    require(sorted(listed) == [large, small], f"a list by prefix returned {listed}")
    print("ok: list by prefix")
    for key in (small, large):
        client.delete_object(Bucket=bucket, Key=key)
        refused_with(404, f"head of the deleted {key[len(prefix):]}", lambda key=key: client.head_object(Bucket=bucket, Key=key))
    refused_with(403, "put to another bucket", lambda: client.put_object(Bucket=other_bucket, Key="x", Body=b"x"))
    refused_with(403, "list of another bucket", lambda: client.list_objects_v2(Bucket=other_bucket))
    refused_with(403, "making a bucket", lambda: client.create_bucket(Bucket=f"made-{uuid.uuid4().hex[:12]}"))
    refused_with(
        403,
        "a lifecycle rule on its own bucket",
        lambda: client.put_bucket_lifecycle_configuration(
            Bucket=bucket,
            LifecycleConfiguration={"Rules": [{"ID": "expire", "Status": "Enabled", "Filter": {"Prefix": ""}, "Expiration": {"Days": 1}}]},
        ),
    )


def denied(client, bucket: str) -> None:
    refused_with(403, "put to the bucket", lambda: client.put_object(Bucket=bucket, Key="x", Body=b"x"))
    refused_with(403, "list of the bucket", lambda: client.list_objects_v2(Bucket=bucket))


def read_only(client, bucket: str, key: str, other_bucket: str) -> None:
    listed = [item["Key"] for item in client.list_objects_v2(Bucket=bucket).get("Contents", [])]
    require(key in listed, "the list of the bucket lacks the object")
    print("ok: list of the bucket")
    require(client.get_object(Bucket=bucket, Key=key)["Body"].read() == SEED_BODY, "the object came back changed")
    print("ok: get of the object")
    refused_with(403, "put to the bucket", lambda: client.put_object(Bucket=bucket, Key=f"{key}-written", Body=b"x"))
    refused_with(403, "delete of the object", lambda: client.delete_object(Bucket=bucket, Key=key))
    refused_with(403, "a multipart create on the bucket", lambda: client.create_multipart_upload(Bucket=bucket, Key=f"{key}-parts"))
    refused_with(
        403,
        "a copy onto the bucket",
        lambda: client.copy_object(Bucket=bucket, Key=f"{key}-copy", CopySource={"Bucket": bucket, "Key": key}),
    )
    refused_with(403, "list of another bucket", lambda: client.list_objects_v2(Bucket=other_bucket))
    refused_with(403, "get from another bucket", lambda: client.get_object(Bucket=other_bucket, Key=key))


def main(arguments: list[str]) -> None:
    mode, bucket_variable = arguments[0], arguments[1]
    client = boto3.client("s3", config=Config(s3={"addressing_style": "path"}))
    bucket = os.environ[bucket_variable]
    if mode == "allowed":
        allowed(client, bucket, arguments[2])
    elif mode == "denied":
        denied(client, bucket)
    elif mode == "put":
        client.put_object(Bucket=bucket, Key=arguments[2], Body=SEED_BODY)
        print("ok: put of the object")
    elif mode == "delete":
        client.delete_object(Bucket=bucket, Key=arguments[2])
        print("ok: delete of the object")
    elif mode == "read-only":
        read_only(client, bucket, arguments[2], arguments[3])
    else:
        raise SystemExit(f"FAIL: the mode {mode} is unknown")


main(sys.argv[1:])
