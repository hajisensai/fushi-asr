import { useState } from 'react';
import { CaptionsIcon, AudioLinesIcon, PanelLeftIcon } from 'lucide-react';
import { Button } from '@/components/ui/button';
import { Sheet, SheetContent, SheetHeader, SheetTitle, SheetDescription, SheetTrigger } from '@/components/ui/sheet';
import type { WorkspaceMode } from '@/lib/types';

type Props = { mode: WorkspaceMode; disabled: boolean; onChange: (mode: WorkspaceMode) => void };
function Navigation({ mode, disabled, onChange }: Props) {
  return <nav aria-label="功能导航" className="flex flex-col gap-2">
    <Button variant={mode === 'generate' ? 'secondary' : 'ghost'} className="justify-start h-10" aria-current={mode === 'generate' ? 'page' : undefined} disabled={disabled} onClick={() => onChange('generate')}><CaptionsIcon data-icon="inline-start" />生成字幕</Button>
    <Button variant={mode === 'retime' ? 'secondary' : 'ghost'} className="justify-start h-10" aria-current={mode === 'retime' ? 'page' : undefined} disabled={disabled} onClick={() => onChange('retime')}><AudioLinesIcon data-icon="inline-start" />字幕对轴</Button>
  </nav>;
}
export function DesktopNavigation(props: Props) {
  return <aside className="workspace-sidebar"><p className="note mb-4 px-2">工作台</p><Navigation {...props} /><p className="note mt-auto pt-10 px-2">{props.mode === 'retime' ? '已有文字，校准时间。' : '从声音开始，生成字幕。'}</p></aside>;
}
export function MobileNavigation(props: Props) {
  const [open, setOpen] = useState(false);
  return <Sheet open={open} onOpenChange={setOpen}><SheetTrigger asChild><Button className="md:hidden" variant="ghost" size="icon" aria-label="打开功能导航"><PanelLeftIcon /></Button></SheetTrigger>
    <SheetContent side="left"><SheetHeader><SheetTitle>Fushi · 字幕工作台</SheetTitle><SheetDescription>选择生成字幕或校准已有字幕。</SheetDescription></SheetHeader><div className="px-4"><Navigation {...props} onChange={mode => { props.onChange(mode); setOpen(false); }} /></div></SheetContent>
  </Sheet>;
}
