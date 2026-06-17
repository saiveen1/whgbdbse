import test from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { existsSync } from 'node:fs';
import { resolve } from 'node:path';

const scriptPath = resolve('scripts/configure-cloudflare-email-routing.ps1');

function runPlan(args = []) {
  const shell = process.platform === 'win32' ? 'powershell.exe' : 'pwsh';
  const result = spawnSync(shell, [
    '-NoProfile',
    '-ExecutionPolicy',
    'Bypass',
    '-File',
    scriptPath,
    '-PlanOnly',
    ...args,
  ], {
    encoding: 'utf8',
    env: {
      ...process.env,
      CLOUDFLARE_EMAIL: '',
      CLOUDFLARE_API_KEY: '',
      CLOUDFLARE_ACCOUNT_ID: '',
    },
  });

  return result;
}

test('Cloudflare Email Routing script emits an offline plan without credentials', () => {
  assert.equal(existsSync(scriptPath), true);

  const result = runPlan([
    '-Domain', 'aibus.us.ci',
    '-WorkerName', 'whgbdbse',
    '-Subdomain', 'test.aibus.us.ci',
    '-WorkerUrl', 'https://whgbdbse.1908912779.workers.dev',
  ]);

  assert.equal(result.status, 0, result.stderr || result.stdout);
  const plan = JSON.parse(result.stdout);

  assert.equal(plan.domain, 'aibus.us.ci');
  assert.equal(plan.workerName, 'whgbdbse');
  assert.equal(plan.subdomain, 'test.aibus.us.ci');
  assert.equal(plan.workerUrl, 'https://whgbdbse.1908912779.workers.dev');
  assert.equal(plan.syncWaitSeconds, 60);

  assert.deepEqual(plan.operations.map((operation) => operation.method), [
    'GET',
    'POST',
    'POST',
    'POST',
    'PUT',
    'PATCH',
    'GET',
    'GET',
    'GET',
    'GET',
  ]);

  assert.equal(plan.operations[1].path, '/zones/{zone_id}/email/routing/dns');
  assert.deepEqual(plan.operations[2].body, { name: 'test.aibus.us.ci' });
  assert.deepEqual(plan.operations[4].body.actions, [
    { type: 'worker', value: ['whgbdbse'] },
  ]);
  assert.deepEqual(plan.operations[4].body.matchers, [{ type: 'all' }]);
  assert.deepEqual(plan.operations[5].body, { support_subaddress: true });
});
