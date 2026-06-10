#!/usr/bin/env python3
"""Publish release artifacts to a Gitea release."""

from __future__ import annotations

import argparse
import json
import mimetypes
import os
from pathlib import Path
import sys
from urllib.error import HTTPError
from urllib.parse import quote
from urllib.request import Request, urlopen


def api_url(base_url: str, path: str) -> str:
    return f"{base_url.rstrip('/')}/api/v1{path}"


def request_json(
    method: str,
    url: str,
    token: str,
    payload: dict | None = None,
    headers: dict | None = None,
) -> dict | None:
    body = None
    request_headers = {
        "Accept": "application/json",
        "Authorization": f"token {token}",
    }
    if payload is not None:
        body = json.dumps(payload).encode("utf-8")
        request_headers["Content-Type"] = "application/json"
    if headers:
        request_headers.update(headers)

    req = Request(url, data=body, method=method, headers=request_headers)
    with urlopen(req) as response:
        data = response.read()
    if not data:
        return None
    return json.loads(data.decode("utf-8"))


def request_empty(method: str, url: str, token: str) -> None:
    req = Request(
        url,
        method=method,
        headers={
            "Accept": "application/json",
            "Authorization": f"token {token}",
        },
    )
    with urlopen(req) as response:
        response.read()


def upload_file(url: str, token: str, path: Path) -> dict:
    boundary = f"----heimdall-gitea-{os.urandom(16).hex()}"
    content_type = mimetypes.guess_type(path.name)[0] or "application/octet-stream"
    payload = bytearray()
    payload.extend(f"--{boundary}\r\n".encode("utf-8"))
    payload.extend(
        (
            f'Content-Disposition: form-data; name="attachment"; '
            f'filename="{path.name}"\r\n'
            f"Content-Type: {content_type}\r\n\r\n"
        ).encode("utf-8")
    )
    payload.extend(path.read_bytes())
    payload.extend(f"\r\n--{boundary}--\r\n".encode("utf-8"))

    req = Request(
        url,
        data=bytes(payload),
        method="POST",
        headers={
            "Accept": "application/json",
            "Authorization": f"token {token}",
            "Content-Type": f"multipart/form-data; boundary={boundary}",
        },
    )
    with urlopen(req) as response:
        return json.loads(response.read().decode("utf-8"))


def get_release(base_url: str, token: str, owner: str, repo: str, tag: str) -> dict | None:
    url = api_url(
        base_url,
        f"/repos/{quote(owner, safe='')}/{quote(repo, safe='')}/releases/tags/{quote(tag, safe='')}",
    )
    try:
        return request_json("GET", url, token)
    except HTTPError as exc:
        if exc.code == 404:
            return None
        raise


def create_release(
    base_url: str,
    token: str,
    owner: str,
    repo: str,
    tag: str,
    name: str,
    body: str,
    target_commitish: str | None,
) -> dict:
    url = api_url(base_url, f"/repos/{quote(owner, safe='')}/{quote(repo, safe='')}/releases")
    payload = {
        "tag_name": tag,
        "name": name,
        "body": body,
        "draft": False,
        "prerelease": any(part in tag.lower() for part in ("alpha", "beta", "rc", "dev")),
    }
    if target_commitish:
        payload["target_commitish"] = target_commitish

    try:
        release = request_json("POST", url, token, payload)
    except HTTPError as exc:
        if exc.code not in (409, 422):
            raise
        release = get_release(base_url, token, owner, repo, tag)
        if release is None:
            raise
    if release is None:
        raise RuntimeError("Gitea returned an empty response while creating release")
    return release


def release_assets(release: dict) -> list[dict]:
    assets = []
    for key in ("attachments", "assets"):
        value = release.get(key)
        if isinstance(value, list):
            assets.extend(asset for asset in value if isinstance(asset, dict))
    return assets


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--tag", required=True)
    parser.add_argument("--name")
    parser.add_argument("--body", default=os.environ.get("GITEA_RELEASE_BODY", ""))
    parser.add_argument("--target-commitish", default=os.environ.get("GITHUB_SHA"))
    parser.add_argument("--files", nargs="+", required=True)
    args = parser.parse_args()

    base_url = os.environ.get("GITEA_BASE_URL")
    token = os.environ.get("GITEA_TOKEN")
    repo_slug = os.environ.get("GITEA_REPO")
    missing = [
        name
        for name, value in (
            ("GITEA_BASE_URL", base_url),
            ("GITEA_TOKEN", token),
            ("GITEA_REPO", repo_slug),
        )
        if not value
    ]
    if missing:
        print(f"Missing required environment variable(s): {', '.join(missing)}", file=sys.stderr)
        return 2

    if "/" not in repo_slug:
        print("GITEA_REPO must be in owner/repo form", file=sys.stderr)
        return 2
    owner, repo = repo_slug.split("/", 1)

    files = [Path(path) for path in args.files]
    files = [path for path in files if path.is_file()]
    if not files:
        print("No files to upload", file=sys.stderr)
        return 2

    release = get_release(base_url, token, owner, repo, args.tag)
    if release is None:
        release = create_release(
            base_url,
            token,
            owner,
            repo,
            args.tag,
            args.name or args.tag,
            args.body,
            args.target_commitish,
        )
        print(f"Created Gitea release {args.tag}")
    else:
        print(f"Using existing Gitea release {args.tag}")

    release_id = release["id"]
    upload_url = api_url(
        base_url,
        f"/repos/{quote(owner, safe='')}/{quote(repo, safe='')}/releases/{release_id}/assets",
    )
    delete_base_url = upload_url

    existing_by_name = {
        asset.get("name"): asset for asset in release_assets(release) if asset.get("name")
    }
    for path in files:
        existing = existing_by_name.get(path.name) or existing_by_name.get(quote(path.name, safe=""))
        if existing and existing.get("id") is not None:
            delete_url = f"{delete_base_url}/{existing['id']}"
            request_empty("DELETE", delete_url, token)
            print(f"Deleted existing Gitea release asset {path.name}")
        upload_file(f"{upload_url}?name={quote(path.name, safe='')}", token, path)
        print(f"Uploaded Gitea release asset {path.name}")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
