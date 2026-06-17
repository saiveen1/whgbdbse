import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';

function readTomlVar(name) {
  const toml = readFileSync('wrangler.toml', 'utf8');
  const match = toml.match(new RegExp(`^${name}\\s*=\\s*"([^"]*)"`, 'm'));
  return match?.[1] ?? null;
}

test('wrangler domain vars stay aligned with the intended production picker set', () => {
  assert.equal(readTomlVar('MAIL_DOMAIN_PREFIXES'), 'novali,edu,itachi');
  assert.equal(readTomlVar('MAIL_DOMAIN_BASES'), 'usla.us.ci,cala.lol,imatech.lol,mofeisi.xyz');
});
