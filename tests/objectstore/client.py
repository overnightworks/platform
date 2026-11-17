"""An app's S3 client for bucket_key_reaches_only_its_bucket.sh: botocore with only the environment the web's manifest
holds, the bucket named in the variable that argv names, addressed by path as the apps' adapters do.

client.py allowed <bucket variable> <other bucket>: everything the key may do on its bucket, and what it may not.
client.py denied <bucket variable>: every request on the bucket is refused with 403.
"""

import os
import sys
import uuid

import boto3
from botocore.config import Config
from botocore.exceptions import ClientError

MEBIBYTE = 1024 * 1024


def status_of(error: ClientError) -> int:
    return error.response["ResponseMetadata"]["HTTPStatusCode"]


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
    assert client.get_object(Bucket=bucket, Key=small)["Body"].read() == b"0123456789", "the small object came back changed"
    print("ok: put and get of a small object")
    multipart_put(client, bucket, large)
    assert client.head_object(Bucket=bucket, Key=large)["ContentLength"] == 6 * MEBIBYTE, "the multipart object has another size"
    print("ok: multipart put of 6 MiB in two parts, and head")
    ranged = client.get_object(Bucket=bucket, Key=large, Range=f"bytes={5 * MEBIBYTE - 2}-{5 * MEBIBYTE + 1}")
    assert ranged["ResponseMetadata"]["HTTPStatusCode"] == 206, "a ranged get did not answer 206"
    assert ranged["Body"].read() == b"aabb", "a ranged get across the part boundary returned other bytes"
    print("ok: ranged get answers 206 with the bytes across the boundary of two parts")
    listed = [item["Key"] for item in client.list_objects_v2(Bucket=bucket, Prefix=prefix).get("Contents", [])]
    assert sorted(listed) == [large, small], f"a list by prefix returned {listed}"
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


def main(arguments: list[str]) -> None:
    mode, bucket_variable = arguments[0], arguments[1]
    client = boto3.client("s3", config=Config(s3={"addressing_style": "path"}))
    bucket = os.environ[bucket_variable]
    if mode == "allowed":
        allowed(client, bucket, arguments[2])
    elif mode == "denied":
        denied(client, bucket)
    else:
        raise SystemExit(f"FAIL: the mode {mode} is unknown")


main(sys.argv[1:])
