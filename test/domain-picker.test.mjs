import test from 'node:test';
import assert from 'node:assert/strict';

import {
  buildDomainPickerModel,
  resolveDomainChoice,
} from '../public/js/modules/app/domains.js';

test('buildDomainPickerModel groups expanded domains by base domain and prefix', () => {
  const model = buildDomainPickerModel([
    'novali.usla.us.ci',
    'novali.cala.lol',
    'edu.usla.us.ci',
    'itachi.mofeisi.xyz',
    'usla.us.ci',
    'cala.lol',
    'mofeisi.xyz',
  ]);

  assert.deepEqual(model.bases, ['usla.us.ci', 'cala.lol', 'mofeisi.xyz']);
  assert.deepEqual(model.prefixesByBase['usla.us.ci'], ['', 'novali', 'edu']);
  assert.deepEqual(model.prefixesByBase['cala.lol'], ['', 'novali']);
  assert.deepEqual(model.prefixesByBase['mofeisi.xyz'], ['', 'itachi']);
});

test('resolveDomainChoice builds configured child suffixes and prefers custom full suffix', () => {
  assert.equal(resolveDomainChoice({
    base: 'usla.us.ci',
    prefix: 'novali',
    custom: '',
  }), 'novali.usla.us.ci');

  assert.equal(resolveDomainChoice({
    base: 'usla.us.ci',
    prefix: '',
    custom: ' test.aibus.us.ci ',
  }), 'test.aibus.us.ci');
});
