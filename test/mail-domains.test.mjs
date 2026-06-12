import test from 'node:test';
import assert from 'node:assert/strict';

import { getMailDomains } from '../src/utils/mail-domains.js';

test('getMailDomains prefers MAIL_DOMAIN when provided', () => {
  const domains = getMailDomains({
    MAIL_DOMAIN: ' alpha.example.com, beta.example.com  gamma.example.com '
  });

  assert.deepEqual(domains, [
    'alpha.example.com',
    'beta.example.com',
    'gamma.example.com'
  ]);
});

test('getMailDomains expands prefixes and bases and allows root bases when MAIL_DOMAIN is absent', () => {
  const domains = getMailDomains({
    MAIL_DOMAIN_PREFIXES: 'amazon, api',
    MAIL_DOMAIN_BASES: 'aibus.us.ci, hotel.us.ci'
  });

  assert.deepEqual(domains, [
    'amazon.aibus.us.ci',
    'amazon.hotel.us.ci',
    'api.aibus.us.ci',
    'api.hotel.us.ci',
    'aibus.us.ci',
    'hotel.us.ci'
  ]);
});

test('getMailDomains falls back to temp.example.com when no config is present', () => {
  assert.deepEqual(getMailDomains({}), ['temp.example.com']);
});
