import { useCallback, useEffect, useRef, useState } from 'react';
import { Button } from '@/components/ui/button';
import { Alert, AlertDescription } from '@/components/ui/alert';
import { modelStatus, pullModel, type ModelStatus } from '@/lib/api';
import { useT } from '@/lib/i18n-react';

/**
 * 选好语言/引擎之后、开始转录之前的模型现状。
 *
 * 存在的理由是两件在此之前都看不见的事：
 *
 * 1. **模型要下载**。此前模型只在转录途中按需下载，界面把那段时间和真正的转录
 *    混在一起，用户看到的是「转录很久没动」。现在选完模型就能看到「还差多少、
 *    点这里下载」，下载完再开始转录，那段等待不再假装成转录。
 * 2. **会不会掉进 CPU**。EP 探测失败是一条真实的降级路径（有 GPU 也会退成
 *    CPU），代价是整本按 CPU 速度跑完。不显示出来，用户只能对着一场慢转录猜
 *    原因——那正是最难查的那种「没坏但不对」。
 */
export function ModelStatusPanel({ language, engine, token, disabled }: {
  language: string;
  engine: string;
  token: string;
  disabled: boolean;
}) {
  const t = useT();
  const [status, setStatus] = useState<ModelStatus | null>(null);
  const [checking, setChecking] = useState(false);
  const [pulling, setPulling] = useState(false);
  const [percent, setPercent] = useState('');
  const [error, setError] = useState('');
  const abort = useRef<AbortController | null>(null);

  const check = useCallback(async () => {
    if (!language) return;
    abort.current?.abort();
    const controller = new AbortController();
    abort.current = controller;
    setChecking(true);
    setError('');
    try {
      setStatus(await modelStatus(language, engine, token, controller.signal));
    } catch (e) {
      if (controller.signal.aborted) return;
      // 查不到不是致命错误（旧版服务端没有这个端点）：整块隐藏，转录路径照旧。
      setStatus(null);
      setError(e instanceof Error ? e.message : String(e));
    } finally {
      if (!controller.signal.aborted) setChecking(false);
    }
  }, [language, engine, token]);

  useEffect(() => {
    void check();
    return () => abort.current?.abort();
  }, [check]);

  async function pull() {
    setPulling(true);
    setPercent('');
    setError('');
    try {
      await pullModel(language, engine, token, ev => {
        const total = ev.totalMs ?? 0;
        const done = ev.processedMs ?? 0;
        setPercent(total > 0 ? Math.round((done / total) * 100) + '%' : '');
      });
      await check();
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    } finally {
      setPulling(false);
    }
  }

  if (checking && !status) return <p className="note mt-2">{t('model.checking')}</p>;
  if (!status) return error ? null : null;
  if (status.managed) return <p className="note mt-2">{t('model.managed')}</p>;

  return (
    <div className="mt-2 flex flex-col gap-2">
      {status.ready ? (
        <p className="note">
          {t('model.ready', { provider: status.provider ?? '' })}
        </p>
      ) : (
        <div className="flex items-center gap-3 flex-wrap">
          <p className="note">
            {t('model.missing', { size: formatBytes(status.bytesToDownload ?? 0) })}
          </p>
          <Button type="button" size="sm" onClick={pull} disabled={disabled || pulling}>
            {pulling ? t('model.pulling', { percent }) : t('model.pull')}
          </Button>
        </div>
      )}
      {status.probeError ? (
        <Alert>
          <AlertDescription>
            {t('model.cpuFallback', { reason: status.probeError })}
          </AlertDescription>
        </Alert>
      ) : null}
    </div>
  );
}

/** 字节数的可读写法。1 位小数够用，模型是百 MB ~ GB 量级。 */
export function formatBytes(bytes: number): string {
  if (bytes <= 0) return '0 MB';
  const mb = bytes / (1024 * 1024);
  return mb >= 1024 ? (mb / 1024).toFixed(1) + ' GB' : mb.toFixed(1) + ' MB';
}
