#!/usr/bin/env python3
"""Deterministic local RSS fixtures for podcast refresh profiling.

Run, for example:
    python3 Scripts/podcast-refresh-fixture-server.py --feeds 100

Endpoints are /<profile>/<feed-number>, where profile is fast, slow-head,
slow-get, unchanged, head-unsupported, malformed, paged, private, or large.
The server logs only method, profile, feed number, and status.
"""

from __future__ import annotations

import argparse
import base64
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
    if profile == "dynamic":
        status = "pending" if revision == 1 else "live"
        start = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
        dynamic_metadata = (
            f"<description>Standard description revision {revision}</description>"
            f'<podcast:liveItem status="{status}" start="{start}">'
            '<podcast:guid>fixture-live-event</podcast:guid>'
            '<podcast:title>Fixture live event</podcast:title>'
            '</podcast:liveItem>'
        )
    body = (
        '<rss version="2.0" xmlns:atom="http://www.w3.org/2005/Atom" '
        'xmlns:podcast="https://podcastindex.org/namespace/1.0"><channel>'
        f"<title>Fixture {profile} {feed_number}</title>"
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
        self.handle_request(include_body=True)

    def handle_request(self, include_body: bool) -> None:
        parsed = urlparse(self.path)
        pieces = [piece for piece in parsed.path.split("/") if piece]
        if len(pieces) != 2 or pieces[0] not in self.server.profiles:
            self.send_error(404)
            return
        profile, feed_number = pieces
        if not feed_number.isdigit() or int(feed_number) >= self.server.feeds:
            self.send_error(404)
            return
        query = parse_qs(parsed.query)
        page = int(query.get("page", ["1"])[0])
        episodes = self.server.episodes
        if profile == "head-unsupported" and not include_body:
            self.send_response(405)
            self.end_headers()
            status = 405
        elif profile == "private" and self.headers.get("Authorization") != self.server.authorization:
            self.send_response(401)
            self.send_header("WWW-Authenticate", 'Basic realm="Podcast fixture"')
            self.end_headers()
            status = 401
        elif profile in {"rate-limited", "server-error"}:
            status = 429 if profile == "rate-limited" else 503
            self.send_response(status)
            self.send_header("Retry-After", "2")
            self.end_headers()
        else:
            if profile == "slow-head" and not include_body:
                import time
                time.sleep(self.server.delay)
            if profile == "slow-get" and include_body:
                import time
                time.sleep(self.server.delay)
            revision = 1
            if profile == "dynamic" and include_body:
                revision_key = feed_number + ":" + query.get("run", [""])[0]
                with self.server.dynamic_lock:
                    revision = self.server.dynamic_versions.get(revision_key, 0) + 1
                    self.server.dynamic_versions[revision_key] = revision
            body = rss_document("large" if profile == "large" else profile, feed_number, page, episodes, revision)
            if profile == "unchanged" and not include_body:
                modified = "Wed, 01 Jan 2020 00:00:00 GMT"
            else:
                modified = self.server.last_modified
            etag = f'"fixture-{profile}-{feed_number}-p{page}"'
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
                    self.wfile.write(body)
                status = 200

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
        "malformed", "paged", "private", "large", "dynamic", "rate-limited", "server-error",
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
    print(f"Serving {args.feeds} feed IDs at http://{args.host}:{args.port}/<profile>/<id>", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
