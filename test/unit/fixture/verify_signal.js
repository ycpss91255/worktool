const {spawn} = require('child_process');
const fs = require('fs');
const {constants} = require('os');
const p = spawn(process.argv[3], process.argv.slice(4), {detached: true, stdio: 'inherit'});
const deadline = Date.now() + 5000;
const timer = setInterval(() => {
    if (fs.existsSync(process.env.SIGNAL_STATE + '/ready')) {
        clearInterval(timer);
        process.kill(-p.pid, 'SIG' + process.argv[2]);
    } else if (Date.now() > deadline) {
        clearInterval(timer);
        process.kill(-p.pid, 'SIGKILL');
    }
}, 10);
const watchdog = setTimeout(() => process.kill(-p.pid, 'SIGKILL'), 6000);
p.on('exit', (code, signal) => {
    clearInterval(timer);
    clearTimeout(watchdog);
    console.log('exit-signal=' + (signal || 'none'));
    console.log('rc=' + (code === null ? 128 + constants.signals[signal] : code));
});
