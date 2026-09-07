import { t } from './i18n.ts';

export type FileKind = 'epub' | 'audio' | 'subtitle';
export function fileError(files: ArrayLike<Pick<File, 'name' | 'size' | 'type'>>, kind: FileKind): string | null {
  if (files.length !== 1) return t('file.error.single');
  const file = files[0];
  if (file.size === 0) return t('file.error.empty');
  if (kind === 'epub') {
    if (!/\.epub$/i.test(file.name)) return t('file.error.epubType');
    if (file.size > 64 * 1024 * 1024) return t('file.error.epubSize');
  } else if (kind === 'subtitle') {
    if (!/\.(srt|vtt)$/i.test(file.name)) return t('file.error.subtitleType');
    if (file.size > 8 * 1024 ** 2) return t('file.error.subtitleSize');
  } else {
    if (!/^(audio|video)\//.test(file.type) && !/\.(m4b|mp3|wav|flac|m4a|mp4|mkv|mka|ogg|opus|aac|aiff?|wma|webm|mov|avi)$/i.test(file.name)) return t('file.error.audioType');
    if (file.size > 4 * 1024 ** 3) return t('file.error.audioSize');
  }
  return null;
}
