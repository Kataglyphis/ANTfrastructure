// Exercise the composite action's current-run artifact lookup with fake API responses.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const action = fs.readFileSync(path.join(__dirname, '../../../.github/actions/windows-clean-gpu-check/action.yml'), 'utf8');
const match = action.match(/        script: \|\r?\n([\s\S]*?)    - name: Allocate clean-host scratch/);
assert(match, 'missing artifact lookup script');
const source = match[1].split(/\r?\n/).map(line => line.replace(/^          /, '')).join('\n');
const AsyncFunction = Object.getPrototypeOf(async function () {}).constructor;
const lookup = new AsyncFunction('github', 'context', 'core', 'process', source);

async function check(artifact, shouldPass, id = '42', digest = 'sha256:' + 'a'.repeat(64)) {
  const outputs = {};
  const github = {rest: {actions: {getArtifact: async args => {
    assert.deepEqual(args, {owner: 'Kataglyphis', repo: 'OmniAccelerANT', artifact_id: 42});
    return {data: artifact};
  }}}};
  const context = {repo: {owner: 'Kataglyphis', repo: 'OmniAccelerANT'}, runId: 99, sha: 'b'.repeat(40)};
  const core = {setOutput: (key, value) => { outputs[key] = value; }};
  const call = () => lookup(github, context, core, {env: {GPU_ARTIFACT_ID: id, GPU_ARTIFACT_DIGEST: digest}});
  if (shouldPass) {
    await call();
    assert.deepEqual(outputs, {size: '123'});
  } else {
    await assert.rejects(call);
    assert.deepEqual(outputs, {});
  }
}

(async () => {
  const good = {expired: false, workflow_run: {id: 99, head_sha: 'b'.repeat(40)}, digest: 'sha256:' + 'a'.repeat(64), size_in_bytes: 123};
  await check(good, true);
  await check({...good, expired: true}, false);
  await check({...good, expired: undefined}, false);
  await check({...good, workflow_run: {id: 98, head_sha: 'b'.repeat(40)}}, false);
  await check({...good, workflow_run: {id: 99, head_sha: 'c'.repeat(40)}}, false);
  await check({...good, digest: 'sha256:' + 'c'.repeat(64)}, false);
  await check({...good, size_in_bytes: 0}, false);
  await check(good, false, '../42');
  await check(good, false, '42', 'bad');
  process.stdout.write('Windows clean-host artifact API fixtures passed\n');
})().catch(error => { process.stderr.write(`${error.stack}\n`); process.exitCode = 1; });
