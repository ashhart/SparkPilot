'use strict';
// Exercise the shipping launcher with process/file boundaries substituted; no downloads or user projects.
const assert = require('node:assert/strict');
const { EventEmitter } = require('node:events');
const fs = require('node:fs');
const path = require('node:path');
const test = require('node:test');
const vm = require('node:vm');

async function launch(harness, { container = true, uid = 1000, nativeCodex = false } = {}) {
    const files = new Map();
    const children = [];
    let finish, fail;
    const done = new Promise((resolve, reject) => { finish = resolve; fail = reject; });
    const session = '11111111-2222-3333-4444-555555555555';
    const config = { harness, model_id: 'local/model', context_length: 65536, workspace_session_id: session, socket: '.gateway', native_codex_cache: nativeCodex };
    const fakeFS = {
        readFileSync: () => JSON.stringify(config), mkdirSync: () => {}, readdirSync: () => [],
        existsSync: name => name === '/.dockerenv' ? container : true,
        writeFileSync: (name, value) => files.set(name, value),
    };
    const gateway = { once: () => {}, listen: (_port, _host, ready) => ready(), address: () => ({ port: 12345 }), close: () => finish() };
    const fakeProcess = {
        env: { SPARK_TERMINAL_ID: session }, arch: 'arm64',
        getuid: () => uid,
        stdout: { write: () => {} }, stderr: { write: message => fail(new Error(message)) },
        on: () => {}, removeListener: () => {}, exit: () => {},
    };
    const dependencies = {
        'node:fs': fakeFS, 'node:path': path, 'node:http': { createServer: () => gateway },
        'node:crypto': require('node:crypto'),
        'node:child_process': { spawn: (command, args, options) => {
            children.push({ command, args: Array.from(args), options });
            const child = new EventEmitter();
            queueMicrotask(() => { child.emit('exit', 0, null); child.emit('close', 0, null); });
            return child;
        } },
    };
    const source = fs.readFileSync(path.join(__dirname, '../runtime/crates/sparkd/src/project_api/development-launch.cjs'), 'utf8');
    const context = {
        require: name => { assert.ok(name in dependencies); return dependencies[name]; },
        process: fakeProcess, Buffer, setTimeout, clearTimeout, AbortSignal, AbortController,
        fetch: async (url, options) => {
            assert.equal(url, 'http://127.0.0.1:12345/spark/codex/prepare');
            assert.equal(options.method, 'POST');
            return { ok: true, json: async () => ({ directory: '.spark-codex-test' }) };
        },
    };
    const cacheModule = { exports: {} };
    vm.runInNewContext(fs.readFileSync(path.join(__dirname,
        '../runtime/crates/sparkd/src/project_api/development-tools.cjs'), 'utf8'), {
        ...context, module: cacheModule,
    });
    dependencies['./.spark-pilot-tools.cjs'] = { ...cacheModule.exports, prepare: async (root, config, id, env, job, current) =>
        cacheModule.exports.runJob({ root, config, id, job, current }, env) };
    vm.runInNewContext(source, context);
    await done;
    return { children, files };
}

test('Codex uses the existing project container sandbox and retains its approval prompts', { timeout: 2000 }, async () => {
    const { children, files } = await launch('codex');
    assert.equal(children.length, 1, 'a cached harness must not be installed again');
    const child = children[0];
    assert.deepEqual(child.args, ['--sandbox', 'danger-full-access', '--ask-for-approval', 'on-request']);
    assert.equal(child.options.cwd, '/workspace');
    const config = files.get(path.join(child.options.env.CODEX_HOME, 'config.toml'));
    assert.match(config, /model = "local\/model"/);
    assert.match(config, /base_url = "http:\/\/127\.0\.0\.1:12345\/v1"/);
    assert.match(config, /wire_api = "responses"/);
});

test('OpenCode receives the selected local model and the live session bridge', { timeout: 2000 }, async () => {
    const { children, files } = await launch('open_code');
    assert.equal(children.length, 1);
    const child = children[0];
    const config = JSON.parse(files.get(child.options.env.OPENCODE_CONFIG));
    assert.equal(config.model, 'spark/local/model');
    assert.equal(config.provider.spark.options.baseURL, 'http://127.0.0.1:12345/v1');
    assert.equal(config.provider.spark.npm, '@ai-sdk/openai-compatible');
    assert.deepEqual(child.args, ['--model', 'spark/local/model']);
});

test('Codex refuses to rely on container isolation when run on the host or as root', { timeout: 2000 }, async () => {
    await assert.rejects(launch('codex', { container: false }), /isolated project container/);
    await assert.rejects(launch('codex', { uid: 0 }), /isolated project container/);
});

test('Claude stays on the selected Spark model without an Anthropic account', { timeout: 2000 }, async () => {
    const { children } = await launch('claude_code');
    const child = children.at(-1);
    assert.equal(child.options.env.ANTHROPIC_BASE_URL, 'http://127.0.0.1:12345');
    assert.equal(child.options.env.ANTHROPIC_AUTH_TOKEN, 'workspace');
    for (const key of ['ANTHROPIC_MODEL', 'ANTHROPIC_DEFAULT_OPUS_MODEL', 'ANTHROPIC_DEFAULT_SONNET_MODEL', 'ANTHROPIC_DEFAULT_HAIKU_MODEL']) {
        assert.equal(child.options.env[key], 'local/model');
    }
    assert.deepEqual(child.args, ['--model', 'local/model']);
    assert.equal(child.options.env.CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC, '1');
    assert.equal(child.options.env.CLAUDE_CODE_MAX_CONTEXT_TOKENS, '65536');
});


test('Codex reuses runtime-prepared binaries without a per-project npm installation', { timeout: 2000 }, async () => {
    const { children } = await launch('codex', { nativeCodex: true });
    assert.equal(children.length, 1);
    assert.equal(children[0].command, '/workspace/.spark-codex-test/bin/codex');
    assert.match(children[0].options.env.PATH, /^\/workspace\/\.spark-codex-test\/codex-path:/);
});


test('bundled app presets match the signed first-install catalogue', () => {
    assert.deepEqual(
        fs.readFileSync(path.join(__dirname, '../apple/SparkApp/Shared/Resources/model-presets.json')),
        fs.readFileSync(path.join(__dirname, '../packaging/catalogue/bootstrap.lab.json')),
    );
});

if (process.platform === 'linux') require('./development-cache.test.cjs');
