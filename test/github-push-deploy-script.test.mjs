import test from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { existsSync, mkdtempSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';

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
    'test/cloudflare-email-routing-removal-script.test.mjs',
    'test/github-push-deploy-script.test.mjs',
    'test/wrangler-domain-vars.test.mjs',
    'test/domain-picker.test.mjs',
    'test/mail-domains.test.mjs',
    'test/mailboxes-domain-selection.test.mjs',
  ]);
});

test('production push script treats git stderr progress as output, not failure', () => {
  assert.equal(existsSync(scriptPath), true);

  const tempDir = mkdtempSync(join(tmpdir(), 'whgbdbse-fake-git-'));
  const fakeGit = join(tempDir, 'fake-git.ps1');
  writeFileSync(fakeGit, [
    'param([Parameter(ValueFromRemainingArguments=$true)][string[]]$GitArgs)',
    'Write-Error "To https://example.invalid/owner/repo.git"',
    'Write-Error " * [new branch]      HEAD -> mypro"',
    'exit 0',
    '',
  ].join('\n'));

  const shell = process.platform === 'win32' ? 'powershell.exe' : 'pwsh';
  const result = spawnSync(shell, [
    '-NoProfile',
    '-ExecutionPolicy',
    'Bypass',
    '-File',
    scriptPath,
    '-SkipChecks',
    '-AllowDirty',
    '-GitCommand',
    fakeGit,
    '-Remote',
    'origin',
    '-Branch',
    'mypro',
  ], { encoding: 'utf8' });

  assert.equal(result.status, 0, result.stderr || result.stdout);
  const body = JSON.parse(result.stdout);
  assert.equal(body.push.exitCode, 0);
  assert.match(body.push.output.join('\n'), /HEAD -> mypro/);
});
