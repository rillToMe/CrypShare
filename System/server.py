import os, time, html, urllib.parse, tempfile, zipfile, mimetypes, threading
from pathlib import Path
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from watchdog.observers import Observer
from watchdog.events import FileSystemEventHandler
from queue import SimpleQueue, Empty

PORT = int(os.getenv("PORT", "8888"))

_DEFAULT_UPLOADS = (Path(__file__).resolve().parent.parent / "uploads")
UPLOADS_DIR = Path(os.getenv("UPLOADS_DIR", str(_DEFAULT_UPLOADS))).resolve()

CHUNK = 1024 * 1024       
TARGET_RATE_MBPS = 512      
MAX_CONCURRENT_TRANSFERS = 3
MAX_CONCURRENT_ZIPS = 1
LIST_TTL = 2.0               

STREAM_RATE_MBPS_DEFAULT = 12
STREAM_BURST_MB_DEFAULT   = 22

_transfer_sem = threading.Semaphore(MAX_CONCURRENT_TRANSFERS)
_zip_sem = threading.Semaphore(MAX_CONCURRENT_ZIPS)

_last_list_html = ""
_last_list_at = 0.0

INLINE_EXTS = {
    ".png",".jpg",".jpeg",".gif",".webp",".bmp",".svg",
    ".mp4",".webm",".mov",".mkv",".avi",
    ".mp3",".wav",".ogg",
    ".pdf",".txt",".html",".htm"
}

_subscribers_lock = threading.Lock()
_subscribers: set[SimpleQueue] = set()

def _notify_all():
    """Kirim sinyal ke semua klien SSE bahwa ada perubahan."""
    with _subscribers_lock:
        dead = []
        for q in list(_subscribers):
            try:
                q.put_nowait(time.time())
            except Exception:
                dead.append(q)
        for d in dead:
            _subscribers.discard(d)

def _safe_join(base: Path, *parts: str) -> Path:
    tgt = (base / Path(*parts)).resolve()
    if not str(tgt).startswith(str(base.resolve())):
        raise PermissionError
    return tgt

def _human(size: int) -> str:
    for u in ("B","KB","MB","GB","TB"):
        if size < 1024: return f"{size:.0f} {u}"
        size /= 1024
    return f"{size:.0f} PB"

def _build_list_html():
    if not UPLOADS_DIR.exists(): return "<p>(uploads not found)</p>"
    rows=[]
    for p in sorted(UPLOADS_DIR.iterdir(), key=lambda x:(x.is_file(), x.name.lower())):
        name=html.escape(p.name)
        if p.is_dir():
            href=f"/download_folder/{p.name}/"; info="Folder"
        else:
            href=f"/download_file/{p.name}"
            try: info=_human(p.stat().st_size)
            except: info="file"
        rows.append(f"<li><a href='{href}'>{name}</a> <span style='opacity:.7'>— {info}</span></li>")
    return "<ul>\n"+"\n".join(rows)+"\n</ul>" if rows else "<p>(kosong)</p>"

def _get_list_html_cached():
    global _last_list_html, _last_list_at
    now=time.time()
    if _last_list_html and (now-_last_list_at) < LIST_TTL:
        return _last_list_html
    _last_list_html=_build_list_html(); _last_list_at=now
    return _last_list_html

def _parse_rate_from_query(query: str, default_rate: int, default_burst: int):
    q = urllib.parse.parse_qs(query or "", keep_blank_values=True)
    def get_int(name, default):
        try:
            v = int((q.get(name, [default])[0] or default))
            return max(1, v)
        except Exception:
            return default
    return get_int("rate", default_rate), get_int("burst", default_burst)

def _throttled_copy(rf, wf, total_len=None, *, target_rate_mbps: int, chunk: int = CHUNK, burst_mb: int = 8):
    rate_bps   = max(1, int(target_rate_mbps * 1024 * 1024))
    bucket_cap = int(burst_mb * 1024 * 1024)
    tokens     = bucket_cap
    sent = 0
    last = time.perf_counter()

    while True:
        to_read = min(chunk, (total_len - sent) if total_len is not None else chunk)
        if to_read <= 0: break
        data = rf.read(to_read)
        if not data: break

        wf.write(data)
        sent += len(data)
        tokens -= len(data)

        now = time.perf_counter()
        elapsed = now - last
        last = now

        tokens = min(bucket_cap, tokens + int(rate_bps * elapsed))
        if tokens < 0:
            need = -tokens
            sleep_s = need / rate_bps
            time.sleep(min(0.030, max(0.0, sleep_s)))

class App(SimpleHTTPRequestHandler):
    web_root = Path(__file__).resolve().parent
    protocol_version = "HTTP/1.1" 

    def translate_path(self, path: str) -> str:
        rel = Path(urllib.parse.urlparse(path).path.lstrip("/"))
        return str((self.web_root / rel).resolve())

    def _send_headers_common(self, code:int, *, ctype:str, disposition:str, length:int=None, extra:dict=None):
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Connection", "keep-alive")
        self.send_header("Keep-Alive", "timeout=5, max=1000")
        self.send_header("Content-Disposition", f'{disposition}; filename="{self._safe_name}"')
        self.send_header("Accept-Ranges", "bytes")
        if length is not None:
            self.send_header("Content-Length", str(length))
        if extra:
            for k, v in extra.items():
                self.send_header(k, v)
        self.end_headers()

    def _stream_whole(self, fp:Path, ctype:str, *, disposition:str="inline",
                      head_only:bool=False, rate_mbps:int=TARGET_RATE_MBPS, burst_mb:int=8):
        with _transfer_sem:
            self._safe_name = fp.name
            size = fp.stat().st_size
            self._send_headers_common(200, ctype=ctype, disposition=disposition, length=size)
            if head_only: return
            with fp.open("rb") as f:
                _throttled_copy(f, self.wfile, total_len=size, target_rate_mbps=rate_mbps, burst_mb=burst_mb)

    def _stream_range(self, fp:Path, ctype:str, range_header:str, *,
                      head_only:bool=False, rate_mbps:int=STREAM_RATE_MBPS_DEFAULT, burst_mb:int=STREAM_BURST_MB_DEFAULT):
        size = fp.stat().st_size
        start, end = 0, size - 1
        try:
            unit, rng = range_header.split("=",1)
            if unit.strip() != "bytes": raise ValueError
            s, e = (rng.split("-",1)+[""])[:2]
            if s: start = int(s)
            if e: end   = int(e)
        except Exception:
            self.send_response(416); self.send_header("Content-Range", f"bytes */{size}"); self.end_headers(); return
        if start > end or start >= size:
            self.send_response(416); self.send_header("Content-Range", f"bytes */{size}"); self.end_headers(); return

        length = end - start + 1
        with _transfer_sem:
            self._safe_name = fp.name
            self._send_headers_common(206, ctype=ctype, disposition="inline", length=length,
                                      extra={"Content-Range": f"bytes {start}-{end}/{size}"})
            if head_only: return
            with fp.open("rb") as f:
                f.seek(start)
                _throttled_copy(f, self.wfile, total_len=length, target_rate_mbps=rate_mbps, burst_mb=burst_mb)

    def do_HEAD(self): self._handle_request(head_only=True)
    def do_GET(self):  self._handle_request(head_only=False)

    def _handle_request(self, head_only: bool):
        parsed = urllib.parse.urlparse(self.path)
        path, query = parsed.path, parsed.query

        if path in ("/files.html","/files"):
            tpl=self.web_root/"files.html"
            body=tpl.read_text(encoding="utf-8").replace("{FILELIST}", _get_list_html_cached()).encode()
            self.send_response(200)
            self.send_header("Content-Type","text/html; charset=utf-8")
            self.send_header("Cache-Control","no-store")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            if not head_only: self.wfile.write(body)
            return

        if path == "/list_html":
            html_body = _get_list_html_cached().encode()
            self.send_response(200)
            self.send_header("Content-Type","text/html; charset=utf-8")
            self.send_header("Cache-Control","no-store")
            self.send_header("Content-Length", str(len(html_body)))
            self.end_headers()
            if not head_only: self.wfile.write(html_body)
            return

        if path == "/events":
            self.send_response(200)
            self.send_header("Content-Type","text/event-stream")
            self.send_header("Cache-Control","no-store")
            self.send_header("Connection","keep-alive")
            self.end_headers()

            q = SimpleQueue()
            with _subscribers_lock:
                _subscribers.add(q)

            try:
                self.wfile.write(b"event: ping\ndata: start\n\n")
                self.wfile.flush()

                while True:
                    try:
                        _ = q.get(timeout=15)
                        self.wfile.write(b"event: refresh\ndata: now\n\n")
                    except Empty:
                        self.wfile.write(b": keepalive\n\n")
                    self.wfile.flush()
            except Exception:
                pass
            finally:
                with _subscribers_lock:
                    _subscribers.discard(q)
            return

        if path.startswith("/uploads/"):
            fname=urllib.parse.unquote(path[len("/uploads/"):]).lstrip("/")
            try: fp=_safe_join(UPLOADS_DIR,fname)
            except: self.send_response(400); self.end_headers(); return
            if not fp.exists() or not fp.is_file(): self.send_response(404); self.end_headers(); return

            ctype=mimetypes.guess_type(str(fp))[0] or "application/octet-stream"
            ext=fp.suffix.lower()
            is_streamable = ext in (".mp4",".webm",".mkv",".avi",".mp3",".wav",".ogg")
            req_rate, req_burst = _parse_rate_from_query(query, STREAM_RATE_MBPS_DEFAULT, STREAM_BURST_MB_DEFAULT)

            rng = self.headers.get("Range")
            if rng and is_streamable:
                self._stream_range(fp, ctype, rng, head_only=head_only, rate_mbps=req_rate, burst_mb=req_burst); return

            disp="inline" if ext in INLINE_EXTS else "attachment"
            self._stream_whole(fp, ctype, disposition=disp, head_only=head_only,
                               rate_mbps=TARGET_RATE_MBPS, burst_mb=max(req_burst, 8))
            return
        
        if path.startswith("/download_file/"):
            fname=urllib.parse.unquote(path[len("/download_file/"):]).lstrip("/")
            try: fp=_safe_join(UPLOADS_DIR,fname)
            except: self.send_response(400); self.end_headers(); return
            if not fp.exists() or not fp.is_file(): self.send_response(404); self.end_headers(); return
            ctype=mimetypes.guess_type(str(fp))[0] or "application/octet-stream"
            self._stream_whole(fp, ctype, disposition="attachment", head_only=head_only,
                               rate_mbps=TARGET_RATE_MBPS, burst_mb=12)
            return

        if path.startswith("/download_folder/"):
            folder=urllib.parse.unquote(path[len("/download_folder/"):].rstrip("/")).lstrip("/")
            try: dirp=_safe_join(UPLOADS_DIR,folder)
            except: self.send_response(400); self.end_headers(); return
            if not dirp.is_dir(): self.send_response(404); self.end_headers(); return
            with _zip_sem:
                with tempfile.NamedTemporaryFile(delete=False, suffix=".zip") as tmp: tmp_name=tmp.name
                try:
                    with zipfile.ZipFile(tmp_name,"w",zipfile.ZIP_STORED) as zf:
                        for root,_,files in os.walk(dirp):
                            for fn in files:
                                fp=Path(root)/fn
                                arc=fp.relative_to(dirp)
                                try: zf.write(str(fp), str(arc))
                                except: pass
                    zp=Path(tmp_name)
                    size=zp.stat().st_size
                    self.send_response(200)
                    self.send_header("Content-Type","application/zip")
                    self.send_header("Content-Disposition", f'attachment; filename="{dirp.name}.zip"')
                    self.send_header("Content-Length", str(size))
                    self.end_headers()
                    if not head_only:
                        with zp.open("rb") as f:
                            _throttled_copy(f, self.wfile, total_len=size, target_rate_mbps=TARGET_RATE_MBPS, burst_mb=12)
                finally:
                    try: os.unlink(tmp_name)
                    except: pass
            return

        if head_only:
            full = Path(self.translate_path(path))
            if full.exists() and full.is_file():
                ctype = mimetypes.guess_type(str(full))[0] or "application/octet-stream"
                self.send_response(200)
                self.send_header("Content-Type", ctype)
                self.send_header("Content-Length", str(full.stat().st_size))
                self.end_headers()
            else:
                self.send_response(404); self.end_headers()
            return
        return super().do_GET()

    def do_PUT(self):
        if self.path == "/__FORGET_FLAG.txt":
            try:
                length = int(self.headers.get("Content-Length") or 0)
            except ValueError:
                length = 0
            if length:
                _ = self.rfile.read(length)
            self.send_response(200); self.end_headers(); self.wfile.write(b"OK")
        else:
            self.send_response(405); self.end_headers()

class _FSHandler(FileSystemEventHandler):
    def on_any_event(self, event):
        global _last_list_html, _last_list_at
        _last_list_html = ""    
        _last_list_at = 0.0
        _notify_all()

if __name__=="__main__":
    UPLOADS_DIR.mkdir(parents=True, exist_ok=True)

    observer = Observer()
    handler = _FSHandler()
    observer.schedule(handler, str(UPLOADS_DIR), recursive=True)
    observer.start()

    httpd = ThreadingHTTPServer(("", PORT), App)
    httpd.daemon_threads = True

    cert = os.getenv("HTTPS_CERT")
    key  = os.getenv("HTTPS_KEY")
    scheme = "http"
    if cert and key and os.path.exists(cert) and os.path.exists(key):
        import ssl
        ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        ctx.load_cert_chain(certfile=cert, keyfile=key)
        httpd.socket = ctx.wrap_socket(httpd.socket, server_side=True)
        scheme = "https"

    print(f"Serving on {scheme}://0.0.0.0:{PORT} | uploads={UPLOADS_DIR}")
    print(f"Limits: transfers={MAX_CONCURRENT_TRANSFERS}, download_rate={TARGET_RATE_MBPS} MB/s, zip_parallel={MAX_CONCURRENT_ZIPS}")
    print(f"Streaming defaults: {STREAM_RATE_MBPS_DEFAULT} MB/s, burst {STREAM_BURST_MB_DEFAULT} MB (override with ?rate=&burst=)")

    try:
        httpd.serve_forever()
    finally:
        observer.stop()
        observer.join()
