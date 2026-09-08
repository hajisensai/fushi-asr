/*
 * 17 种界面语言的字典，全部静态导入打进包里——离线单文件不允许运行时下载。
 * 语言集合与顺序见 lib/i18n.ts 的 LANGS，两处必须一致（i18n.test.ts 守这一点）。
 */
import zhCN from './zh-CN.ts';
import zhHK from './zh-HK.ts';
import en from './en.ts';
import ja from './ja.ts';
import ko from './ko.ts';
import de from './de.ts';
import es from './es.ts';
import fr from './fr.ts';
import it from './it.ts';
import nl from './nl.ts';
import ptBR from './pt-BR.ts';
import ru from './ru.ts';
import tr from './tr.ts';
import vi from './vi.ts';
import th from './th.ts';
import id from './id.ts';
import ar from './ar.ts';
import type { Dict } from './types.ts';

export type { Dict, Key } from './types.ts';
export const source: Dict = zhCN;
export const dictionaries: Record<string, Dict> = {
  'zh-CN': zhCN, 'zh-HK': zhHK, en, ja, ko, de, es, fr, it, nl, 'pt-BR': ptBR, ru, tr, vi, th, id, ar,
};
