#!/usr/bin/env python3
"""Deterministic local RSS fixtures for podcast refresh profiling.

Run, for example:
    python3 Scripts/podcast-refresh-fixture-server.py --feeds 100

Endpoints are /<profile>/<feed-number>. Profiles include fast, slow-head,
slow-get, unchanged, head-unsupported, malformed, paged, private, large,
large-history, dynamic, changed, stale-last-modified, rate-limited, and
server-error. /__stats returns bounded request metadata and /__reset clears it.
The server logs only method, profile, feed number, and status.
"""

from __future__ import annotations

import argparse
import base64
import json
import time
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from threading import Lock
from urllib.parse import parse_qs, urlparse


def rss_document(profile: str, feed_number: str, page: int, episodes: int, revision: int = 1) -> bytes:
    start = (page - 1) * episodes
    items = []
    for number in range(start, start + episodes):
        items.append(
            f"<item><title>Episode {number}</title>"
            f"<guid>{profile}-{feed_number}-{number}</guid>"
            f"<enclosure url=\"https://media.example.invalid/{profile}/{feed_number}/{number}.mp3\" "
            "type=\"audio/mpeg\"/></item>"
        )
    next_link = ""
    if profile == "paged" and page == 1:
        next_link = f'<podcast:remoteItem feedGuid="fixture" feedUrl="/paged/{feed_number}?page=2" />'
        next_link += f'<atom:link rel="next" href="/paged/{feed_number}?page=2" />'
    dynamic_metadata = ""
    if profile in {"dynamic", "stale-last-modified"}:
        status = "pending" if revision == 1 else "live"
        start = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
        dynamic_metadata = (
            f"<description>Standard description revision {revision}</description>"
            f'<podcast:liveItem status="{status}" start="{start}">'
            '<podcast:guid>fixture-live-event</podcast:guid>'
            '<podcast:title>Fixture live event</podcast:title>'
            '</podcast:liveItem>'
        )
    description = ""
    if profile == "changed":
        description = f"<description>Changed fixture revision {revision}</description>"
    body = (
        '<rss version="2.0" xmlns:atom="http://www.w3.org/2005/Atom" '
        'xmlns:podcast="https://podcastindex.org/namespace/1.0"><channel>'
        f"<title>Fixture {profile} {feed_number}</title>"
        + description
        + dynamic_metadata
        +
        f"<lastBuildDate>{datetime.now(timezone.utc).strftime('%a, %d %b %Y %H:%M:%S GMT')}</lastBuildDate>"
        f"{next_link}{''.join(items)}</channel></rss>"
    )
    if profile == "malformed":
        body = body.replace("</channel>", "", 1)
    return body.encode()


class FixtureHandler(BaseHTTPRequestHandler):
    server_version = "PodcastRefreshFixture/1.0"

    def do_HEAD(self) -> None:
        self.handle_request(include_body=False)

    def do_GET(self) -> None:
        parsed = urlparse(self.path)
        if parsed.path == "/__stats":
            self.send_json(self.server.snapshot_stats())
            return
        if parsed.path == "/__reset":
            self.server.reset_stats()
            self.send_json({"reset": True})
            return
        self.handle_request(include_body=True)

    def do_POST(self) -> None:
        parsed = urlparse(self.path)
        if parsed.path == "/__reset":
            self.server.reset_stats()
            self.send_json({"reset": True})
            return
        self.send_error(404)

    def send_json(self, value: object) -> None:
        body = json.dumps(value, sort_keys=True).encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        try:
            self.wfile.write(body)
        except BrokenPipeError:
            pass

    def handle_request(self, include_body: bool) -> None:
        started_at = time.monotonic()
        parsed = urlparse(self.path)
        pieces = [piece for piece in parsed.path.split("/") if piece]
        if len(pieces) != 2 or pieces[0] not in self.server.profiles:
            self.send_error(404)
            self.server.record_request(self.command, "", "", 1, 404, started_at)
            return
        profile, feed_number = pieces
        if not feed_number.isdigit() or int(feed_number) >= self.server.feeds:
            self.send_error(404)
            self.server.record_request(self.command, profile, feed_number, 1, 404, started_at)
            return
        query = parse_qs(parsed.query)
        page = int(query.get("page", ["1"])[0])
        episodes = max(1, int(query.get("episodes", [str(self.server.episodes)])[0]))
        revision = int(query.get("revision", ["0"])[0])
        if revision == 0 and profile in {"changed", "dynamic", "stale-last-modified"} and include_body:
            revision = self.server.next_revision(profile, feed_number, parsed.query)
        status = 500
        if profile == "head-unsupported" and not include_body:
            self.send_response(405)
            self.end_headers()
            status = 405
        elif profile == "private" and self.headers.get("Authorization") != self.server.authorization:
            self.send_response(401)
            self.send_header("WWW-Authenticate", 'Basic realm="Podcast fixture"')
            self.end_headers()
            status = 401
        elif profile == "rate-limited" and self.server.rate_limit_attempt(profile, feed_number, parsed.query) == 1:
            status = 429
            self.send_response(status)
            self.send_header("Retry-After", query.get("retry_after", ["2"])[0])
            self.end_headers()
        elif profile == "server-error":
            status = 503
            self.send_response(status)
            self.send_header("Retry-After", "2")
            self.end_headers()
        else:
            delay = float(query.get("delay", [str(self.server.delay)])[0])
            if (profile == "slow-head" and not include_body) or (profile == "slow-get" and include_body):
                time.sleep(max(0.0, delay))
            body_profile = "large" if profile in {"large", "large-history"} else profile
            body = rss_document(body_profile, feed_number, page, episodes, revision or 1)
            if profile in {"unchanged", "stale-last-modified"} and not include_body:
                modified = "Wed, 01 Jan 2020 00:00:00 GMT"
            else:
                modified = self.server.last_modified
            etag_revision = revision or 1
            etag = f'"fixture-{profile}-{feed_number}-p{page}-r{etag_revision}"'
            if include_body and self.headers.get("If-None-Match") == etag:
                self.send_response(304)
                self.send_header("ETag", etag)
                self.end_headers()
                status = 304
            else:
                self.send_response(200)
                self.send_header("Content-Type", "application/rss+xml; charset=utf-8")
                self.send_header("Last-Modified", modified)
                self.send_header("ETag", etag)
                self.send_header("Content-Length", str(len(body)))
                if profile == "paged" and page == 1:
                    self.send_header("Link", f'</paged/{feed_number}?page=2>; rel="next"')
                self.end_headers()
                if include_body:
                    try:
                        self.wfile.write(body)
                    except BrokenPipeError:
                        pass
                status = 200

        self.server.record_request(self.command, profile, feed_number, page, status, started_at)
        print(f"{self.command} profile={profile} feed={feed_number} page={page} status={status}", flush=True)

    def log_message(self, _format: str, *_args: object) -> None:
        return


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=8787)
    parser.add_argument("--feeds", type=int, default=100)
    parser.add_argument("--episodes", type=int, default=10)
    parser.add_argument("--delay", type=float, default=1.0)
    args = parser.parse_args()
    profiles = {
        "fast", "slow-head", "slow-get", "unchanged", "head-unsupported",
        "malformed", "paged", "private", "large", "large-history", "dynamic", "changed",
        "stale-last-modified", "rate-limited", "server-error",
    }
    server = ThreadingHTTPServer((args.host, args.port), FixtureHandler)
    server.profiles = profiles
    server.feeds = max(1, args.feeds)
    server.episodes = max(1, args.episodes)
    server.delay = max(0.0, args.delay)
    server.last_modified = datetime.now(timezone.utc).strftime("%a, %d %b %Y %H:%M:%S GMT")
    server.authorization = "Basic " + base64.b64encode(b"fixture:password").decode("ascii")
    server.dynamic_lock = Lock()
    server.dynamic_versions = {}
    server.stats_lock = Lock()
    server.requests = []
    server.maximum_requests = 20_000
    server.rate_limit_attempts = {}

    def record_request(method: str, profile: str, feed: str, page: int, status: int, started_at: float) -> None:
        with server.stats_lock:
            server.requests.append({
                "method": method,
                "profile": profile,
                "feed": feed,
                "page": page,
                "status": status,
                "duration_ms": round((time.monotonic() - started_at) * 1000, 3),
            })
            if len(server.requests) > server.maximum_requests:
                del server.requests[:-server.maximum_requests]

    def reset_stats() -> None:
        with server.stats_lock:
            server.requests.clear()
            server.dynamic_versions.clear()
            server.rate_limit_attempts.clear()

    def snapshot_stats() -> dict[str, object]:
        with server.stats_lock:
            requests = list(server.requests)
        counts: dict[str, int] = {}
        for request in requests:
            key = f"{request['method']} {request['profile']} {request['status']}"
            counts[key] = counts.get(key, 0) + 1
        return {"counts": counts, "requests": requests}

    def next_revision(profile: str, feed: str, query: str) -> int:
        key = f"{profile}:{feed}:{query}"
        with server.stats_lock:
            value = server.dynamic_versions.get(key, 0) + 1
            server.dynamic_versions[key] = value
            return value

    def rate_limit_attempt(profile: str, feed: str, query: str) -> int:
        key = f"{profile}:{feed}:{query}"
        with server.stats_lock:
            value = server.rate_limit_attempts.get(key, 0) + 1
            server.rate_limit_attempts[key] = value
            return value

    server.record_request = record_request
    server.reset_stats = reset_stats
    server.snapshot_stats = snapshot_stats
    server.next_revision = next_revision
    server.rate_limit_attempt = rate_limit_attempt
    print(f"Serving {args.feeds} feed IDs at http://{args.host}:{args.port}/<profile>/<id>", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
