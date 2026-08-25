#!/usr/bin/env python3
"""可选首页前置层（Python 应用用）：
/ 和 /index.html 返回 index.html，其余 HTTP 请求转发给你的应用(:PORT+10)。
注意：不支持 WebSocket 透传（Node 版支持）。
"""
import http.server
import os
import subprocess
import sys
import urllib.error
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
PORT = int(os.environ.get('PORT', '3000'))
BACK = PORT + 10
HTML = open(os.path.join(HERE, 'index.html'), 'rb').read()
SKIP_REQ = {'host', 'content-length', 'connection', 'accept-encoding'}
SKIP_RESP = {'connection', 'transfer-encoding'}

# 启动真正的应用（入口：环境变量 PY_ENTRY 优先，否则按 main.py/app.py/index.py 探测）
ENTRY = os.environ.get('PY_ENTRY', '')
if ENTRY not in ('main.py', 'app.py', 'index.py'):
    ENTRY = next((f for f in ('main.py', 'app.py', 'index.py')
                  if os.path.exists(os.path.join(HERE, f))), 'main.py')
# stdout/stderr 必须 DEVNULL：继承控制台 fd 在 unikernel 下可能卡死进程
subprocess.Popen([sys.executable, '-u', ENTRY],
                 cwd=HERE, env={**os.environ, 'PORT': str(BACK)},
                 stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'

    def _page(self):
        self.send_response(200)
        self.send_header('Content-Type', 'text/html; charset=utf-8')
        self.send_header('Content-Length', str(len(HTML)))
        self.send_header('Cache-Control', 'no-cache')
        self.end_headers()
        if self.command != 'HEAD':
            self.wfile.write(HTML)

    def _fwd(self):
        body = None
        n = self.headers.get('Content-Length')
        if n:
            body = self.rfile.read(int(n))
        req = urllib.request.Request('http://127.0.0.1:%d%s' % (BACK, self.path),
                                     data=body, method=self.command)
        for k, v in self.headers.items():
            if k.lower() not in SKIP_REQ:
                req.add_header(k, v)
        try:
            with urllib.request.urlopen(req, timeout=60) as r:
                data = r.read()
                status, headers = r.status, r.headers.items()
        except urllib.error.HTTPError as e:
            data = e.read()
            status, headers = e.code, e.headers.items()
        except Exception:
            data, status, headers = b'bad gateway', 502, []
        try:
            self.send_response(status)
            sent_len = False
            for k, v in headers:
                if k.lower() in SKIP_RESP or k.lower() == 'content-length':
                    continue
                self.send_header(k, v)
            self.send_header('Content-Length', str(len(data)))
            self.end_headers()
            if self.command != 'HEAD':
                self.wfile.write(data)
        except Exception:
            pass

    def route(self):
        u = (self.path or '/').split('?')[0]
        if u in ('/', '/index.html'):
            self._page()
        else:
            self._fwd()

    do_GET = do_POST = do_PUT = do_DELETE = do_PATCH = do_HEAD = route

    def log_message(self, *a):  # 静音访问日志
        pass


if __name__ == '__main__':
    print('front :%d -> app :%d' % (PORT, BACK))
    http.server.ThreadingHTTPServer(('0.0.0.0', PORT), Handler).serve_forever()
