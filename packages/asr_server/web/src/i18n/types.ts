import source from './zh-CN.ts';

/** 文案键：由源语言字典的键集定义。别的字典多一条少一条都过不了 tsc。 */
export type Key = keyof typeof source;
export type Dict = Record<Key, string>;
