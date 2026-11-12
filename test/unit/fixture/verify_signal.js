const {spawn} = require('child_process');
const fs = require('fs');
const {constants} = require('os');
const p = spawn(process.argv[3], process.argv.slice(4), {detached: true, stdio: 'inherit'});
const started = Date.now();
const deadline = Date.now() + Number(process.env.SIGNAL_READY_MS || 5000);
const timer = setInterval(() => {
    if (fs.existsSync(process.env.SIGNAL_STATE + '/ready')) {
        clearInterval(timer);
        if (process.env.SIGNAL_TRACE === '1') console.log('ready-pid=' + p.pid + ' elapsed-ms=' + (Date.now() - started));
        process.kill(-p.pid, 'SIG' + process.argv[2]);
        if (process.env.SIGNAL_TRACE === '1') console.log('sent=SIG' + process.argv[2] + ' pgid=' + p.pid);
    } else if (Date.now() > deadline) {
        clearInterval(timer);
        process.kill(-p.pid, 'SIGKILL');
    }
}, 10);
const repeat = setInterval(() => {
    if (process.env.SIGNAL_REPEAT === '1' && fs.existsSync(process.env.SIGNAL_STATE + '/cleanup-ready')) {
        clearInterval(repeat);
        process.kill(-p.pid, 'SIG' + process.argv[2]);
    }
}, 10);
const watchdog = setTimeout(() => process.kill(-p.pid, 'SIGKILL'), Number(process.env.SIGNAL_WATCHDOG_MS || 6000));
p.on('exit', (code, signal) => {
    clearInterval(timer);
    clearInterval(repeat);
    clearTimeout(watchdog);
    console.log('exit-signal=' + (signal || 'none'));
    console.log('rc=' + (code === null ? 128 + constants.signals[signal] : code));
});
