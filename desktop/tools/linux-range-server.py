"""A tiny static file server with HTTP Range support (WebKit's media player
requires it), for the Linux run's video checks. python linux-range-server.py PORT"""
import http.server, os, re, sys

class H(http.server.SimpleHTTPRequestHandler):
    def send_head(self):
        path = self.translate_path(self.path)
        if not os.path.isfile(path):
            return super().send_head()
        size = os.path.getsize(path)
        m = re.match(r"bytes=(\d*)-(\d*)", self.headers.get("Range", ""))
        f = open(path, "rb")
        if not m:
            self.send_response(200)
            self.send_header("Content-Length", str(size))
            start, end = 0, size - 1
        else:
            start = int(m.group(1) or 0)
            end = min(int(m.group(2)) if m.group(2) else size - 1, size - 1)
            self.send_response(206)
            self.send_header("Content-Range", f"bytes {start}-{end}/{size}")
            self.send_header("Content-Length", str(end - start + 1))
        self.send_header("Content-Type", self.guess_type(path))
        self.send_header("Accept-Ranges", "bytes")
        self.end_headers()
        f.seek(start)
        self.range_left = end - start + 1
        return f

    def copyfile(self, src, dst):
        left = getattr(self, "range_left", None)
        while left is None or left > 0:
            chunk = src.read(65536 if left is None else min(65536, left))
            if not chunk:
                break
            dst.write(chunk)
            if left is not None:
                left -= len(chunk)

os.chdir("/")
http.server.ThreadingHTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
