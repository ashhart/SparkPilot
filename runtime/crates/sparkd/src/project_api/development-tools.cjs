'use strict';
const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const { spawn } = require('node:child_process');
const PINNED = { oh_my_pi: '18.1.12', pi: '0.73.1', open_code: '1.18.29', claude_code: '2.1.261', codex: '0.153.4' };
const NAMES = { oh_my_pi: 'Oh My Pi', pi: 'Pi', open_code: 'OpenCode', claude_code: 'Claude Code', codex: 'Codex' };

// flock replaces itself with the worker, so lock ownership lasts through cleanup and publication.
function prepare(root, config, id, env, job, current, signal) {
    signal?.throwIfAborted();
    const tools = path.join(root, '.spark-home', 'tools');
    fs.mkdirSync(tools, { recursive: true, mode: 0o700 });
    return new Promise((resolve, reject) => {
        const payload = JSON.stringify({ root, config, id, job, current });
        const child = spawn('/usr/bin/flock', ['--exclusive', '--no-fork', '--timeout', '360',
            path.join(tools, '.install.lock'), process.execPath, __filename, payload], {
            cwd: root, env, stdio: ['ignore', job === 'update' ? 'ignore' : 'inherit', 'inherit', 'pipe'],
        });
        let result = '', stopped = false;
        const abort = () => { stopped = true; child.kill('SIGTERM'); };
        signal?.addEventListener('abort', abort, { once: true });
        child.stdio[3].on('data', chunk => {
            result += chunk;
            if (result.length > 8192) abort();
        });
        child.on('error', reject);
        child.on('close', code => {
            signal?.removeEventListener('abort', abort);
            if (stopped || code !== 0) return reject(new Error('Tool preparation stopped; reopen this session to retry'));
            try { resolve(JSON.parse(result)); } catch { reject(new Error('Tool preparation returned no result')); }
        });
    });
}

async function runJob({ root, config, id, job, current }, env) {
    if (!/^[0-9a-f-]{36}$/.test(id || '')) throw new Error('Invalid development session');
    const home = path.join(root, '.spark-home');
    const tools = path.join(home, 'tools');
    const binDir = path.join(tools, 'bin');
    fs.mkdirSync(binDir, { recursive: true, mode: 0o700 });
    const controller = new AbortController();
    const signal = controller.signal;
    const children = new Set();
    const stop = () => {
        controller.abort();
        for (const child of children) child.kill('SIGTERM');
    };
    process.on('SIGTERM', stop);
    const run = (command, args, options = {}) => new Promise((resolve, reject) => {
        signal.throwIfAborted();
        const child = spawn(command, args, { cwd: root, env, stdio: 'inherit', ...options });
        children.add(child);
        child.on('error', error => { children.delete(child); reject(error); });
        child.on('close', code => {
            children.delete(child);
            code === 0 && !signal.aborted ? resolve() : reject(new Error(`${command} installation stopped`));
        });
    });
    const NPM = { pi: ['pi', '@mariozechner/pi-coding-agent'], open_code: ['opencode', 'opencode-ai'], claude_code: ['claude', '@anthropic-ai/claude-code'], codex: ['codex', '@openai/codex'] };
    const semver = value => { const m = String(value || '').match(/(\d+)\.(\d+)\.(\d+)/); return m ? m.slice(1, 4).map(Number) : null; };
    const newer = (candidate, current) => { const a = semver(candidate), b = semver(current); if (!a || !b) return false; for (let i = 0; i < 3; i++) if (a[i] !== b[i]) return a[i] > b[i]; return false; };
    const sha256 = file => crypto.createHash('sha256').update(fs.readFileSync(file)).digest('hex');
    const log = text => { try { fs.appendFileSync(path.join(tools, 'updates.log'), `${new Date().toISOString()} ${text}\n`, { mode: 0o600 }); } catch {} };
    // The worker owns the shared lock before recovering abandoned installations.
    for (const entry of fs.readdirSync(tools)) {
        if (/\.install-[0-9a-f-]{36}$/.test(entry) || /\.[0-9a-f-]{36}$/.test(entry)) fs.rmSync(path.join(tools, entry), { recursive: true, force: true });
    }
    for (const entry of fs.readdirSync(binDir)) {
        if (/\.[0-9a-f-]{36}$/.test(entry)) fs.rmSync(path.join(binDir, entry), { force: true });
    }
    async function download(url, limit, label) {
        const response = await fetch(url, { signal: AbortSignal.any([signal, AbortSignal.timeout(300000)]), headers: { 'user-agent': 'SparkPilot' } });
        if (!response.ok) throw new Error(`${label} download failed (${response.status})`);
        const total = Number(response.headers.get('content-length')) || 0;
        const chunks = []; let length = 0; let shown = -1;
        for await (const chunk of response.body) {
            signal.throwIfAborted();
            length += chunk.length;
            if (length > limit) throw new Error(`${label} download exceeds its size limit`);
            chunks.push(chunk);
            if (label && total) {
                const percent = Math.floor(length * 100 / total);
                // One short line, rewritten in place: it must fit a phone-width terminal or every update wraps to a new line.
                if (percent !== shown && percent % 5 === 0) { shown = percent; process.stdout.write(`\r\x1b[2KDownloading ${label}… ${percent}%`); }
            }
        }
        if (label && total) process.stdout.write('\r\x1b[2K');
        return Buffer.concat(chunks);
    }
    // Run a harness only to ask its version; a hung or foreign binary answers nothing.
    const versionOf = binary => new Promise(resolve => {
        let output = '';
        let child;
        try { child = spawn(binary, ['--version'], { cwd: root, env, stdio: ['ignore', 'pipe', 'ignore'] }); }
        catch { return resolve(null); }
        const timer = setTimeout(() => { child.kill('SIGKILL'); resolve(null); }, 10000);
        child.stdout.on('data', chunk => { output += chunk; });
        child.on('error', () => { clearTimeout(timer); resolve(null); });
        child.on('exit', () => { clearTimeout(timer); const v = semver(output); resolve(v ? v.join('.') : null); });
    });
    function preparedVersions(prefix, marker) {
        return fs.readdirSync(tools).flatMap(entry => {
            const m = entry.match(new RegExp(`^${prefix}-(\\d+\\.\\d+\\.\\d+)$`));
            if (!m) return [];
            const file = path.join(tools, entry);
            return fs.existsSync(marker(file)) ? [{ version: m[1], file }] : [];
        });
    }
    async function latestOMPRelease(signal) {
        const release = await (await fetch('https://api.github.com/repos/can1357/oh-my-pi/releases/latest', { headers: { accept: 'application/vnd.github+json', 'user-agent': 'SparkPilot' }, signal })).json();
        const version = String(release.tag_name || '').replace(/^v/, '');
        const asset = (release.assets || []).find(a => a.name === `omp-linux-${process.arch}`);
        const sums = (release.assets || []).find(a => /^SHA256SUMS/i.test(a.name) || /sha256|checksum/i.test(a.name));
        if (!semver(version) || !asset || !sums) return null;
        return { version, url: asset.browser_download_url, sumsURL: sums.browser_download_url };
    }
    // The release's own SHA256SUMS names the expected digest; a download that does not match is discarded.
    async function expectedDigest(release, signal) {
        const text = await (await fetch(release.sumsURL, { signal, headers: { 'user-agent': 'SparkPilot' } })).text();
        const line = text.split('\n').find(l => l.trim().endsWith(`omp-linux-${process.arch}`));
        const digest = line && line.trim().split(/\s+/)[0];
        return /^[a-f0-9]{64}$/i.test(digest || '') ? digest.toLowerCase() : null;
    }
    async function installOMPRelease(release, label) {
        const target = path.join(tools, `omp-${release.version}`);
        if (fs.existsSync(target) && fs.existsSync(target + '.prepared')) return target;
        const digest = await expectedDigest(release, AbortSignal.any([signal, AbortSignal.timeout(30000)]));
        if (!digest) throw new Error(`Oh My Pi ${release.version} publishes no checksum for this Spark`);
        const bytes = await download(release.url, 512 * 1024 * 1024, label ? `Oh My Pi ${release.version}` : null);
        if (crypto.createHash('sha256').update(bytes).digest('hex') !== digest) throw new Error('Oh My Pi download verification failed');
        const staging = target + '.' + id;
        fs.writeFileSync(staging, bytes, { mode: 0o700 });
        fs.renameSync(staging, target);
        fs.writeFileSync(target + '.prepared', release.version);
        return target;
    }
    async function installOMP() {
        const hashes = { arm64: '128c79498e5b9d3285d57b7b43d46139aad5473a698767314ffbe60c7c5de314', x64: 'f5431008f71d2f3971617205cfce9cb227c1d135665930088244c76d86b2fb42' };
        const hash = hashes[process.arch];
        if (!hash) throw new Error('Oh My Pi is not available for this Spark architecture');
        const binary = path.join(home, 'tools', 'omp-18.1.12');
        fs.mkdirSync(path.dirname(binary), { recursive: true });
        if (fs.existsSync(binary) && sha256(binary) === hash) return binary;
        // Prefer the latest checksum-verified release; fall back to the signed pin.
        try {
            const latest = await latestOMPRelease(AbortSignal.any([signal, AbortSignal.timeout(10000)]));
            if (latest && newer(latest.version, PINNED.oh_my_pi)) return await installOMPRelease(latest, true);
        } catch (error) { signal.throwIfAborted(); log(`Oh My Pi latest: ${error.message}`); }
        const bytes = await download(`https://github.com/can1357/oh-my-pi/releases/download/v18.1.12/omp-linux-${process.arch}`, 512 * 1024 * 1024, 'Oh My Pi 18.1.12');
        if (crypto.createHash('sha256').update(bytes).digest('hex') !== hash) throw new Error('Oh My Pi download verification failed');
        const staging = binary + '.' + id;
        fs.writeFileSync(staging, bytes, { mode: 0o700 });
        fs.renameSync(staging, binary);
        return binary;
    }
    // Preserve the newest prepared or self-updated Oh My Pi; never downgrade.
    async function selectOMP() {
        const installed = await installOMP();
        const installedVersion = (path.basename(installed).match(/omp-(\d+\.\d+\.\d+)$/) || [])[1] || PINNED.oh_my_pi;
        const candidates = [{ version: installedVersion, file: installed }, ...preparedVersions('omp', file => file + '.prepared')];
        const best = candidates.reduce((a, b) => newer(b.version, a.version) ? b : a);
        const launch = path.join(binDir, 'omp');
        if (fs.existsSync(launch)) {
            const current = sha256(launch) === sha256(best.file) ? best.version : await versionOf(launch);
            if (current && !newer(best.version, current)) return { binary: launch, version: current };
        }
        const staging = launch + '.' + id;
        fs.copyFileSync(best.file, staging);
        fs.chmodSync(staging, 0o700);
        fs.renameSync(staging, launch);
        return { binary: launch, version: best.version };
    }
    async function installOptional() {
        const choices = { pi: ['pi', '0.73.1'], open_code: ['opencode', '1.18.29'], claude_code: ['claude', '2.1.261'], codex: ['codex', '0.153.4'] };
        const choice = choices[config.harness];
        if (!choice) throw new Error('Unsupported harness');
        const directory = path.join(home, 'tools', config.harness + '-' + choice[1]);
        if (!fs.existsSync(path.join(directory, '.installed'))) {
            const staging = directory + '.install-' + id;
            fs.mkdirSync(staging, { recursive: true, mode: 0o700 });
            for (const file of ['package.json', 'package-lock.json']) {
                fs.copyFileSync(path.join(root, `.spark-${id}-${file}`), path.join(staging, file));
            }
            process.stdout.write(`\r\nInstalling ${choice[0]} on your Spark (first time only)…\r\n`);
            await run('npm', ['ci', '--prefix', staging, '--no-audit', '--no-fund']);
            fs.writeFileSync(path.join(staging, '.installed'), choice[1]);
            try { fs.renameSync(staging, directory); }
            catch (error) {
                if (!fs.existsSync(path.join(directory, '.installed'))) throw error;
                fs.rmSync(staging, { recursive: true, force: true });
            }
        }
        // Prefer a newer version SparkPilot prepared in the background; the pinned one is the floor.
        const candidates = [{ version: choice[1], file: directory }, ...preparedVersions(config.harness, file => path.join(file, '.installed'))];
        const best = candidates.reduce((a, b) => newer(b.version, a.version) ? b : a);
        const bin = path.join(best.file, 'node_modules', '.bin');
        env.PATH = bin + ':' + env.PATH;
        const link = path.join(binDir, choice[0]);
        try { fs.rmSync(link, { force: true }); fs.symlinkSync(path.join(bin, choice[0]), link); } catch {}
        return { binary: path.join(bin, choice[0]), version: best.version };
    }
    // Prepare updates for the next session; native Codex remains pinned.
    async function prepareUpdates(current) {
        const name = NAMES[config.harness];
        try {
            if (config.harness === 'oh_my_pi') {
                const latest = await latestOMPRelease(AbortSignal.any([signal, AbortSignal.timeout(10000)]));
                if (!latest || !newer(latest.version, current) || fs.existsSync(path.join(tools, `omp-${latest.version}.prepared`))) return;
                await installOMPRelease(latest, false);
                log(`prepared ${name} ${latest.version}`);
            } else if (NPM[config.harness] && !(config.harness === 'codex' && config.native_codex_directory)) {
                const [binary, pkg] = NPM[config.harness];
                const meta = await (await fetch(`https://registry.npmjs.org/${pkg}/latest`, { signal: AbortSignal.any([signal, AbortSignal.timeout(10000)]), headers: { accept: 'application/json' } })).json();
                const version = String(meta.version || '');
                const directory = path.join(tools, `${config.harness}-${version}`);
                if (!newer(version, current) || fs.existsSync(path.join(directory, '.installed'))) return;
                const staging = directory + '.install-' + id;
                fs.mkdirSync(staging, { recursive: true, mode: 0o700 });
                await run('npm', ['install', `${pkg}@${version}`, '--prefix', staging, '--no-audit', '--no-fund', '--loglevel=error'], { stdio: 'ignore' });
                if (!fs.existsSync(path.join(staging, 'node_modules', '.bin', binary))) throw new Error(`${pkg}@${version} did not install its ${binary} command`);
                fs.writeFileSync(path.join(staging, '.installed'), version);
                fs.renameSync(staging, directory);
                log(`prepared ${name} ${version}`);
            }
        } catch (error) {
            if (!signal.aborted) log(`${name} update check: ${error.message}`);
        }
    }

    try {
        if (job === 'update') {
            await prepareUpdates(current);
            return {};
        }
        if (job !== 'install') throw new Error('Invalid tool preparation job');
        const selected = config.harness === 'oh_my_pi' ? await selectOMP() : await installOptional();
        return { ...selected, path: env.PATH };
    } finally { process.removeListener('SIGTERM', stop); }
}

module.exports = { prepare, runJob, PINNED, NAMES };
if (require.main === module) {
    runJob(JSON.parse(process.argv[2]), { ...process.env }).then(result => {
        fs.writeSync(3, JSON.stringify(result));
    }).catch(error => {
        process.stderr.write(`SparkPilot tools: ${error.message}\n`);
        process.exitCode = 1;
    });
}
