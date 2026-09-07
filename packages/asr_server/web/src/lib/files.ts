export type FileKind = 'epub' | 'audio' | 'subtitle';
export function fileError(files: ArrayLike<Pick<File, 'name' | 'size' | 'type'>>, kind: FileKind): string | null {
  if (files.length !== 1) return '每个区域请放入一个文件。';
  const file = files[0];
  if (file.size === 0) return '不能使用空文件。';
  if (kind === 'epub') {
    if (!/\.epub$/i.test(file.name)) return '正文区域只接受 EPUB 文件。';
    if (file.size > 64 * 1024 * 1024) return 'EPUB 超过 64 MiB 上限。';
  } else if (kind === 'subtitle') {
    if (!/\.(srt|vtt)$/i.test(file.name)) return '请放入 SRT 或 WebVTT 字幕文件。';
    if (file.size > 8 * 1024 ** 2) return '字幕超过 8 MiB 上限。';
  } else {
    if (!/^(audio|video)\//.test(file.type) && !/\.(m4b|mp3|wav|flac|m4a|mp4|mkv|mka|ogg|opus|aac|aiff?|wma|webm|mov|avi)$/i.test(file.name)) return '请在此处放入音频或视频文件。';
    if (file.size > 4 * 1024 ** 3) return '音频超过默认 4 GiB 上限。';
  }
  return null;
}
