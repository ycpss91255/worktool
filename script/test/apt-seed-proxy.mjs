// apt-seed-proxy.mjs - a local HTTP proxy for CI's Ubuntu image builds that
// serves pool .deb files from a saved package dir (issue #892).
//
// A cold image build (the apt RUN layer missed the gha layer cache because
// a Dockerfile or the apt-mirror.sh it bind-mounts changed) downloads every
// package again, and the amd64 mirror serves packages it has not cached at
// ~100 kB/s (run 42819549766: 129 MB in 21 min). CI passes this proxy to
// the build as Docker's predefined `http_proxy` build arg, which is not part
// of the layer cache key and not written into the image, so the Dockerfile
// and its layers stay byte-identical and a warm build still hits the cache.
//
// Rules (fail closed: the proxy only ever saves a download, it never decides
// what apt installs):
//   - only a GET/HEAD of a pool file `<...>/pool/<...>/<name>.deb` is looked
//     up in --seed (then in --record, so a second image build of the same
//     run reuses what the first fetched), by file name; Debian file names carry the version, so a
//     stale seed is a miss, never an old package passed off as a new one.
//     apt still checks every file against the index hash.
//   - everything else (InRelease, Packages*, by-hash/, a .deb outside
//     pool/) goes to the origin untouched, so the indexes are always fresh.
//   - a miss goes to the origin the client named; its status (404, 5xx)
//     comes back unchanged, so apt's mirror list falls through to the next
//     source exactly as without the proxy (ADR-0022). An origin that cannot
//     be reached is a 502.
//   - with --record DIR, every pool .deb the client received complete
//     (a seed hit, or a 200 from the origin whose bytes match its
//     Content-Length) is written to DIR, so DIR ends up holding exactly what
//     a cold build needs.
//   - GET /__apt_seed/health -> 200 "ok"; GET /__apt_seed/stats -> JSON
//     counts. Only absolute http:// request targets are proxied; CONNECT and
//     other methods get 405.
//
// Usage: node apt-seed-proxy.mjs --port N --seed DIR [--record DIR] [--host ADDR] [--port-file FILE]
//   --port 0 takes a free port; --port-file receives the port listened on.
// Exit: 2 bad arguments; otherwise it serves until SIGTERM/SIGINT (exit 0).
// One line per request on stderr: `seed <name>`, `fetch <status> <url>`,
// `pass <status> <url>`, `error <url> <reason>`.

import { createReadStream, createWriteStream, existsSync, statSync, renameSync, rmSync, writeFileSync } from 'node:fs';
import { copyFile } from 'node:fs/promises';
import http from 'node:http';
import path from 'node:path';

const USAGE = 'Usage: node apt-seed-proxy.mjs --port N --seed DIR [--record DIR] [--host ADDR] [--port-file FILE]';

function die(msg) {
    process.stderr.write(`apt-seed-proxy.mjs: ${msg} (see --help)\n`);
    process.exit(2);
}

const opts = { host: '127.0.0.1', port: '', seed: '', record: '', portFile: '' };
const argv = process.argv.slice(2);
for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === '-h' || a === '--help') {
        process.stdout.write(`${USAGE}\n`);
        process.exit(0);
    }
    const key = { '--port': 'port', '--seed': 'seed', '--record': 'record', '--host': 'host', '--port-file': 'portFile' }[a];
    if (!key) die(`unknown option '${a}'`);
    if (i + 1 >= argv.length || argv[i + 1] === '') die(`${a} requires a value`);
    opts[key] = argv[++i];
}
if (!/^(0|[1-9][0-9]*)$/.test(opts.port) || Number(opts.port) > 65535) die(`--port must be 0-65535, got '${opts.port}'`);
for (const k of ['seed', 'record']) {
    if (k === 'record' && opts.record === '') continue;
    if (!path.isAbsolute(opts[k])) die(`--${k} must be an absolute path, got '${opts[k]}'`);
    if (!existsSync(opts[k]) || !statSync(opts[k]).isDirectory()) die(`--${k} is not a directory: '${opts[k]}'`);
}

const stats = { seed: 0, fetch: 0, pass: 0, error: 0, recorded: 0 };
const agent = new http.Agent({ keepAlive: true, maxSockets: 16 });
const log = (line) => process.stderr.write(`${line}\n`);

// The file name of a pool .deb, or '' for anything else. The name is
// decoded once and must be a plain Debian file name (no separator, no dots
// only), so it can never leave the seed or record dir.
function poolDeb(pathname) {
    const parts = pathname.split('/');
    if (!parts.includes('pool')) return '';
    let name;
    try {
        name = decodeURIComponent(parts[parts.length - 1]);
    } catch {
        return '';
    }
    return /^[A-Za-z0-9][A-Za-z0-9.+~_:%-]*\.deb$/.test(name) ? name : '';
}

const pending = new Set();
function record(name, from) {
    if (!opts.record) return;
    const p = copyFile(from, path.join(opts.record, name)).then(
        () => { stats.recorded++; },
        (err) => { stats.error++; log(`error record ${name} ${err.message}`); },
    );
    pending.add(p);
    p.finally(() => pending.delete(p));
}

// The seed copy of <name>, else one already recorded in this run (two
// images share most packages), else ''.
function seedFile(name) {
    for (const dir of [opts.seed, opts.record]) {
        if (!dir) continue;
        const file = path.join(dir, name);
        try {
            if (statSync(file).isFile()) return file;
        } catch {
            // not in this dir
        }
    }
    return '';
}

function serveSeed(req, res, name) {
    const file = seedFile(name);
    if (!file) return false;
    const size = statSync(file).size;
    stats.seed++;
    log(`seed ${name}`);
    res.writeHead(200, { 'content-type': 'application/vnd.debian.binary-package', 'content-length': size });
    if (req.method === 'HEAD') {
        res.end();
        return true;
    }
    createReadStream(file).pipe(res);
    if (req.method === 'GET' && path.dirname(file) !== opts.record) record(name, file);
    return true;
}

function forward(req, res, url, name) {
    const headers = { ...req.headers };
    for (const h of ['proxy-connection', 'proxy-authorization', 'connection', 'keep-alive']) delete headers[h];
    const up = http.request(url, { method: req.method, headers, agent }, (upRes) => {
        const status = upRes.statusCode || 502;
        const keep = name && opts.record && req.method === 'GET' && status === 200;
        log(`${name ? 'fetch' : 'pass'} ${status} ${url.href}`);
        stats[name ? 'fetch' : 'pass']++;
        res.writeHead(status, upRes.headers);
        if (!keep) {
            upRes.pipe(res);
            return;
        }
        const want = Number(upRes.headers['content-length'] ?? -1);
        const part = path.join(opts.record, `.${name}.${process.pid}.part`);
        const out = createWriteStream(part);
        let got = 0;
        upRes.on('data', (chunk) => {
            got += chunk.length;
            out.write(chunk);
            res.write(chunk);
        });
        upRes.on('end', () => {
            res.end();
            out.end(() => {
                if (want >= 0 && got === want) {
                    renameSync(part, path.join(opts.record, name));
                    stats.recorded++;
                } else {
                    rmSync(part, { force: true });
                }
            });
        });
        upRes.on('error', () => {
            out.destroy();
            rmSync(part, { force: true });
            res.destroy();
        });
    });
    up.on('error', (err) => {
        stats.error++;
        log(`error ${url.href} ${err.code || err.message}`);
        if (!res.headersSent) {
            res.writeHead(502, { 'content-type': 'text/plain' });
            res.end(`apt-seed-proxy: ${err.code || err.message}\n`);
        } else {
            res.destroy();
        }
    });
    req.pipe(up);
}

const server = http.createServer((req, res) => {
    if (req.url === '/__apt_seed/health') {
        res.writeHead(200, { 'content-type': 'text/plain' });
        res.end('ok\n');
        return;
    }
    if (req.url === '/__apt_seed/stats') {
        res.writeHead(200, { 'content-type': 'application/json' });
        res.end(`${JSON.stringify(stats)}\n`);
        return;
    }
    if (req.method !== 'GET' && req.method !== 'HEAD') {
        res.writeHead(405, { 'content-type': 'text/plain' });
        res.end('apt-seed-proxy: only GET and HEAD\n');
        return;
    }
    let url;
    try {
        url = new URL(req.url);
    } catch {
        url = null;
    }
    if (!url || url.protocol !== 'http:') {
        res.writeHead(400, { 'content-type': 'text/plain' });
        res.end('apt-seed-proxy: absolute http:// targets only\n');
        return;
    }
    const name = poolDeb(url.pathname);
    if (name && serveSeed(req, res, name)) return;
    forward(req, res, url, name);
});
server.on('connect', (_req, socket) => {
    socket.end('HTTP/1.1 405 Method Not Allowed\r\n\r\n');
});

function stop() {
    server.close();
    server.closeAllConnections();
    Promise.allSettled([...pending]).then(() => {
        log(`stats ${JSON.stringify(stats)}`);
        process.exit(0);
    });
}
process.on('SIGTERM', stop);
process.on('SIGINT', stop);

server.listen(Number(opts.port), opts.host, () => {
    const port = server.address().port;
    if (opts.portFile) writeFileSync(opts.portFile, `${port}\n`);
    log(`apt-seed-proxy: listening on ${opts.host}:${port}, seed ${opts.seed}${opts.record ? `, record ${opts.record}` : ''}`);
});
