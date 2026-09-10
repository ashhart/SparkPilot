'use strict';
// Runs inside the project container; stop only processes carrying this session's exact identity.
const fs = require('node:fs');
const id = process.argv[2];
if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/.test(id || '')) process.exit(2);
const tag = `SPARK_TERMINAL_ID=${id}`;
function owned() {
    return fs.readdirSync('/proc').filter(p => /^\d+$/.test(p) && Number(p) !== process.pid).filter(p => {
        try {
            if (fs.statSync(`/proc/${p}`).uid !== process.getuid()) return false;
            const stat = fs.readFileSync(`/proc/${p}/stat`, 'utf8');
            if (stat.slice(stat.lastIndexOf(')') + 2).startsWith('Z ')) return false;
            return fs.readFileSync(`/proc/${p}/environ`).toString().split('\0').includes(tag);
        } catch (e) {
            if (e.code === 'ENOENT' || e.code === 'ESRCH') return false;
            throw e;
        }
    });
}
async function stop() {
    for (const signal of ['SIGTERM', 'SIGKILL']) {
        for (const pid of owned()) {
            try { process.kill(Number(pid), signal); }
            catch (e) { if (e.code !== 'ESRCH') throw e; }
        }
        const deadline = Date.now() + 1500;
        while (Date.now() < deadline) {
            if (owned().length === 0) return;
            await new Promise(resolve => setTimeout(resolve, 25));
        }
    }
    if (owned().length) throw new Error('Session processes remain');
}
stop().catch(() => { process.stderr.write('Session termination could not be confirmed\n'); process.exitCode = 1; });
