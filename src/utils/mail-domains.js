/**
 * 邮件域名配置解析
 * 支持直接域名列表，或通过前缀与基础域名笛卡尔积生成列表。
 *
 * @param {object} env - 环境变量对象
 * @returns {Array<string>} 域名列表
 */

function splitConfigList(value) {
  return String(value || '')
    .split(/[,\s]+/)
    .map(item => item.trim())
    .filter(Boolean);
}

export function getMailDomains(env = {}) {
  const directDomains = splitConfigList(env.MAIL_DOMAIN);
  if (directDomains.length > 0) {
    return [...new Set(directDomains)];
  }

  const prefixes = splitConfigList(env.MAIL_DOMAIN_PREFIXES);
  const bases = splitConfigList(env.MAIL_DOMAIN_BASES);

  if (prefixes.length > 0 && bases.length > 0) {
    return [...new Set(
      [
        ...prefixes.flatMap(prefix => bases.map(base => `${prefix}.${base}`)),
        ...bases
      ]
    )];
  }

  return ['temp.example.com'];
}
