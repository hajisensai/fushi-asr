/*
 * i18n 的 React 绑定，单独一个文件是为了让 lib/i18n.ts 保持零依赖：
 * files.ts / api.ts 的测试用 node --test 直接跑 TypeScript，不该被 react 拖进来。
 */
import { useSyncExternalStore } from 'react';
import { getLanguage, subscribe, t } from './i18n.ts';

/** 订阅语言变化的翻译函数；语言一换，用到它的组件重渲染。 */
export function useT(): typeof t {
  useSyncExternalStore(subscribe, getLanguage, getLanguage);
  return t;
}
export function useLanguage(): string {
  return useSyncExternalStore(subscribe, getLanguage, getLanguage);
}
