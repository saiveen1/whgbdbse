import test from 'node:test';
import assert from 'node:assert/strict';
import { spawn, spawnSync } from 'node:child_process';
import { createServer } from 'node:http';
import { existsSync } from 'node:fs';
import { resolve } from 'node:path';

const scriptPath = resolve('scripts/remove-cloudflare-email-routing-subdomain.ps1');

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
      CLOUDFLARE_ACCOUNT_ID: '',
    },
  });
}

test('Cloudflare Email Routing removal script emits a safe offline plan', () => {
  assert.equal(existsSync(scriptPath), true);

  const result = runPlan([
    '-Domain', 'aibus.us.ci',
    '-Subdomain', 'test.aibus.us.ci',
  ]);

  assert.equal(result.status, 0, result.stderr || result.stdout);
  const plan = JSON.parse(result.stdout);

  assert.equal(plan.domain, 'aibus.us.ci');
  assert.equal(plan.subdomain, 'test.aibus.us.ci');
  assert.equal(plan.zoneWideEmailRoutingChanged, false);
  assert.equal(plan.catchAllChanged, false);
  assert.equal(plan.supportSubaddressChanged, false);

  assert.deepEqual(plan.operations.map((operation) => operation.method), [
    'GET',
    'GET',
    'GET',
    'DELETE',
    'GET',
    'GET',
  ]);

  assert.equal(plan.operations[0].path, '/zones?account.id={account_id}&name=aibus.us.ci&per_page=1');
  assert.equal(plan.operations[1].path, '/zones/{zone_id}/email/routing/dns?subdomain=test.aibus.us.ci');
  assert.equal(plan.operations[2].path, '/zones/{zone_id}/dns_records?name=test.aibus.us.ci&per_page=100');
  assert.equal(plan.operations[3].path, '/zones/{zone_id}/dns_records/{record_id}');
  assert.equal(plan.operations[3].scope, 'only DNS records whose name exactly equals test.aibus.us.ci');
});

test('Cloudflare Email Routing removal script refuses apex as subdomain target', () => {
  const result = runPlan([
    '-Domain', 'aibus.us.ci',
    '-Subdomain', 'aibus.us.ci',
  ]);

  assert.notEqual(result.status, 0);
  assert.match(result.stderr, /must be a child of/);
});

test('Cloudflare Email Routing removal script reports missing diagnostics as absent records', async () => {
  const target = 'test.aibus.us.ci';
  const records = [
    { id: 'mx1', type: 'MX', name: target, content: 'route1.mx.cloudflare.net.', priority: 78, ttl: 1 },
    { id: 'mx2', type: 'MX', name: target, content: 'route2.mx.cloudflare.net.', priority: 31, ttl: 1 },
    { id: 'mx3', type: 'MX', name: target, content: 'route3.mx.cloudflare.net.', priority: 11, ttl: 1 },
    { id: 'txt1', type: 'TXT', name: target, content: '"v=spf1 include:_spf.mx.cloudflare.net ~all"', ttl: 1 },
  ];
  const deleted = new Set();

  const server = createServer((request, response) => {
    const url = new URL(request.url, 'http://127.0.0.1');
    const send = (body) => {
      response.writeHead(200, { 'content-type': 'application/json' });
      response.end(JSON.stringify(body));
    };

    if (request.method === 'GET' && url.pathname === '/client/v4/zones') {
      send({ success: true, result: [{ id: 'zone123', name: 'aibus.us.ci', status: 'active' }] });
      return;
    }

    if (request.method === 'GET' && url.pathname === '/client/v4/zones/zone123/email/routing/dns') {
      const missing = records
        .filter((record) => deleted.has(record.id))
        .map((record) => ({ code: `${record.type.toLowerCase()}.missing`, missing: record }));
      send({ success: true, result: { errors: missing, records } });
      return;
    }

    if (request.method === 'GET' && url.pathname === '/client/v4/zones/zone123/dns_records') {
      send({ success: true, result: records.filter((record) => !deleted.has(record.id)) });
      return;
    }

    if (request.method === 'DELETE' && url.pathname.startsWith('/client/v4/zones/zone123/dns_records/')) {
      deleted.add(url.pathname.split('/').at(-1));
      send({ success: true, result: { id: url.pathname.split('/').at(-1) } });
      return;
    }

    response.writeHead(404, { 'content-type': 'application/json' });
    response.end(JSON.stringify({ success: false, errors: [{ message: `unexpected ${request.method} ${url.pathname}` }] }));
  });

  await new Promise((resolveListen) => server.listen(0, '127.0.0.1', resolveListen));
  const { port } = server.address();

  try {
    const shell = process.platform === 'win32' ? 'powershell.exe' : 'pwsh';
    const result = await new Promise((resolveRun) => {
      const child = spawn(shell, [
        '-NoProfile',
        '-ExecutionPolicy',
        'Bypass',
        '-File',
        scriptPath,
        '-Apply',
        '-Domain', 'aibus.us.ci',
        '-Subdomain', target,
        '-ApiBaseUrl', `http://127.0.0.1:${port}/client/v4`,
      ], {
        encoding: 'utf8',
        env: {
          ...process.env,
          CLOUDFLARE_EMAIL: 'operator@example.test',
          CLOUDFLARE_API_KEY: 'fake-global-key',
          CLOUDFLARE_ACCOUNT_ID: 'account123',
        },
      });
      let stdout = '';
      let stderr = '';
      child.stdout.on('data', (chunk) => { stdout += chunk; });
      child.stderr.on('data', (chunk) => { stderr += chunk; });
      child.on('close', (status) => resolveRun({ status, stdout, stderr }));
    });

    assert.equal(result.status, 0, result.stderr || result.stdout);
    const body = JSON.parse(result.stdout);
    assert.equal(body.before.emailRoutingDnsPresentRecordCount, 4);
    assert.equal(body.before.emailRoutingDnsMissingRecordCount, 0);
    assert.equal(body.deleted.dnsRecordCount, 4);
    assert.equal(body.after.emailRoutingDnsRequiredRecordCount, 4);
    assert.equal(body.after.emailRoutingDnsMissingRecordCount, 4);
    assert.equal(body.after.emailRoutingDnsPresentRecordCount, 0);
    assert.equal(body.after.dnsRecordCount, 0);
  } finally {
    await new Promise((resolveClose) => server.close(resolveClose));
  }
});
