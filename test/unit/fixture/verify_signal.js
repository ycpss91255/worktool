const {spawn} = require('child_process');
const fs = require('fs');
const {constants} = require('os');
const signal = 'SIG' + process.argv[2];
const signalDelay = Number(process.env.SIGNAL_DELAY_MS || 0);
const delayMax = Number(process.env.SIGNAL_DELAY_MAX_MS || 0);
const pollMs = Number(process.env.SIGNAL_POLL_MS || 10);
if (!['SIGINT', 'SIGTERM', 'SIGHUP'].includes(signal)) {
    console.error('invalid-signal');
    process.exit(2);
}
if (!Number.isInteger(signalDelay) || signalDelay < 0 || signalDelay > 1000 ||
    !Number.isInteger(delayMax) || delayMax < 0 || delayMax > 1000 ||
    !Number.isInteger(pollMs) || pollMs < 1 || pollMs > 1000) process.exit(2);
function delay() { return signalDelay || (delayMax ? Math.floor(Math.random() * delayMax) : 0); }
const started = Date.now();
let p, readyTimer, ackTimer, cleanupTimer, finalTimer;
let phase = 'startup', workerPid, workerExit, sent = false, repeatSent = false, repeatAck = false, result, finished = false, failed = false;
function finishFail(reason) {
    if (failed) return;
    failed = true;
    console.log(reason);
    process.exitCode = 1;
    if (p && p.connected) send({type: 'stop', phase: reason});
    finalTimer = setTimeout(() => {
        console.log('anchor-exit-timeout=1');
        if (!workerExit) console.log('worker-status=unknown');
        if (p) { p.stdout.destroy(); p.stderr.destroy(); if (p.connected) p.disconnect(); p.unref(); }
        process.exit(1);
    }, 2000);
}
function send(message) {
    if (!p.connected) { finishFail('ipc-disconnected=1'); return; }
    try {
        p.send(message, (error) => { if (error) finishFail('ipc-send-error=' + error.message); });
    } catch (error) { finishFail('ipc-send-error=' + error.message); }
}
try {
    p = spawn(process.execPath, [process.env.SIGNAL_ANCHOR || __dirname + '/verify_signal_anchor.js', process.argv[3], ...process.argv.slice(4)], {
        detached: true, stdio: ['ignore', 'pipe', 'pipe', 'ipc']
    });
} catch (error) { console.error('anchor-spawn-error=' + error.message); process.exit(1); }
p.stdout.pipe(process.stdout, {end: false});
p.stderr.pipe(process.stderr, {end: false});
p.on('error', (error) => finishFail('anchor-spawn-error=' + error.message));
const readyMs = Number(process.env.SIGNAL_READY_MS || 5000);
const cleanupMs = Number(process.env.SIGNAL_CLEANUP_MS || process.env.SIGNAL_WATCHDOG_MS || 15000);
readyTimer = setInterval(() => {
    if (fs.existsSync(process.env.SIGNAL_STATE + '/ready') && workerPid) {
        clearInterval(readyTimer);
        phase = 'signal';
        console.log('ready-pid=' + workerPid + ' pgid=' + p.pid + ' elapsed-ms=' + (Date.now() - started));
        send({type: 'signal', signal, id: 1, delay: delay()});
        ackTimer = setTimeout(() => finishFail('signal-ack-timeout=1'), 2000);
    } else if (Date.now() - started >= readyMs) {
        clearInterval(readyTimer);
        finishFail('timeout-phase=ready');
    }
}, pollMs);
const repeat = setInterval(() => {
    if (phase === 'cleanup' && process.env.SIGNAL_REPEAT === '1' && fs.existsSync(process.env.SIGNAL_STATE + '/cleanup-ready')) {
        clearInterval(repeat);
        repeatSent = true;
        send({type: 'signal', signal, id: 2, delay: delay()});
        ackTimer = setTimeout(() => finishFail('repeat-ack-timeout=1'), 2000);
    }
}, pollMs);
p.on('message', (message) => {
    if (message.type === 'worker-start') workerPid = message.pid;
    else if (message.type === 'worker-exit') {
        workerExit = message;
        console.log('worker-exit-signal=' + (message.signal || 'none'));
        console.log('worker-rc=' + (message.code === null ? 128 + constants.signals[message.signal] : message.code));
    }
    else if (message.type === 'scan-error') finishFail('scan-error=' + message.error);
    else if (message.type === 'worker-error') finishFail('worker-error=' + message.error);
    else if (message.type === 'signal-refused') finishFail('signal-refused=1');
    else if (message.type === 'sent') {
        console.log('sent=' + message.signal + ' pgid=' + message.pgid + ' delay-ms=' + message.delay + ' id=' + message.id + ' elapsed-ms=' + (Date.now() - started));
        if (message.id === 2) { repeatAck = true; clearTimeout(ackTimer); }
        if (message.id === 1 && !sent) {
            sent = true; clearTimeout(ackTimer); phase = 'cleanup';
            cleanupTimer = setTimeout(() => finishFail('timeout-phase=cleanup'), cleanupMs);
        }
    } else if (message.type === 'worker-close') {
        if (!sent || (process.env.SIGNAL_REPEAT === '1' && (!repeatSent || !repeatAck))) {
            finishFail('worker-closed-before-signal=1'); return;
        }
        if (failed) return;
        result = message;
        clearTimeout(cleanupTimer);
        phase = 'finishing';
        send({type: 'finish'});
        finalTimer = setTimeout(() => finishFail('anchor-exit-timeout=1'), 15000);
    } else if (message.type === 'finished') finished = true;
});
p.on('disconnect', () => { if (!finished && !failed) finishFail('anchor-disconnected=1'); });
p.on('exit', () => {
    if (!finalTimer) finalTimer = setTimeout(() => finishFail('anchor-exit-timeout=1'), 2000);
});
p.on('close', () => {
    clearInterval(readyTimer); clearInterval(repeat);
    clearTimeout(ackTimer); clearTimeout(cleanupTimer); clearTimeout(finalTimer);
    if (!finished || !result || failed) {
        if (!failed) console.log('anchor-lost=1');
        if (!workerExit) console.log('worker-status=unknown');
        process.exitCode = 1;
    } else {
        console.log('exit-signal=' + (result.signal || 'none'));
        console.log('rc=' + (result.code === null ? 128 + constants.signals[result.signal] : result.code));
    }
});
