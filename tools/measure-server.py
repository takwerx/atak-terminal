# Serves its own directory (windows-measure.ps1 as measure.ps1, and ATAK.apk) on a LAN and accepts
# PUT /upload/<name> into incoming/. For tools/windows-measure.ps1; development only.
#   python3 measure-server.py <listen-ip> <port>
import http.server, os, sys
ROOT = os.path.dirname(os.path.abspath(__file__)); INC = os.path.join(ROOT, 'incoming'); os.makedirs(INC, exist_ok=True)
class H(http.server.SimpleHTTPRequestHandler):
    def __init__(self, *a, **k): super().__init__(*a, directory=ROOT, **k)
    def do_PUT(self):
        name = os.path.basename(self.path.split('?')[0])
        if not self.path.startswith('/upload/') or not name: self.send_error(404); return
        n = int(self.headers.get('Content-Length', 0)); dest = os.path.join(INC, name)
        with open(dest, 'wb') as f:
            left = n
            while left > 0:
                chunk = self.rfile.read(min(65536, left)); f.write(chunk); left -= len(chunk)
        print(f'received {name} ({n} bytes)', flush=True)
        self.send_response(201); self.end_headers()
http.server.ThreadingHTTPServer((sys.argv[1], int(sys.argv[2])), H).serve_forever()
