const {spawn} = require('child_process');
const fs = require('fs');
for (const sig of ['SIGINT', 'SIGTERM', 'SIGHUP']) process.on(sig, () => {});
let worker;
let closed = false;
let exited = false;
let result;
let emptyScans = 0;
function otherMembers() {
    return fs.readdirSync('/proc').some((name) => {
        if (!/^\d+$/.test(name) || Number(name) === process.pid) return false;
        try {
            const stat = fs.readFileSync('/proc/' + name + '/stat', 'utf8');
            const fields = stat.slice(stat.lastIndexOf(')') + 2).split(' ');
            return Number(fields[2]) === process.pid && fields[0] !== 'Z';
        } catch (error) {
            if (error.code === 'ENOENT' || error.code === 'ESRCH') return false;
            throw error;
        }
    });
}
function send(message, done) {
    if (!process.connected) { process.kill(0, 'SIGKILL'); return; }
    process.send(message, (error) => {
        if (error) process.kill(0, 'SIGKILL');
        else if (done) done();
    });
}
try {
    worker = spawn(process.argv[2], process.argv.slice(3), {stdio: ['ignore', 'pipe', 'pipe']});
} catch (error) {
    send({type: 'worker-error', error: error.message}, () => process.kill(0, 'SIGKILL'));
}
if (worker) {
    worker.stdout.pipe(process.stdout, {end: false});
    worker.stderr.pipe(process.stderr, {end: false});
    worker.on('spawn', () => send({type: 'worker-start', pid: worker.pid, pgid: process.pid}));
    worker.on('error', (error) => send({type: 'worker-error', error: error.message}, () => process.kill(0, 'SIGKILL')));
    worker.on('exit', (code, signal) => {
        exited = true;
        send({type: 'worker-exit', code, signal});
    });
    worker.on('close', (code, signal) => {
        closed = true;
        result = {code, signal};
    });
}
process.on('message', (message) => {
    if (message.type === 'signal') {
        if (exited || closed || !['SIGINT', 'SIGTERM', 'SIGHUP'].includes(message.signal)) {
            send({type: 'signal-refused'});
            return;
        }
        setTimeout(() => {
            if (exited || closed) { send({type: 'signal-refused'}); return; }
            process.kill(0, message.signal);
            send({type: 'sent', signal: message.signal, pgid: process.pid, id: message.id, delay: message.delay});
        }, message.delay || 0);
    } else if (message.type === 'stop') {
        send({type: 'stopping', phase: message.phase}, () => process.kill(0, 'SIGKILL'));
    } else if (message.type === 'finish' && closed) {
        let pending = 2;
        const flushed = () => {
            if (--pending === 0) send({type: 'finished'}, () => process.exit(0));
        };
        process.stdout.write('', flushed);
        process.stderr.write('', flushed);
    }
});
const drain = setInterval(() => {
    if (!result) return;
    try {
        emptyScans = otherMembers() ? 0 : emptyScans + 1;
        if (emptyScans >= 2) {
            clearInterval(drain);
            send({type: 'worker-close', ...result});
        }
    } catch (error) {
        send({type: 'scan-error', error: error.message}, () => process.kill(0, 'SIGKILL'));
    }
}, 10);
process.on('disconnect', () => process.kill(0, 'SIGKILL'));
