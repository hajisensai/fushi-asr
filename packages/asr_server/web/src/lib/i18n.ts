/*
 * 界面语言。语言集合、自称、检测顺序与官网 fushi.moe/public/site.js 完全一致
 * （官网又与 app 的 lib/i18n/*.i18n.json 一致），三处是同一批 17 种语言。
 *
 * 与官网的两处不同，都是「工作台跑在本机」带来的：
 *  - 字典全部打进包里，不按语言烤静态页、也不 fetch /i18n/<code>.json。离线单文件
 *    是这个界面的硬约束，任何运行时下载都不能有；代价是包大了几十 KB。
 *  - 因此不存在「先闪一屏中文再换语言」，官网那套 i18n-pending 藏 body 的处理不需要。
 *
 * 判定顺序沿用官网规矩：?lang= → 记住的选择 → 浏览器 Accept-Language。地址里写了
 * 语言就按地址来，不让偏好把它顶掉。任何一步失败都只能退化成「看到源语言中文」。
 *
 * 翻译取值走模块级函数 t() 而不是 React context：files.ts / api.ts 里的报错文案
 * 也要翻译，它们不是组件，拿不到 context。React 侧的订阅在 i18n-react.ts —— 这个
 * 文件不 import react，node --test 才能直接跑它和它的下游。
 */
import { dictionaries, source, type Dict, type Key } from '../i18n/index.ts';

export type { Key } from '../i18n/index.ts';

/** 与 app、官网同集；顺序即菜单顺序。第二项是该语言的自称，菜单里不翻译。 */
export const LANGS: readonly (readonly [string, string])[] = [
  ['zh-CN', '简体中文'],
  ['zh-HK', '繁體中文'],
  ['en', 'English'],
  ['ja', '日本語'],
  ['ko', '한국어'],
  ['de', 'Deutsch'],
  ['es', 'Español'],
  ['fr', 'Français'],
  ['it', 'Italiano'],
  ['nl', 'Nederlands'],
  ['pt-BR', 'Português (Brasil)'],
  ['ru', 'Русский'],
  ['tr', 'Türkçe'],
  ['vi', 'Tiếng Việt'],
  ['th', 'ไทย'],
  ['id', 'Bahasa Indonesia'],
  ['ar', 'العربية'],
];
/** 字典源语言：界面文案先写成简体中文，其余语言由它翻译而来。 */
export const SOURCE = 'zh-CN';
const RTL = new Set(['ar']);
const STORE = 'fushi-ui-lang';
const codes = LANGS.map(([code]) => code);

export function nativeNameOf(code: string): string {
  return LANGS.find(([value]) => value === code)?.[1] ?? code;
}
export function isRtl(code: string): boolean {
  return RTL.has(code);
}

/**
 * 浏览器语言标签 → 本站语言。zh 按字形分流（繁体/港台澳 → zh-HK，其余 → zh-CN），
 * pt 一律归 pt-BR（官网只有巴西葡语一份字典）。认不出返回 null。
 */
export function matchTag(tag: string | null | undefined): string | null {
  const value = String(tag || '').toLowerCase();
  if (!value) return null;
  const exact = codes.find(code => code.toLowerCase() === value);
  if (exact) return exact;
  const primary = value.split('-')[0];
  if (primary === 'zh') return /hant|tw|hk|mo/.test(value) ? 'zh-HK' : 'zh-CN';
  if (primary === 'pt') return 'pt-BR';
  return codes.find(code => code.toLowerCase().split('-')[0] === primary) ?? null;
}

/**
 * navigator.languages（即请求头 Accept-Language 的顺序）里第一个本站支持的语言。
 * 不掺任何地区/时区猜测——浏览器把哪种语言排在第一就给哪种；都不支持退回英文。
 */
export function detect(list: readonly string[]): string {
  for (const tag of list) {
    const hit = matchTag(tag);
    if (hit) return hit;
  }
  return 'en';
}

/** ?lang= → 记住的选择 → 浏览器。地址里的显式请求压过记住的偏好。 */
export function initialLanguage(search: string, stored: string | null, list: readonly string[]): string {
  const asked = new URLSearchParams(search).get('lang');
  return matchTag(asked) ?? (stored && matchTag(stored)) ?? detect(list);
}

let current = SOURCE;
let dict: Dict = source;
const listeners = new Set<() => void>();

export function getLanguage(): string {
  return current;
}
export function setLanguage(code: string): void {
  const next = matchTag(code) ?? SOURCE;
  if (next === current) return;
  current = next;
  dict = dictionaries[next] ?? source;
  applyDocumentLanguage();
  try { localStorage.setItem(STORE, next); } catch { /* 无痕模式：记不住就每次重新检测 */ }
  listeners.forEach(listener => listener());
}
function applyDocumentLanguage(): void {
  const root = document.documentElement;
  root.lang = current;
  root.dir = isRtl(current) ? 'rtl' : 'ltr';
  document.title = t('meta.title');
}
/** 启动时定一次语言：不写 localStorage（用户还没选过），但要把 <html lang/dir> 落实。 */
export function startLanguage(): void {
  const stored = (() => { try { return localStorage.getItem(STORE); } catch { return null; } })();
  const list = navigator.languages?.length ? navigator.languages : [navigator.language || 'en'];
  current = initialLanguage(location.search, stored, list);
  dict = dictionaries[current] ?? source;
  applyDocumentLanguage();
}

/**
 * 取一条文案。{name} 占位符按 params 替换。
 * 缺键退回源语言的中文，绝不返回空串或键名——少一条翻译只该是「这一句是中文」。
 */
export function t(key: Key, params?: Record<string, string | number>): string {
  const template = dict[key] ?? source[key] ?? key;
  if (!params) return template;
  return template.replace(/\{(\w+)\}/g, (whole, name: string) => (name in params ? String(params[name]) : whole));
}

/** t() 的类型，给不想 import t 本体的调用方用。 */
export type Translate = typeof t;

/** 语言变化订阅，供 i18n-react.ts 的 useSyncExternalStore 使用。 */
export function subscribe(listener: () => void): () => void {
  listeners.add(listener);
  return () => { listeners.delete(listener); };
}
