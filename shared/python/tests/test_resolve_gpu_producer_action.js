// Exercise the actual composite-action API lookup with simulated GitHub responses.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const action = fs.readFileSync(path.join(__dirname, '../../../.github/actions/resolve-gpu-producer/action.yml'), 'utf8');
const match = action.match(/        script: \|\r?\n([\s\S]*?)    - name: Validate the producer receipt/);
assert(match, 'missing artifact lookup script');
const source = match[1].split(/\r?\n/).map(line => line.replace(/^          /, '')).join('\n');
const AsyncFunction = Object.getPrototypeOf(async function () {}).constructor;
const lookup = new AsyncFunction('github', 'context', 'core', 'process', source);

async function check(artifacts, shouldPass, runnerOS = 'Linux', platform = 'linux') {
  const outputs = {};
  const github = {
    rest: {actions: {listWorkflowRunArtifacts: 'list'}},
    paginate: async (method, args) => {
      assert.equal(method, 'list');
      assert.deepEqual(args, {owner: 'Kataglyphis', repo: 'OrchestrANT', run_id: 99, per_page: 100});
      return artifacts;
    }
  };
  const core = {setOutput: (key, value) => { outputs[key] = value; }};
  const call = () => lookup(github, {repo: {owner: 'Kataglyphis', repo: 'OrchestrANT'}, runId: 99}, core, {env: {GPU_ARTIFACT_NAME: 'expected', RUNNER_OS: runnerOS, GPU_PLATFORM: platform}});
  if (shouldPass) {
    await call();
    assert.deepEqual(outputs, {id: '42', digest: 'sha256:' + 'a'.repeat(64)});
  } else {
    await assert.rejects(call);
    assert.deepEqual(outputs, {});
  }
}

(async () => {
  const artifact = {name: 'expected', id: 42, digest: 'sha256:' + 'a'.repeat(64), expired: false};
  await check([artifact], true);
  await check([], false);
  await check([artifact, artifact], false);
  await check([{...artifact, expired: true}], false);
  await check([{...artifact, expired: undefined}], false);
  await check([{...artifact, digest: null}], false);
  await check([{...artifact, name: 'other'}], false);
  await check([artifact], false, 'Windows', 'linux');
  await check([artifact], true, 'Linux', 'windows');
  await check([artifact], false, 'Windows', 'windows');
  await check([artifact], false, 'Linux', 'macos');
  process.stdout.write('GPU artifact API lookup fixtures passed\n');
})().catch(error => { process.stderr.write(`${error.stack}\n`); process.exitCode = 1; });
