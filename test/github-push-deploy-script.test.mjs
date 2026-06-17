import test from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { existsSync } from 'node:fs';
import { resolve } from 'node:path';

const scriptPath = resolve('scripts/push-production.ps1');

function runPlan(args = []) {
  const shell = process.platform === 'win32' ? 'powershell.exe' : 'pwsh';
  return spawnSync(shell, [
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
      CLOUDFLARE_API_TOKEN: '',
      CF_EMAIL: '',
      CF_API_KEY: '',
      CF_API_TOKEN: '',
    },
  });
}

test('production push script documents GitHub-triggered deploy path without Cloudflare auth', () => {
  assert.equal(existsSync(scriptPath), true);

  const result = runPlan(['-Remote', 'origin', '-Branch', 'mypro']);

  assert.equal(result.status, 0, result.stderr || result.stdout);
  const plan = JSON.parse(result.stdout);

  assert.equal(plan.remote, 'origin');
  assert.equal(plan.branch, 'mypro');
  assert.deepEqual(plan.defaultCommand, ['git', 'push', '--dry-run', 'origin', 'HEAD:mypro']);
  assert.deepEqual(plan.applyCommand, ['git', 'push', 'origin', 'HEAD:mypro']);
  assert.equal(plan.cloudflare.usesWranglerDeploy, false);
  assert.equal(plan.cloudflare.usesWranglerLogin, false);
  assert.equal(plan.cloudflare.requiresCloudflareCredentials, false);
  assert.deepEqual(plan.focusedChecks, [
    'test/cloudflare-email-routing-script.test.mjs',
    'test/github-push-deploy-script.test.mjs',
    'test/wrangler-domain-vars.test.mjs',
    'test/domain-picker.test.mjs',
    'test/mail-domains.test.mjs',
    'test/mailboxes-domain-selection.test.mjs',
  ]);
});
