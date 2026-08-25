// 飞行记录仪：node -r tracer.js 预加载，把应用的一举一动写到 /tmp/ukc-trace.log
const fs = require('fs');
const http = require('http');
const https = require('https');
const cp = require('child_process');
const os = require('os');

const LOG = '/tmp/ukc-trace.log';
let fd;
try { fd = fs.openSync(LOG, 'w'); } catch (e) { fd = fs.openSync('/tmp/ukc-trace2.log', 'w'); }
const log = (...a) => { try { fs.writeSync(fd, a.join(' ') + '\n'); } catch (e) {} };

log('=== tracer 启动', new Date().toISOString(), 'node', process.version, '===');
log('cwd =', process.cwd());
log('uid =', os.userInfo ? (() => { try { return os.userInfo().uid; } catch (e) { return '?'; } })() : '?');

// 关键：测试哪些路径可写
for (const p of ['/.wtest', '/tmp/.wtest', process.cwd() + '/.wtest', '/app/.wtest']) {
  try { fs.writeFileSync(p, 'x'); fs.unlinkSync(p); log('可写:', p, '✓'); } catch (e) { log('可写:', p, '✗', e.code); }
}

// 网络钩子
for (const mod of [http, https]) {
  const orig = mod.request;
  mod.request = function (u, o, cb) {
    let url = '';
    if (typeof u === 'string') url = u;
    else if (u && u.href) url = u.href;
    else if (o && (o.host || o.hostname)) url = 'http' + (mod === https ? 's' : '') + '://' + (o.hostname || o.host) + (o.path || (u && u.path) || '');
    else if (u && (u.hostname || u.host)) url = 'http' + (mod === https ? 's' : '') + '://' + (u.hostname || u.host) + (u.path || '');
    const t0 = Date.now();
    log('[REQ]', url || '(空)');
    try {
      const req = orig.apply(this, [u, o, cb]);
      req.on('error', (e) => log('[REQ-ERR]', url.slice(0, 80), e.code || e.message, Date.now() - t0 + 'ms'));
      const origCb = cb;
      if (typeof origCb === 'function') {
        arguments[2] = function (r) { log('[RES]', r.statusCode, url.slice(0, 80), Date.now() - t0 + 'ms'); return origCb(r); };
      }
      return req;
    } catch (e) { log('[REQ-THROW]', e.message); throw e; }
  };
}

// 子进程钩子
for (const fn of ['exec', 'execSync', 'spawn', 'spawnSync', 'execFile']) {
  const orig = cp[fn];
  if (!orig) continue;
  cp[fn] = function (cmd, ...r) {
    log('[CP.' + fn + ']', String(cmd).slice(0, 200));
    return orig.apply(this, [cmd, ...r]);
  };
}

process.on('uncaughtException', (e) => log('[uncaught]', (e.stack || e.message || '').slice(0, 400)));
process.on('unhandledRejection', (e) => log('[rejection]', (e && e.stack || String(e)).slice(0, 400)));
const oe = process.exit;
process.exit = function (c) { log('[process.exit]', c, new Error().stack.split('\n').slice(1, 4).join(' | ')); return oe.call(this, c); };
process.on('exit', (c) => log('[exit]', c));
