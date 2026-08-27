// 前置入口 v2：/ 返回 home.html；/__trace 返回飞行记录仪日志；其余转发原应用(:3010)
// 修复：给原应用显式指定可写的 cwd 和 FILE_PATH（之前继承的 cwd 可能只读，导致
// 应用把 .tmp/ 下载文件写失败，xray/cloudflared 起不来，/sub 永远 404、CPU 为 0）
const { spawn } = require('child_process');
const http = require('http');
const net = require('net');
const fs = require('fs');
const path = require('path');

const BACK_PORT = 3010;
const FRONT_PORT = parseInt(process.env.PORT || process.env.SERVER_PORT || '3000', 10);
const HTML = fs.readFileSync(path.join(__dirname, 'home.html'));
const TRACE = '/tmp/ukc-trace.log';
const TRACE_KEY = process.env.TRACE_KEY || '';

// 启动原应用：预载 tracer，固定可写 cwd，FILE_PATH 指到可写绝对路径
spawn(process.execPath, ['-r', '/tmp/tracer.js', path.join(__dirname, 'orig-app.js')], {
  cwd: '/tmp',
  env: { ...process.env, PORT: String(BACK_PORT), SERVER_PORT: String(BACK_PORT), FILE_PATH: '/tmp/.tmp' },
  stdio: 'ignore',
});

function proxy(req, res) {
  const p = http.request(
    { host: '127.0.0.1', port: BACK_PORT, path: req.url, method: req.method, headers: req.headers },
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
  if (u === '/__trace') {
    // 鉴权：设了 TRACE_KEY 环境变量后须 ?key=<TRACE_KEY> 才能看；未设则直接 404（关闭）。
    // tracer 日志含出站 URL、子进程命令等敏感信息，不能裸奔
    const key = new URL(req.url, 'http://x').searchParams.get('key');
    if (!TRACE_KEY || key !== TRACE_KEY) {
      res.writeHead(404, { 'Content-Type': 'text/plain' });
      return res.end('Not Found');
    }
    let t = '';
    try { t = fs.readFileSync(TRACE, 'utf8'); } catch (e) { t = '(无日志) ' + e.message; }
    res.writeHead(200, { 'Content-Type': 'text/plain; charset=utf-8' });
    return res.end(t);
  }
  proxy(req, res);
});

server.on('upgrade', (req, socket, head) => {
  const up = net.connect(BACK_PORT, '127.0.0.1', () => {
    let raw = `${req.method} ${req.url} HTTP/1.1\r\nHost: 127.0.0.1:${BACK_PORT}\r\n`;
    for (let i = 0; i < req.rawHeaders.length; i += 2) {
      if (/^host$/i.test(req.rawHeaders[i])) continue;
      raw += `${req.rawHeaders[i]}: ${req.rawHeaders[i + 1]}\r\n`;
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

server.listen(FRONT_PORT, () => console.log(`front :${FRONT_PORT} -> app :${BACK_PORT}`));
