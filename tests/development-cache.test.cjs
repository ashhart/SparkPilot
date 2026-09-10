'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const test = require('node:test');
const { spawn } = require('node:child_process');
const { prepare } = require('../runtime/crates/sparkd/src/project_api/development-tools.cjs');
const a = '11111111-1111-4111-8111-111111111111';
const b = '22222222-2222-4222-8222-222222222222';
const config = { harness: 'open_code' };
const delay = ms => new Promise(resolve => setTimeout(resolve, ms));
async function until(check) {
    for (let i = 0; i < 300; i++) { if (check()) return; await delay(10); }
    throw new Error('Timed out waiting for fixture');
}
function fixture(t) {
    const root = fs.mkdtempSync(path.join(os.tmpdir(), 'spark-cache-'));
    const running = [];
    t.after(async () => {
        for (const job of running) job.controller.abort();
        await Promise.allSettled(running.map(job => job.promise));
        fs.rmSync(root, { recursive: true, force: true });
    });
    const bin = path.join(root, 'bin');
    fs.mkdirSync(bin);
    fs.writeFileSync(path.join(bin, 'npm'), `#!${process.execPath}
const fs = require('node:fs'), path = require('node:path');
const stage = process.argv[process.argv.indexOf('--prefix') + 1];
fs.appendFileSync(process.env.CACHE_TEST_ROOT + '/calls', 'install\\n');
fs.writeFileSync(stage + '/active', String(process.pid));
const timer = setInterval(() => {
    if (!fs.existsSync(process.env.CACHE_TEST_ROOT + '/release')) return;
    clearInterval(timer);
    if (fs.existsSync(process.env.CACHE_TEST_ROOT + '/fail')) process.exit(42);
    fs.mkdirSync(stage + '/node_modules/.bin', { recursive: true });
    fs.writeFileSync(stage + '/node_modules/.bin/opencode', 'ready');
}, 10);
`, { mode: 0o700 });
    for (const id of [a, b]) for (const name of ['package.json', 'package-lock.json']) {
        fs.writeFileSync(path.join(root, `.spark-${id}-${name}`), '{}');
    }
    const env = { ...process.env, PATH: bin + ':' + process.env.PATH, CACHE_TEST_ROOT: root };
    const tools = path.join(root, '.spark-home/tools');
    const stage = id => path.join(tools, `open_code-1.18.29.install-${id}`);
    const job = (id, kind, current, overrides = {}, signal) => {
        const controller = new AbortController();
        const combined = signal ? AbortSignal.any([signal, controller.signal]) : controller.signal;
        const promise = prepare(root, config, id, { ...env, ...overrides }, kind, current, combined);
        promise.catch(() => {});
        running.push({ controller, promise });
        return promise;
    };
    const install = (id, signal) => job(id, 'install', undefined, {}, signal);
    const release = () => fs.writeFileSync(path.join(root, 'release'), '');
    return { root, env, tools, stage, install, release, job };
}

test('two sessions share one installation without deleting active staging', { timeout: 10000 }, async t => {
    const f = fixture(t);
    const first = f.install(a);
    await until(() => fs.existsSync(f.stage(a) + '/active'));
    let secondFinished = false;
    const second = f.install(b).then(value => { secondFinished = true; return value; });
    await delay(150);
    assert.ok(fs.existsSync(f.stage(a) + '/active'));
    assert.equal(secondFinished, false);
    f.release();
    const [one, two] = await Promise.all([first, second]);
    assert.equal(one.binary, two.binary);
    assert.equal(fs.readFileSync(path.join(f.root, 'calls'), 'utf8'), 'install\n');
    assert.ok(fs.existsSync(one.binary));
    assert.ok(!fs.existsSync(f.stage(a)));
});

test('a crashed lock owner releases the cache and abandoned staging is recovered', { timeout: 10000 }, async t => {
    const f = fixture(t);
    fs.mkdirSync(f.tools, { recursive: true });
    const worker = spawn('flock', ['--no-fork', f.tools + '/.install.lock', process.execPath, '-e',
        `require('node:fs').mkdirSync(${JSON.stringify(f.stage(a))}); setInterval(() => {}, 1000)`]);
    const ended = new Promise(resolve => worker.on('close', resolve));
    t.after(() => worker.kill('SIGKILL'));
    await until(() => fs.existsSync(f.stage(a)));
    worker.kill('SIGKILL');
    await ended;
    f.release();
    const result = await f.install(b);
    assert.ok(fs.existsSync(result.binary));
    assert.equal(fs.existsSync(f.stage(a)), false);
});

test('cancelling a waiter does not release another session lock or delete its files', { timeout: 10000 }, async t => {
    const f = fixture(t);
    const first = f.install(a);
    await until(() => fs.existsSync(f.stage(a) + '/active'));
    const controller = new AbortController();
    const second = f.install(b, controller.signal);
    const rejected = assert.rejects(second, /preparation stopped/);
    await delay(100);
    controller.abort();
    await rejected;
    assert.ok(fs.existsSync(f.stage(a) + '/active'));
    f.release();
    await first;
});

test('failed installation is not published and the next session retries cleanly', { timeout: 10000 }, async t => {
    const f = fixture(t);
    fs.writeFileSync(path.join(f.root, 'fail'), '');
    f.release();
    await assert.rejects(f.install(a), /preparation stopped/);
    assert.equal(fs.existsSync(path.join(f.tools, 'open_code-1.18.29/.installed')), false);
    fs.rmSync(path.join(f.root, 'fail'));
    const result = await f.install(b);
    assert.ok(fs.existsSync(result.binary));
    assert.equal(fs.existsSync(f.stage(a)), false);
    assert.equal(fs.readFileSync(path.join(f.root, 'calls'), 'utf8'), 'install\ninstall\n');
});

test('ending an active install keeps its lock until the installer exits, then permits recovery', { timeout: 10000 }, async t => {
    const f = fixture(t);
    const controller = new AbortController();
    const first = f.install(a, controller.signal);
    const rejected = assert.rejects(first, /preparation stopped/);
    await until(() => fs.existsSync(f.stage(a) + '/active'));
    controller.abort();
    await rejected;
    f.release();
    const next = await f.install(b);
    assert.ok(fs.existsSync(next.binary));
    assert.equal(fs.existsSync(f.stage(a)), false);
});

test('background updates and foreground launches use the same cache lock', { timeout: 10000 }, async t => {
    const f = fixture(t);
    const preload = path.join(f.root, 'registry.cjs');
    fs.writeFileSync(preload, "global.fetch = async () => ({ json: async () => ({ version: '1.19.0' }) });");
    const env = { ...f.env, NODE_OPTIONS: `--require=${preload}` };
    const update = f.job(a, 'update', '1.18.29', env);
    const stage = path.join(f.tools, `open_code-1.19.0.install-${a}`);
    await until(() => fs.existsSync(stage + '/active'));
    const launch = f.install(b);
    await delay(100);
    assert.ok(fs.existsSync(stage + '/active'));
    f.release();
    await update;
    const selected = await launch;
    assert.equal(selected.version, '1.19.0');
    assert.ok(fs.existsSync(selected.binary));
});
