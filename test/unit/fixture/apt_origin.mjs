// apt_origin.mjs - fixture for test/unit/apt_seed_proxy_spec.bats (#892).
//
//   node apt_origin.mjs origin <dir> <log> <port_file>
//       a plain HTTP origin: serves <dir>/<path> (404 when absent), appends
//       every request path to <log>, writes its port to <port_file>. The
//       path ending in `truncated_1_amd64.deb` announces 100 bytes, sends 5
//       and drops the connection.
//   node apt_origin.mjs get <proxy_port> <url> <out> [HEAD]
//       one request through the proxy at 127.0.0.1:<proxy_port>, the body
//       written to <out>; prints the status code (or `error`).
import { appendFileSync, createReadStream, statSync, writeFileSync, createWriteStream } from 'node:fs';
import http from 'node:http';
import path from 'node:path';

const [mode, ...args] = process.argv.slice(2);

if (mode === 'origin') {
    const [dir, logFile, portFile] = args;
    const server = http.createServer((req, res) => {
        const p = new URL(req.url, 'http://origin').pathname;
        appendFileSync(logFile, `${p}\n`);
        if (p.endsWith('truncated_1_amd64.deb')) {
            res.writeHead(200, { 'content-length': 100 });
            res.write('short');
            setTimeout(() => res.destroy(), 50);
            return;
        }
        const file = path.join(dir, p);
        let size;
        try {
            size = statSync(file).size;
        } catch {
            res.writeHead(404);
            res.end();
            return;
        }
        res.writeHead(200, { 'content-length': size });
        createReadStream(file).pipe(res);
    });
    server.listen(0, '127.0.0.1', () => writeFileSync(portFile, `${server.address().port}\n`));
} else if (mode === 'get') {
    const [port, url, out, method] = args;
    const req = http.request({ host: '127.0.0.1', port: Number(port), method: method || 'GET', path: url, headers: { host: url.startsWith('http://') ? new URL(url).host : '127.0.0.1' } }, (res) => {
        const w = createWriteStream(out);
        res.pipe(w);
        res.on('end', () => w.end(() => process.stdout.write(`${res.statusCode}\n`)));
        res.on('error', () => process.stdout.write('error\n'));
    });
    req.on('error', () => process.stdout.write('error\n'));
    req.end();
} else {
    process.stderr.write('apt_origin.mjs: origin|get\n');
    process.exit(2);
}
