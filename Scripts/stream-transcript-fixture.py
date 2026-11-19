#!/usr/bin/env python3
"""Serve synthetic MP3/HLS fixtures for StreamAudioProbeTests; requires say and ffmpeg."""
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from tempfile import TemporaryDirectory
import json
import os
import re
import subprocess
import time


class Handler(SimpleHTTPRequestHandler):
    live_requests = 0

    def send_head(self):
        if self.path == "/stats":
            return self.send_bytes(json.dumps({"live_playlist_requests": Handler.live_requests}).encode(), "application/json")
        if self.path == "/live/fixture.m3u8":
            Handler.live_requests += 1
            text = "#EXTM3U\n#EXT-X-VERSION:3\n#EXT-X-TARGETDURATION:2\n#EXT-X-MEDIA-SEQUENCE:0\n"
            text += "".join(f"#EXTINF:2.0,\nsegment{i:03d}.ts\n" for i in range(3))
            if Handler.live_requests > 1:
                text += "#EXT-X-DISCONTINUITY\n#EXTINF:2.0,\nad.ts\n#EXT-X-DISCONTINUITY\n"
                text += "".join(f"#EXTINF:2.0,\nsegment{i:03d}.ts\n" for i in range(3, 6))
                text += "#EXT-X-ENDLIST\n"
            return self.send_bytes(text.encode(), "application/vnd.apple.mpegurl")
        self.is_slow = self.path.startswith("/slow/")
        if self.is_slow:
            self.path = self.path.removeprefix("/slow")
        if self.path.startswith("/live/"):
            self.path = self.path.removeprefix("/live")
        path = self.translate_path(self.path)
        if not os.path.isfile(path):
            return super().send_head()
        source = open(path, "rb")
        size = os.fstat(source.fileno()).st_size
        match = re.match(r"bytes=(\d+)-(\d*)", self.headers.get("Range", ""))
        if match:
            start = int(match.group(1))
            end = min(int(match.group(2) or size - 1), size - 1)
            if start >= size:
                source.close()
                self.send_error(416)
                return None
            self.send_response(206)
            self.send_header("Content-Range", f"bytes {start}-{end}/{size}")
            source.seek(start)
            self.remaining = end - start + 1
        else:
            self.send_response(200)
            self.remaining = size
        self.send_header("Content-Length", str(self.remaining))
        self.send_header("Content-Type", self.guess_type(path))
        self.send_header("Accept-Ranges", "bytes")
        self.end_headers()
        return source

    def send_bytes(self, data, content_type):
        self.send_response(200)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)
        return None

    def copyfile(self, source, output):
        sent = 0
        stalled = False
        while self.remaining:
            if self.is_slow and sent >= 32768 and not stalled:
                time.sleep(5)
                stalled = True
            data = source.read(min(self.remaining, 4096))
            if not data:
                break
            output.write(data)
            self.remaining -= len(data)
            sent += len(data)

    def log_message(self, *args):
        pass


def main():
    with TemporaryDirectory(prefix="upnext-stream-fixture-") as directory:
        root = Path(directory)
        speech = root / "speech.aiff"
        sentence = "This is a public sample podcast. The curious traveler walks beside the river and tells a story about the city. "
        subprocess.run(["say", "-o", str(speech), sentence * 2], check=True)
        ffmpeg = ["ffmpeg", "-hide_banner", "-loglevel", "error"]
        subprocess.run(ffmpeg + ["-i", str(speech), "-c:a", "libmp3lame", "-b:a", "96k", str(root / "fixture.mp3")], check=True)
        subprocess.run(ffmpeg + ["-i", str(speech), "-c:a", "aac", "-b:a", "96k", "-f", "hls", "-hls_time", "2", "-hls_list_size", "0", "-hls_segment_filename", str(root / "segment%03d.ts"), str(root / "fixture.m3u8")], check=True)
        subprocess.run(ffmpeg + ["-f", "lavfi", "-i", "sine=frequency=660:sample_rate=22050:duration=2", "-c:a", "aac", "-b:a", "96k", "-f", "mpegts", str(root / "ad.ts")], check=True)
        os.chdir(root)
        print("Synthetic stream fixture listening on 127.0.0.1:18765", flush=True)
        with ThreadingHTTPServer(("127.0.0.1", 18765), Handler) as server:
            try:
                server.serve_forever()
            except KeyboardInterrupt:
                pass


if __name__ == "__main__":
    main()
