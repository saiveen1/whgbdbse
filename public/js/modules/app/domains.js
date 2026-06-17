/**
 * 域名管理模块
 * @module modules/app/domains
 */

import { cacheGet, cacheSet, readPrefetch } from '../../storage.js';
import { isGuest } from './session.js';

// 域名列表
let domains = [];

// 存储键
export const STORAGE_KEYS = {
  domain: 'mailfree:lastDomain',
  length: 'mailfree:lastLen'
};

/**
 * 获取域名列表
 * @returns {Array}
 */
export function getDomains() {
  return domains;
}

/**
 * 设置域名列表
 * @param {Array} list - 域名列表
 */
export function setDomains(list) {
  domains = Array.isArray(list) ? list : [];
}

export function normalizeDomainChoice(value) {
  return String(value || '')
    .trim()
    .replace(/^@+/, '')
    .replace(/\.+$/, '')
    .toLowerCase();
}

export function isValidDomainChoice(value) {
  const domain = normalizeDomainChoice(value);
  if (!domain || domain.length > 253 || !domain.includes('.')) return false;
  return domain
    .split('.')
    .every(label => /^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$/.test(label));
}

function unique(items) {
  return [...new Set(items.filter(item => item !== null && typeof item !== 'undefined'))];
}

export function buildDomainPickerModel(domainList) {
  const list = unique((Array.isArray(domainList) ? domainList : [])
    .map(normalizeDomainChoice)
    .filter(isValidDomainChoice));

  const bases = list.filter(domain => !list.some(other => other !== domain && domain.endsWith(`.${other}`)));
  const finalBases = bases.length ? bases : list;
  const prefixesByBase = {};

  finalBases.forEach(base => {
    const prefixes = [''];
    list.forEach(domain => {
      if (domain === base) return;
      if (!domain.endsWith(`.${base}`)) return;
      prefixes.push(domain.slice(0, -(base.length + 1)));
    });
    prefixesByBase[base] = unique(prefixes);
  });

  return { domains: list, bases: finalBases, prefixesByBase };
}

export function resolveDomainChoice({ base = '', prefix = '', custom = '' } = {}) {
  const customDomain = normalizeDomainChoice(custom);
  if (customDomain) {
    return isValidDomainChoice(customDomain) ? customDomain : '';
  }

  const normalizedBase = normalizeDomainChoice(base);
  const normalizedPrefix = String(prefix || '').trim().replace(/^\.|\.$/g, '').toLowerCase();
  if (!normalizedBase) return '';
  return normalizedPrefix ? `${normalizedPrefix}.${normalizedBase}` : normalizedBase;
}

function setOptions(selectElement, values, labelForValue = value => value) {
  if (!selectElement) return;
  selectElement.innerHTML = values
    .map(value => `<option value="${value}">${labelForValue(value)}</option>`)
    .join('');
}

function findPartsForDomain(domain, model) {
  const normalized = normalizeDomainChoice(domain);
  for (const base of model.bases) {
    if (normalized === base) return { base, prefix: '' };
    if (normalized.endsWith(`.${base}`)) {
      return { base, prefix: normalized.slice(0, -(base.length + 1)) };
    }
  }
  return null;
}

function getPickerElements() {
  return {
    baseSelect: document.getElementById('domain-base-select'),
    prefixSelect: document.getElementById('domain-prefix-select'),
    customInput: document.getElementById('domain-custom-input'),
  };
}

function saveSelectedDomain(selectElement) {
  const domain = getSelectedDomain(selectElement);
  if (domain) localStorage.setItem(STORAGE_KEYS.domain, domain);
}

function updatePrefixOptions(prefixSelect, model, base, selectedPrefix = '') {
  const prefixes = model.prefixesByBase[base] || [''];
  setOptions(prefixSelect, prefixes, prefix => prefix ? prefix : '根域');
  prefixSelect.value = prefixes.includes(selectedPrefix) ? selectedPrefix : '';
}

/**
 * 填充域名下拉框
 * @param {Array} domainList - 域名列表
 * @param {HTMLSelectElement} selectElement - 下拉框元素
 */
export function populateDomains(domainList, selectElement) {
  if (!selectElement) return;
  const list = Array.isArray(domainList) ? domainList : [];
  selectElement.innerHTML = list.map((d, i) => `<option value="${i}">${d}</option>`).join('');

  const model = buildDomainPickerModel(list);
  const { baseSelect, prefixSelect, customInput } = getPickerElements();
  const stored = localStorage.getItem(STORAGE_KEYS.domain) || '';
  const idx = stored ? model.domains.indexOf(normalizeDomainChoice(stored)) : -1;
  selectElement.selectedIndex = idx >= 0 ? idx : 0;

  if (baseSelect && prefixSelect && model.bases.length) {
    const storedParts = findPartsForDomain(stored, model);
    const selectedBase = storedParts?.base || model.bases[0];
    const selectedPrefix = storedParts?.prefix || '';

    setOptions(baseSelect, model.bases);
    baseSelect.value = selectedBase;
    updatePrefixOptions(prefixSelect, model, selectedBase, selectedPrefix);
    if (customInput && stored && !storedParts) customInput.value = normalizeDomainChoice(stored);

    baseSelect.onchange = () => {
      updatePrefixOptions(prefixSelect, model, baseSelect.value, '');
      if (customInput) customInput.value = '';
      saveSelectedDomain(selectElement);
    };
    prefixSelect.onchange = () => {
      if (customInput) customInput.value = '';
      saveSelectedDomain(selectElement);
    };
    if (customInput) {
      customInput.oninput = () => saveSelectedDomain(selectElement);
    }
  }

  selectElement.onchange = () => saveSelectedDomain(selectElement);
  setDomains(list);
}

/**
 * 从 API 加载域名列表
 * @param {HTMLSelectElement} selectElement - 下拉框元素
 * @param {Function} api - API 函数
 */
export async function loadDomains(selectElement, api) {
  if (isGuest()) {
    populateDomains(['example.com'], selectElement);
    return;
  }
  
  let domainSet = false;
  
  // 尝试从缓存加载
  try {
    const cached = cacheGet('domains', 24 * 60 * 60 * 1000);
    if (Array.isArray(cached) && cached.length) {
      populateDomains(cached, selectElement);
      domainSet = true;
    }
  } catch(_) {}
  
  // 尝试从预取加载
  try {
    const prefetched = readPrefetch('mf:prefetch:domains');
    if (Array.isArray(prefetched) && prefetched.length) {
      populateDomains(prefetched, selectElement);
      domainSet = true;
    }
  } catch(_) {}
  
  // 从 API 加载
  try {
    const r = await api('/api/domains');
    const domainList = await r.json();
    if (Array.isArray(domainList) && domainList.length) {
      populateDomains(domainList, selectElement);
      cacheSet('domains', domainList);
      domainSet = true;
    }
  } catch(_) {}
  
  // 降级处理
  if (!domainSet) {
    const meta = (document.querySelector('meta[name="mail-domains"]')?.getAttribute('content') || '')
      .split(',').map(s => s.trim()).filter(Boolean);
    const fallback = [];
    if (window.currentMailbox && window.currentMailbox.includes('@')) {
      fallback.push(window.currentMailbox.split('@')[1]);
    }
    if (!meta.length && location.hostname) {
      fallback.push(location.hostname);
    }
    const list = [...new Set(meta.length ? meta : fallback)].filter(Boolean);
    populateDomains(list, selectElement);
  }
}

/**
 * 获取存储的长度
 * @returns {number}
 */
export function getStoredLength() {
  const stored = Number(localStorage.getItem(STORAGE_KEYS.length) || '8');
  return Math.max(8, Math.min(30, isNaN(stored) ? 8 : stored));
}

/**
 * 保存长度
 * @param {number} length - 长度
 */
export function saveLength(length) {
  const clamped = Math.max(8, Math.min(30, isNaN(length) ? 8 : length));
  localStorage.setItem(STORAGE_KEYS.length, String(clamped));
}

/**
 * 获取选中的域名索引
 * @param {HTMLSelectElement} selectElement - 下拉框元素
 * @returns {number}
 */
export function getSelectedDomainIndex(selectElement) {
  const selectedDomain = getSelectedDomain(selectElement);
  if (selectedDomain && selectElement?.options) {
    const options = Array.from(selectElement.options);
    const idx = options.findIndex(option => normalizeDomainChoice(option.textContent) === selectedDomain);
    if (idx >= 0) return idx;
  }
  return Number(selectElement?.value || 0);
}

export function getSelectedDomain(selectElement) {
  const { baseSelect, prefixSelect, customInput } = getPickerElements();
  const pickedDomain = resolveDomainChoice({
    base: baseSelect?.value || '',
    prefix: prefixSelect?.value || '',
    custom: customInput?.value || '',
  });
  if (pickedDomain) return pickedDomain;

  const opt = selectElement?.options?.[selectElement.selectedIndex];
  return normalizeDomainChoice(opt?.textContent || domains[Number(selectElement?.value || 0)] || '');
}

/**
 * 更新范围滑块进度
 * @param {HTMLInputElement} input - 滑块元素
 */
export function updateRangeProgress(input) {
  if (!input) return;
  const min = Number(input.min || 0);
  const max = Number(input.max || 100);
  const val = Number(input.value || min);
  const percent = ((val - min) * 100) / (max - min);
  input.style.background = `linear-gradient(to right, var(--primary) ${percent}%, var(--border-light) ${percent}%)`;
}

export default {
  getDomains,
  setDomains,
  populateDomains,
  loadDomains,
  getStoredLength,
  saveLength,
  getSelectedDomain,
  getSelectedDomainIndex,
  updateRangeProgress,
  STORAGE_KEYS
};
