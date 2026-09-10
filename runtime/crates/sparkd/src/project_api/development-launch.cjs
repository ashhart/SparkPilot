'use strict';
// Runs unprivileged inside the managed container, never on the Spark host.
const fs = require('node:fs');
const path = require('node:path');
const http = require('node:http');
const { spawn } = require('node:child_process');
const root = '/workspace';
const id = process.env.SPARK_TERMINAL_ID;
if (!/^[0-9a-f-]{36}$/.test(id || '')) throw new Error('Invalid development session');
const config = JSON.parse(fs.readFileSync(path.join(root, `.spark-session-${id}.json`), 'utf8'));
if (!/^[0-9a-f-]{36}$/.test(config.workspace_session_id || "")) throw new Error("Invalid workspace identity");
const home = path.join(root, '.spark-home');
fs.mkdirSync(home, { recursive: true, mode: 0o700 });
const sessionHome = path.join(home, 'sessions', config.workspace_session_id);
fs.mkdirSync(sessionHome, { recursive: true, mode: 0o700 });
const env = { ...process.env, HOME: home, TERM: 'xterm-256color', COLORTERM: 'truecolor', SPARK_API_KEY: 'workspace', XDG_CONFIG_HOME: path.join(sessionHome, 'config'), XDG_DATA_HOME: path.join(sessionHome, 'data'), XDG_STATE_HOME: path.join(sessionHome, 'state'), npm_config_cache: path.join(home, 'npm-cache') };
const writeJSON = (file, value) => {
    fs.mkdirSync(path.dirname(file), { recursive: true, mode: 0o700 });
    fs.writeFileSync(file, JSON.stringify(value, null, 2), { mode: 0o600 });
};
const children = new Set();
const run = (command, args, options = {}) => new Promise((resolve, reject) => {
    const child = spawn(command, args, { cwd: root, env, stdio: 'inherit', ...options });
    children.add(child);
    child.on('error', error => { children.delete(child); reject(error); });
    child.on('exit', (code, signal) => { children.delete(child); code === 0 ? resolve() : reject(new Error(`${path.basename(command)} stopped${signal ? ` (${signal})` : ` with status ${code}`}`)); });
});
// Every harness is launched through one stable directory on PATH, so a harness can find and replace itself.
const tools = path.join(home, 'tools');
const binDir = path.join(tools, 'bin');
fs.mkdirSync(binDir, { recursive: true, mode: 0o700 });
env.PATH = binDir + ':' + (process.env.PATH || '/usr/local/bin:/usr/bin:/bin');
const { prepare, PINNED, NAMES } = require('./.spark-pilot-tools.cjs');
async function installTool() {
    const selected = await prepare(root, config, id, env, 'install');
    env.PATH = selected.path;
    return selected;
}
async function main() {
    if (config.harness === 'codex' && (!fs.existsSync('/.dockerenv') || typeof process.getuid !== 'function' || process.getuid() === 0)) {
        throw new Error('Codex requires the isolated project container running as its unprivileged user');
    }
    // Node bridges only the container's loopback to this session's Unix socket.
    const gateway = http.createServer((req, res) => {
        const upstream = http.request({ socketPath: path.join(root, config.socket), path: req.url, method: req.method, headers: req.headers }, incoming => {
            res.writeHead(incoming.statusCode, incoming.headers);
            incoming.pipe(res);
        });
        upstream.on('error', () => { if (!res.headersSent) res.writeHead(502); res.end('Spark model connection unavailable'); });
        req.on('aborted', () => upstream.destroy());
        res.on('close', () => upstream.destroy());
        req.pipe(upstream);
    });
    await new Promise((resolve, reject) => { gateway.once('error', reject); gateway.listen(0, '127.0.0.1', resolve); });
    const baseURL = `http://127.0.0.1:${gateway.address().port}/v1`;
    const model = { id: config.model_id, name: config.model_id, contextWindow: config.context_length, maxTokens: Math.min(8192, Math.floor(config.context_length / 4)), input: ['text'] };
    const provider = { baseUrl: baseURL, api: 'openai-completions', apiKey: 'SPARK_API_KEY', authHeader: true, models: [model] };
    let binary, args, version = PINNED[config.harness];
    if (config.harness === 'oh_my_pi') {
        ({ binary, version } = await installTool());
        env.PI_CODING_AGENT_DIR = path.join(sessionHome, 'omp');
        writeJSON(path.join(env.PI_CODING_AGENT_DIR, 'models.yml'), { providers: { spark: provider } });
        // Keep phone-width conversations visible; wider terminals retain the default detail.
        const narrow = (process.stdout.columns || 120) < 90;
        writeJSON(path.join(env.PI_CODING_AGENT_DIR, 'config.yml'), {
            startup: { showSplash: false },
            statusLine: { preset: narrow ? 'compact' : 'default' },
            hideThinkingBlock: narrow,
        });
        args = ['--continue', '--provider', 'spark', '--model', config.model_id];
    } else {
        if (config.harness === 'codex' && config.native_codex_cache) {
            process.stdout.write('\r\nPreparing Codex on your Spark…\r\n');
            const prepared = await fetch(baseURL.replace(/\/v1$/, '') + '/spark/codex/prepare', {
                method: 'POST', signal: AbortSignal.timeout(360000),
            });
            if (!prepared.ok) throw new Error('Codex preparation failed; reopen this session to retry');
            config.native_codex_directory = (await prepared.json()).directory;
        }
        if (config.harness === 'codex' && config.native_codex_directory) {
            if (!/^\.spark-codex-[a-z0-9]+$/.test(config.native_codex_directory)) throw new Error('Invalid Codex cache directory');
            const codexTools = path.join(root, config.native_codex_directory);
            binary = path.join(codexTools, 'bin', 'codex');
            env.PATH = path.join(codexTools, 'codex-path') + ':' + path.join(codexTools, 'bin') + ':' + env.PATH;
            env.CODEX_MANAGED_BY_NPM = '1';
        } else {
            ({ binary, version } = await installTool());
        }
        switch (config.harness) {
        case 'pi':
            env.PI_CODING_AGENT_DIR = path.join(sessionHome, 'pi');
            writeJSON(path.join(env.PI_CODING_AGENT_DIR, 'models.json'), { providers: { spark: provider } });
            args = ['--continue', '--provider', 'spark', '--model', config.model_id];
            break;
        case 'open_code':
            env.OPENCODE_CONFIG = path.join(sessionHome, 'opencode.json');
            writeJSON(env.OPENCODE_CONFIG, { $schema: 'https://opencode.ai/config.json', model: `spark/${config.model_id}`, provider: { spark: { npm: '@ai-sdk/openai-compatible', name: 'Spark', options: { baseURL, apiKey: 'workspace' }, models: { [config.model_id]: { name: config.model_id, limit: { context: config.context_length, output: model.maxTokens } } } } } });
            args = ['--model', `spark/${config.model_id}`];
            break;
        case 'codex':
            env.CODEX_HOME = path.join(sessionHome, 'codex');
            fs.mkdirSync(env.CODEX_HOME, { recursive: true, mode: 0o700 });
            fs.writeFileSync(path.join(env.CODEX_HOME, 'config.toml'), `model = ${JSON.stringify(config.model_id)}\nmodel_provider = "spark"\n[model_providers.spark]\nname = "Spark"\nbase_url = ${JSON.stringify(baseURL)}\nwire_api = "responses"\nenv_key = "SPARK_API_KEY"\n`, { mode: 0o600 });
            // Use Spark's unprivileged container isolation; nested user namespaces are denied, and Codex approval prompts stay enabled.
            args = ['--sandbox', 'danger-full-access', '--ask-for-approval', 'on-request'];
            break;
        case 'claude_code':
            env.CLAUDE_CONFIG_DIR = path.join(sessionHome, 'claude');
            env.ANTHROPIC_BASE_URL = baseURL.replace(/\/v1$/, '');
            env.ANTHROPIC_AUTH_TOKEN = 'workspace';
            env.ANTHROPIC_API_KEY = 'workspace';
            for (const key of ['ANTHROPIC_MODEL', 'ANTHROPIC_DEFAULT_OPUS_MODEL', 'ANTHROPIC_DEFAULT_SONNET_MODEL', 'ANTHROPIC_DEFAULT_HAIKU_MODEL']) {
                env[key] = config.model_id;
            }
            env.CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC = '1';
            env.CLAUDE_CODE_MAX_CONTEXT_TOKENS = String(config.context_length);
            args = ['--model', config.model_id];
            break;
        }
    }
    // The PTY signals the foreground process group; let the harness handle Control-C.
    process.on('SIGINT', () => {});
    process.stdout.write('\x1b[2J\x1b[H');
    process.stdout.write(`${NAMES[config.harness]} ${version}\r\n`);
    const updateController = new AbortController();
    const updates = config.harness === 'codex' && config.native_codex_directory ? Promise.resolve()
        : prepare(root, config, id, env, 'update', version, updateController.signal).catch(() => {});
    try { await run(binary, args); } finally {
        gateway.close();
        // Cancel background work and let its installer exit before releasing the cache lock.
        updateController?.abort();
        for (const child of children) child.kill('SIGTERM');
        await updates;
    }
}
main().catch(error => {
    process.stderr.write(`\r\nSpark Pilot: ${error.message}\r\nYour files are saved on the Spark; close this session and reopen to retry.\r\n`);
    process.exitCode = 1;
    // Installation failures must not leave the local model bridge keeping Node alive.
    setTimeout(() => process.exit(1), 100).unref();
    process.exit(1);
});
