import { source } from '../i18n/index.ts';
import type { Key, Translate } from './i18n.ts';
import type { ProgressEvent } from './types.ts';

/**
 * 进度事件里那句人读说明，按界面语言显示。
 *
 * 服务端的 `detail` 是**一种语言写死的字符串**（历史原因是中文），界面切成任何
 * 语言都不变。所以带 `detailCode` 的事件按 code 查本地词条；没有 code 的（第三方
 * 后端、旧版服务端）才回退显示服务端原文——回退比空白强。
 */
export function progressDetail(event: ProgressEvent, t: Translate): string {
  const code = event.detailCode;
  if (code) {
    const key = `detail.${code}` as Key;
    if (key in source) return t(key);
  }
  return event.detail ?? '';
}
