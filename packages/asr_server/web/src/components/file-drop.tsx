import { useRef, useState } from 'react';
import { BookOpenIcon, FileAudioIcon, CaptionsIcon, XIcon } from 'lucide-react';
import { Button } from '@/components/ui/button';
import { Field, FieldDescription, FieldError, FieldLabel } from '@/components/ui/field';
import { fileError, type FileKind } from '@/lib/files';

type Props = { kind: FileKind; file: File | null; disabled: boolean; onChange: (file: File | null) => void };
const fileKinds = {
  epub: { title: 'EPUB 正文', Icon: BookOpenIcon, prompt: '将 EPUB 拖到这里', id: 'epub', accept: '.epub,application/epub+zip', note: '同一卷、同一版本 · 最大 64 MiB' },
  audio: { title: '音频或视频', Icon: FileAudioIcon, prompt: '将音频或视频拖到这里', id: 'file', accept: 'audio/*,video/*,.m4b,.mka,.opus,.flac', note: 'M4B、MP3、WAV、MP4、MKV 等 · 每次一个文件' },
  subtitle: { title: '待校准字幕', Icon: CaptionsIcon, prompt: '将已有字幕拖到这里', id: 'subtitle', accept: '.srt,.vtt,application/x-subrip,text/vtt', note: 'SRT / WebVTT · UTF-8 编码 · 最大 8 MiB' },
};
export function FileDrop({ kind, file, disabled, onChange }: Props) {
  const input = useRef<HTMLInputElement>(null), trigger = useRef<HTMLButtonElement>(null);
  const depth = useRef(0);
  const [dragging, setDragging] = useState(false), [error, setError] = useState<string | null>(null);
  const { title, Icon, prompt, id, accept: extensions, note } = fileKinds[kind];
  function accept(files: FileList | File[]) {
    if (disabled) return;
    const problem = fileError(files, kind); setError(problem);
    if (!problem) onChange(files[0]);
  }
  return <Field data-disabled={disabled || undefined} data-invalid={!!error || undefined}>
    <FieldLabel htmlFor={`${kind}-drop`}>{title}</FieldLabel>
    <div className="relative min-w-0" onDragEnter={e => { e.preventDefault(); if (!disabled) { depth.current++; setDragging(true); } }}
      onDragOver={e => { e.preventDefault(); e.dataTransfer.dropEffect = disabled ? 'none' : 'copy'; }}
      onDragLeave={e => { e.preventDefault(); depth.current = Math.max(0, depth.current - 1); if (!depth.current) setDragging(false); }}
      onDrop={e => { e.preventDefault(); depth.current = 0; setDragging(false); accept(e.dataTransfer.files); }}>
      <Button ref={trigger} id={`${kind}-drop`} data-testid={`${kind}-drop`} variant="outline" disabled={disabled}
        aria-invalid={!!error || undefined} aria-describedby={`${kind}-note`} data-dragging={dragging && !disabled || undefined}
        className="drop-target w-full min-w-0 h-auto min-h-36 py-6 px-6" onClick={() => input.current?.click()}>
        <span className="flex min-w-0 flex-col items-center gap-3 w-full">
          <Icon data-icon="inline-start" />
          <span className="max-w-full whitespace-normal break-all">{dragging && !disabled ? '松开即可添加' : file ? file.name : prompt}</span>
          <span>{file ? `${(file.size / 1024 / 1024).toFixed(1)} MB · 点击或拖入替换` : '或点击选择文件'}</span>
        </span>
      </Button>
      {file ? <div className="absolute top-2 right-2"><Button variant="ghost" size="icon-sm" disabled={disabled} aria-label={`移除${title}`} onClick={() => { onChange(null); setError(null); if (input.current) input.current.value = ''; trigger.current?.focus(); }}><XIcon data-icon="inline-start" /></Button></div> : null}
      <input ref={input} id={id} type="file" hidden disabled={disabled} tabIndex={-1}
        accept={extensions}
        onChange={e => { if (e.target.files?.length) accept(e.target.files); e.target.value = ''; }} />
    </div>
    <FieldDescription id={`${kind}-note`}>{note}</FieldDescription>
    {error ? <FieldError role="alert">{error}</FieldError> : null}
  </Field>;
}
