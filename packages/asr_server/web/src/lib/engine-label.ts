import { source } from '../i18n/index.ts';
import type { Key } from './i18n.ts';
import { t } from './i18n.ts';

/**
 * 后端（引擎）的展示名与说明。
 *
 * 服务端下发的 `name` / `description` 是**一种语言写死的字符串**：内置后端在
 * server.dart 里是字面量，界面切成任何语言它都不变。所以内置后端的文案改由界面
 * 字典提供，按后端 id 查 `engine.<id>` / `engineDesc.<id>`。
 *
 * 服务端下发的值不丢：**自定义后端**（部署方在 `backends` 里自己配的）不可能出现
 * 在界面字典里，那时仍原样显示服务端给的名字——那是部署方自己写的文案，本就该
 * 照它说的显示。判据是「字典里有没有这条 key」，不是「id 等不等于 default」，
 * 所以将来新增内置后端只需补词条，这里不用改。
 */
export function engineLabel(backend: { id: string; name: string }): string {
  const key = `engine.${backend.id}` as Key;
  return key in source ? t(key) : backend.name;
}

/** 同 [engineLabel]，用于选项下方的一行说明。 */
export function engineDescription(backend: { id: string; description: string }): string {
  const key = `engineDesc.${backend.id}` as Key;
  return key in source ? t(key) : backend.description;
}

/**
 * 结果卡片里的引擎名。结果 JSON 带的是 `engine`（id）+ `engineName`（服务端文案），
 * 与 [engineLabel] 同一套规则——历史结果即使是别的语言下产生的，重新打开时也按
 * 当前界面语言显示。
 */
export function resultEngineLabel(result: { engine: string; engineName: string }): string {
  return engineLabel({ id: result.engine, name: result.engineName });
}
