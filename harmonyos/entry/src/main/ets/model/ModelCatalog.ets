/**
 * Hermes 鸿蒙原生模型与推理能力目录模型
 * 严格对齐 upstream HermesModelCatalog.swift & HermesCall.swift
 */

export interface ModelCatalogOption {
  id: string;
  displayName: string;
  providerId: string;
  isDefault?: boolean;
}

export interface ModelCatalogGroup {
  id: string;
  name: string;
  providerId: string;
  models: ModelCatalogOption[];
}

export interface ModelCatalog {
  groups: ModelCatalogGroup[];
  activeModel?: ModelCatalogOption;
  capabilities: Record<string, Object>;
}

export const REASONING_EFFORT_LEVELS: string[] = [
  'none',
  'minimal',
  'low',
  'medium',
  'high',
  'xhigh',
  'max',
  'ultra'
];

/**
 * 校验 token 安全性（严格对齐 upstream HermesModelCatalog.sessionModelValue 内部 safe 函数）
 * 宿主服务端按 flag string 解析参数，而非 shell quoting。
 * 必须拒绝可能改变命令行 scope 的字符：
 * 1. 空字符
 * 2. 任何空白字符 (\s)
 * 3. 双破折号 (--)
 * 4. Unicode 破折号：‒ (U+2012), – (U+2013), — (U+2014), ― (U+2015)
 */
export function isSafeToken(value: string): boolean {
  if (!value || value.length === 0) {
    return false;
  }
  if (/\s/.test(value)) {
    return false;
  }
  if (value.includes('--')) {
    return false;
  }
  if (/[‒–—―]/.test(value)) {
    return false;
  }
  return true;
}

/**
 * 生成服务端 session 级模型配置字符串：
 * `${model.id} --provider ${model.provider} --session`
 */
export function formatSessionModelValue(modelId: string, providerId: string): string | null {
  if (!isSafeToken(modelId) || !isSafeToken(providerId)) {
    return null;
  }
  return `${modelId} --provider ${providerId} --session`;
}

/**
 * 解析 model.options 响应报文为结构化 ModelCatalog
 * 严格按照 upstream HermesModelCatalog 规范：
 * - 从 providers[].slug/name/authenticated/models/unavailable_models/capabilities 读取
 * - 排除已认证为 false 的 provider
 * - 排除 unavailable_models
 * - 排除同一个 provider 下的重复模型
 * - 排除没有任何可用模型的 provider group
 * - 顶层 model / provider 作为当前 activeModel
 * - 兼容 fallback：顶层平铺 models 数组（隔离 stub/单模型场景）
 */
export function parseModelCatalog(payload: Record<string, Object>): ModelCatalog {
  if (!payload || typeof payload !== 'object') {
    const emptyCatalog: ModelCatalog = { groups: [], capabilities: {} };
    return emptyCatalog;
  }

  const seenProviders = new Set<string>();
  const capabilities: Record<string, Object> = {};
  const groups: ModelCatalogGroup[] = [];

  const rawProviders = Array.isArray(payload['providers'])
    ? (payload['providers'] as Array<Record<string, Object>>)
    : [];

  for (let i = 0; i < rawProviders.length; i++) {
    const row = rawProviders[i];
    if (!row || typeof row !== 'object') {
      continue;
    }
    const provider = String(row['slug'] || '');
    if (!provider || seenProviders.has(provider)) {
      continue;
    }
    seenProviders.add(provider);

    // 若 authenticated 明确为 false，则排除该 provider
    if (row['authenticated'] === false) {
      continue;
    }

    const seenModels = new Set<string>();
    const unavailableList = Array.isArray(row['unavailable_models'])
      ? (row['unavailable_models'] as string[])
      : [];
    const unavailable = new Set<string>(unavailableList.map(String));

    const rawModels = Array.isArray(row['models']) ? (row['models'] as Object[]) : [];
    const options: ModelCatalogOption[] = [];

    let rawCaps: Record<string, Object> = {};
    if (row['capabilities'] && typeof row['capabilities'] === 'object') {
      rawCaps = row['capabilities'] as Record<string, Object>;
    }

    for (let j = 0; j < rawModels.length; j++) {
      const item: Object = rawModels[j];
      const id = typeof item === 'string' ? item : (item && typeof item === 'object' ? String((item as Record<string, Object>)['id'] || '') : '');
      if (!id || unavailable.has(id) || seenModels.has(id)) {
        continue;
      }
      seenModels.add(id);

      const displayName = (item && typeof item === 'object' && (item as Record<string, Object>)['name'])
        ? String((item as Record<string, Object>)['name'])
        : id;

      const opt: ModelCatalogOption = {
        id: id,
        displayName: displayName,
        providerId: provider
      };
      options.push(opt);

      if (rawCaps[id]) {
        capabilities[`${provider}:${id}`] = rawCaps[id];
      }
    }

    // 只有存在可用模型的 provider 才生成分组
    if (options.length > 0) {
      const group: ModelCatalogGroup = {
        id: provider,
        name: String(row['name'] || provider),
        providerId: provider,
        models: options
      };
      groups.push(group);
    }
  }

  // Fallback 兼容顶层 models 简单结构（如隔离测试环境 stub）
  if (groups.length === 0 && Array.isArray(payload['models'])) {
    const rawFlatModels = payload['models'] as Object[];
    const defaultProvider = String(payload['provider'] || 'default');
    const options: ModelCatalogOption[] = [];
    const seenFlat = new Set<string>();

    for (let i = 0; i < rawFlatModels.length; i++) {
      const m = rawFlatModels[i];
      const id = typeof m === 'string' ? m : String((m as Record<string, Object>)['id'] || (m as Record<string, Object>)['name'] || '');
      const name = typeof m === 'string' ? m : String((m as Record<string, Object>)['name'] || (m as Record<string, Object>)['id'] || '');
      const prov = (typeof m === 'object' && (m as Record<string, Object>)['provider']) ? String((m as Record<string, Object>)['provider']) : defaultProvider;
      if (id && !seenFlat.has(`${prov}:${id}`)) {
        seenFlat.add(`${prov}:${id}`);
        const flatOpt: ModelCatalogOption = {
          id: id,
          displayName: name,
          providerId: prov,
          isDefault: typeof m === 'object' ? Boolean((m as Record<string, Object>)['is_default']) : false
        };
        options.push(flatOpt);
      }
    }

    if (options.length > 0) {
      const group: ModelCatalogGroup = {
        id: defaultProvider,
        name: defaultProvider,
        providerId: defaultProvider,
        models: options
      };
      groups.push(group);
    }
  }

  let activeModel: ModelCatalogOption | undefined = undefined;
  const activeId = payload['model'] ? String(payload['model']) : '';
  if (activeId) {
    const activeProvider = payload['provider'] ? String(payload['provider']) : (groups.length > 0 ? groups[0].providerId : 'default');
    activeModel = {
      id: activeId,
      displayName: activeId,
      providerId: activeProvider
    };
  }

  const result: ModelCatalog = {
    groups: groups,
    activeModel: activeModel,
    capabilities: capabilities
  };
  return result;
}
