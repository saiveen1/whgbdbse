import test from 'node:test';
import assert from 'node:assert/strict';

import { handleMailboxesApi } from '../src/api/mailboxes.js';

function createDbStub() {
  const mailboxes = new Map();
  let nextId = 1;

  return {
    prepare(sql) {
      let values = [];
      return {
        bind(...args) {
          values = args;
          return this;
        },
        async all() {
          if (sql.includes('SELECT id FROM mailboxes WHERE address = ?')) {
            const address = String(values[0] || '').toLowerCase();
            const id = mailboxes.get(address);
            return { results: id ? [{ id }] : [] };
          }
          return { results: [] };
        },
        async run() {
          if (sql.includes('INSERT INTO mailboxes')) {
            const address = String(values[0] || '').toLowerCase();
            if (!mailboxes.has(address)) {
              mailboxes.set(address, nextId++);
            }
          }
          return { success: true };
        },
      };
    },
  };
}

async function callCreate(body, domains = ['novali.imatech.lol', 'imatech.lol']) {
  const request = new Request('https://freemail.example/api/create', {
    method: 'POST',
    body: JSON.stringify(body),
    headers: { 'Content-Type': 'application/json' },
  });
  return await handleMailboxesApi(
    request,
    createDbStub(),
    domains,
    new URL(request.url),
    '/api/create',
    {}
  );
}

async function callGenerate(query, domains = ['novali.imatech.lol', 'imatech.lol']) {
  const request = new Request(`https://freemail.example/api/generate?${query}`);
  return await handleMailboxesApi(
    request,
    createDbStub(),
    domains,
    new URL(request.url),
    '/api/generate',
    {}
  );
}

test('GET /api/generate honors explicit root domain when it is allowed', async () => {
  const response = await callGenerate('length=6&domain=imatech.lol&domainIndex=0');
  const body = await response.json();

  assert.equal(response.status, 200);
  assert.match(body.email, /^[a-z0-9]{6}@imatech\.lol$/);
});

test('GET /api/generate honors explicit custom suffix even when it is not in configured domains', async () => {
  const response = await callGenerate('length=6&domain=test.aibus.us.ci&domainIndex=0');
  const body = await response.json();

  assert.equal(response.status, 200);
  assert.match(body.email, /^[a-z0-9]{6}@test\.aibus\.us\.ci$/);
});

test('POST /api/create honors explicit root domain when it is allowed', async () => {
  const response = await callCreate({ local: 'manual', domain: 'imatech.lol', domainIndex: 0 });
  const body = await response.json();

  assert.equal(response.status, 200);
  assert.equal(body.email, 'manual@imatech.lol');
});

test('POST /api/create honors explicit custom suffix even when it is not in configured domains', async () => {
  const response = await callCreate({ local: 'manual', domain: 'test.aibus.us.ci', domainIndex: 0 });
  const body = await response.json();

  assert.equal(response.status, 200);
  assert.equal(body.email, 'manual@test.aibus.us.ci');
});

test('POST /api/create rejects malformed explicit suffix', async () => {
  const response = await callCreate({ local: 'manual', domain: 'bad_domain', domainIndex: 0 });
  const text = await response.text();

  assert.equal(response.status, 400);
  assert.match(text, /域名/);
});
