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

REDIRECT_STATUSES = (301, 302, 303, 307, 308)


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


def resolve_location(scheme, host, port, location):
    parsed = urllib.parse.urlparse(location)
    if parsed.scheme and parsed.hostname:
        resolved_scheme = parsed.scheme
        resolved_host = parsed.hostname
        resolved_port = parsed.port or (443 if resolved_scheme == "https" else 80)
        resolved_path = parsed.path or "/"
    else:
        resolved_scheme = scheme
        resolved_host = host
        resolved_port = port
        resolved_path = parsed.path or location
    if parsed.query:
        resolved_path += "?" + parsed.query
    return resolved_scheme, resolved_host, resolved_port, resolved_path


def redirect_location(headers):
    return headers.get("Location") or headers.get("location")


def request_with_redirects(scheme, host, port, method, path, headers=None, body=None, verify_tls=False):
    current_scheme = scheme
    current_host = host
    current_port = port
    current_path = path
    for _ in range(5):
        status, response_headers, content = request(
            current_scheme,
            current_host,
            current_port,
            method,
            current_path,
            headers=headers,
            body=body,
            verify_tls=verify_tls,
        )
        if status not in REDIRECT_STATUSES:
            return status, response_headers, content
        location = redirect_location(response_headers)
        if not location:
            raise RuntimeError("registry redirect did not include Location")
        current_scheme, current_host, current_port, current_path = resolve_location(
            current_scheme,
            current_host,
            current_port,
            location,
        )
    raise RuntimeError("registry request redirected too many times")


def blob_member_name(digest):
    return "blobs/sha256/" + digest.split(":", 1)[1]


def blob_exists(scheme, host, port, path, digest, verify_tls):
    status, _, _ = request_with_redirects(
        scheme,
        host,
        port,
        "HEAD",
        path + "/blobs/" + digest,
        verify_tls=verify_tls,
    )
    return status == 200


def upload_blob(scheme, host, port, base, digest, tar, member, size, verify_tls):
    if blob_exists(scheme, host, port, base, digest, verify_tls):
        return
    upload_start_scheme = scheme
    upload_start_host = host
    upload_start_port = port
    upload_start_path = base + "/blobs/uploads/"
    for _ in range(5):
        status, headers, _ = request(
            upload_start_scheme,
            upload_start_host,
            upload_start_port,
            "POST",
            upload_start_path,
            headers={"Content-Length": "0"},
            verify_tls=verify_tls,
        )
        if status not in REDIRECT_STATUSES:
            break
        location = redirect_location(headers)
        if not location:
            raise RuntimeError("registry upload redirect did not include Location")
        upload_start_scheme, upload_start_host, upload_start_port, upload_start_path = resolve_location(
            upload_start_scheme,
            upload_start_host,
            upload_start_port,
            location,
        )
    else:
        raise RuntimeError("registry upload start redirected too many times")
    if status not in (201, 202):
        raise RuntimeError("registry upload start failed with HTTP %s" % status)
    location = redirect_location(headers)
    if not location:
        raise RuntimeError("registry upload response did not include Location")
    upload_scheme, upload_host, upload_port, upload_path = resolve_location(
        upload_start_scheme,
        upload_start_host,
        upload_start_port,
        location,
    )
    upload_path += ("&" if "?" in upload_path else "?") + "digest=" + urllib.parse.quote(digest, safe=":")

    conn = connection(upload_scheme, upload_host, upload_port, verify_tls)
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
            status, _, _ = request_with_redirects(
                scheme,
                host,
                port,
                "HEAD",
                base + "/manifests/" + args.tag,
                verify_tls=args.tls_verify,
            )
            if status == 200:
                print("Image already exists: %s:%s" % (repository, args.tag))
                return 0
        for item in [manifest["config"]] + manifest.get("layers", []):
            digest = item["digest"]
            member = blob_member_name(digest)
            info = tar.getmember(member)
            upload_blob(scheme, host, port, base, digest, tar, member, info.size, args.tls_verify)
        headers = {"Content-Type": manifest_descriptor.get("mediaType", "application/vnd.oci.image.manifest.v1+json")}
        status, _, _ = request_with_redirects(
            scheme,
            host,
            port,
            "PUT",
            base + "/manifests/" + args.tag,
            headers=headers,
            body=manifest_data,
            verify_tls=args.tls_verify,
        )
        if status not in (200, 201, 202):
            raise RuntimeError("registry manifest upload failed with HTTP %s" % status)
    print("Published %s:%s" % (repository, args.tag))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
