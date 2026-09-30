#!/usr/bin/env python3
"""Publish an OCI image archive to a Docker Registry v2 endpoint.

The supported AAP execution environment contains Python and curl but does not
ship skopeo. This publisher uses only the Python standard library and streams
large blobs so the APME job can publish its bundled plugin pack in-cluster.
"""

import argparse
import http.client
import json
import os
import ssl
import tarfile
import urllib.parse


def parse_args():
    parser = argparse.ArgumentParser()
    parser.add_argument("--archive", required=True)
    parser.add_argument("--registry", required=True, help="host[:port], optionally with http(s)://")
    parser.add_argument("--repository", required=True)
    parser.add_argument("--tag", required=True)
    parser.add_argument("--force", action="store_true")
    parser.add_argument("--tls-verify", action="store_true", default=False)
    return parser.parse_args()


def registry_parts(value, verify_tls):
    raw = value if "://" in value else ("https://" if verify_tls else "http://") + value
    parsed = urllib.parse.urlparse(raw)
    if not parsed.hostname:
        raise ValueError("registry must contain a host")
    port = parsed.port or (443 if parsed.scheme == "https" else 80)
    return parsed.scheme, parsed.hostname, port


def connection(scheme, host, port, verify_tls):
    if scheme == "https":
        context = ssl.create_default_context() if verify_tls else ssl._create_unverified_context()
        return http.client.HTTPSConnection(host, port, context=context, timeout=120)
    return http.client.HTTPConnection(host, port, timeout=120)


def request(scheme, host, port, method, path, headers=None, body=None, verify_tls=False):
    conn = connection(scheme, host, port, verify_tls)
    try:
        conn.request(method, path, body=body, headers=headers or {})
        response = conn.getresponse()
        content = response.read()
        return response.status, dict(response.getheaders()), content
    finally:
        conn.close()


def blob_member_name(digest):
    return "blobs/sha256/" + digest.split(":", 1)[1]


def blob_exists(scheme, host, port, path, digest, verify_tls):
    status, _, _ = request(scheme, host, port, "HEAD", path + "/blobs/" + digest, verify_tls=verify_tls)
    return status == 200


def upload_blob(scheme, host, port, base, digest, tar, member, size, verify_tls):
    if blob_exists(scheme, host, port, base, digest, verify_tls):
        return
    status, headers, _ = request(scheme, host, port, "POST", base + "/blobs/uploads/", headers={"Content-Length": "0"}, verify_tls=verify_tls)
    if status not in (201, 202):
        raise RuntimeError("registry upload start failed with HTTP %s" % status)
    location = headers.get("Location") or headers.get("location")
    if not location:
        raise RuntimeError("registry upload response did not include Location")
    parsed = urllib.parse.urlparse(location)
    upload_path = parsed.path or location
    if parsed.query:
        upload_path += "?" + parsed.query
    upload_path += ("&" if "?" in upload_path else "?") + "digest=" + urllib.parse.quote(digest, safe=":")

    conn = connection(scheme, host, port, verify_tls)
    try:
        conn.putrequest("PUT", upload_path)
        conn.putheader("Content-Length", str(size))
        conn.putheader("Content-Type", "application/octet-stream")
        conn.endheaders()
        source = tar.extractfile(member)
        remaining = size
        while remaining:
            chunk = source.read(min(1024 * 1024, remaining))
            if not chunk:
                raise RuntimeError("unexpected end of archive while uploading %s" % digest)
            conn.send(chunk)
            remaining -= len(chunk)
        response = conn.getresponse()
        response.read()
        if response.status not in (201, 202):
            raise RuntimeError("registry blob upload failed with HTTP %s" % response.status)
    finally:
        conn.close()


def main():
    args = parse_args()
    scheme, host, port = registry_parts(args.registry, args.tls_verify)
    repository = args.repository.strip("/")
    base = "/v2/" + repository
    with tarfile.open(args.archive, mode="r:gz") as tar:
        index = json.load(tar.extractfile("index.json"))
        manifest_descriptor = index["manifests"][0]
        manifest_digest = manifest_descriptor["digest"]
        manifest_data = tar.extractfile(blob_member_name(manifest_digest)).read()
        manifest = json.loads(manifest_data)
        force = args.force or os.environ.get("APME_OCI_PUSH_FORCE", "").lower() in ("1", "true", "yes")
        if not force:
            status, _, _ = request(scheme, host, port, "HEAD", base + "/manifests/" + args.tag, verify_tls=args.tls_verify)
            if status == 200:
                print("Image already exists: %s:%s" % (repository, args.tag))
                return 0
        for item in [manifest["config"]] + manifest.get("layers", []):
            digest = item["digest"]
            member = blob_member_name(digest)
            info = tar.getmember(member)
            upload_blob(scheme, host, port, base, digest, tar, member, info.size, args.tls_verify)
        headers = {"Content-Type": manifest_descriptor.get("mediaType", "application/vnd.oci.image.manifest.v1+json")}
        status, _, _ = request(scheme, host, port, "PUT", base + "/manifests/" + args.tag, headers=headers, body=manifest_data, verify_tls=args.tls_verify)
        if status not in (200, 201, 202):
            raise RuntimeError("registry manifest upload failed with HTTP %s" % status)
    print("Published %s:%s" % (repository, args.tag))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
