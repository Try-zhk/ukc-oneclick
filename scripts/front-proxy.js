// 可选首页前置层（Node 应用用）：
// / 和 /index.html 返回 index.html，其余所有请求（含 WebSocket）转发给你的应用。
// 你的应用以后台方式运行在 PORT+10 上。
const { spawn } = require('child_process');
const http = require('http');
const net = require('net');
const fs = require('fs');
const path = require('path');

const HERE = __dirname;
const PORT = parseInt(process.env.PORT || '3000', 10);
const BACK = PORT + 10;
const HTML = fs.readFileSync(path.join(HERE, 'index.html'));

// 启动真正的应用
// stdio 必须用 'ignore'：部分应用会劫持/改写自己的 stdout，继承控制台 fd
// 在 unikernel 环境下会把进程卡死（CPU 0%、无日志），别改回 inherit
spawn(process.execPath, ['index.js'], {
  cwd: HERE,
  env: { ...process.env, PORT: String(BACK) },
  stdio: 'ignore',
});

function proxy(req, res) {
  const p = http.request(
    { host: '127.0.0.1', port: BACK, path: req.url, method: req.method, headers: req.headers },
    (r) => { res.writeHead(r.statusCode, r.headers); r.pipe(res); }
  );
  p.on('error', () => { try { res.writeHead(502); res.end('bad gateway'); } catch (e) {} });
  req.pipe(p);
}

const server = http.createServer((req, res) => {
  const u = (req.url || '/').split('?')[0];
  if (u === '/' || u === '/index.html') {
    res.writeHead(200, {
      'Content-Type': 'text/html; charset=utf-8',
      'Content-Length': HTML.length,
      'Cache-Control': 'no-cache',
    });
    return res.end(req.method === 'HEAD' ? undefined : HTML);
  }
  proxy(req, res);
});

// WebSocket 透传
server.on('upgrade', (req, socket, head) => {
  const up = net.connect(BACK, '127.0.0.1', () => {
    const keep = {};
    for (let i = 0; i < req.rawHeaders.length; i += 2) {
      if (/^connection$|^upgrade$/i.test(req.rawHeaders[i])) keep[req.rawHeaders[i].toLowerCase()] = req.rawHeaders[i + 1];
    }
    let raw = `${req.method} ${req.url} HTTP/1.1\r\nHost: 127.0.0.1:${BACK}\r\n`;
    for (let i = 0; i < req.rawHeaders.length; i += 2) {
      const k = req.rawHeaders[i];
      if (/^host$/i.test(k)) continue;
      raw += `${k}: ${req.rawHeaders[i + 1]}\r\n`;
    }
    raw += '\r\n';
    up.write(raw);
    if (head && head.length) up.write(head);
    up.pipe(socket);
    socket.pipe(up);
  });
  up.on('error', () => socket.destroy());
  socket.on('error', () => up.destroy());
});

server.listen(PORT, () => console.log(`front :${PORT} -> app :${BACK}`));
