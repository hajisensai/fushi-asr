/*
 * 站点外壳：顶栏 / 语言菜单 / 底栏 / 回到顶部。形状与类名照搬官网
 * fushi.moe/public/chrome.css 的标记约定（.site-nav / .site-nav-lang / .site-footer /
 * .site-totop），样式在 styles.css。官网那两处标记（静态首页 + Layout.vue）改了，
 * 这里也要跟着改，否则从官网点进本机工作台视觉会断裂。
 *
 * 与官网的差别只有一处：官网顶栏放的是「怎么开始」和社区图标，工作台放的是两个
 * 工作模式——顶栏在这里既是导航也是模式开关，任务运行中要锁住。
 *
 * 这两个模式做成分段开关（.site-nav-modes）而不是官网那种文字链，是改过一次的：
 * 文字链和社区入口长得一样，读起来像装饰导航，用户找不到「字幕对轴」在哪；窄屏还
 * 被收进汉堡里，等于藏了两层。分段开关自带「共两项、你在其中一项」的含义，所以
 * 汉堡整个去掉了——任何宽度下两个模式都直接可见，窄屏只收起文字留图标。
 */
import { useEffect, useRef, useState, type ReactNode } from 'react';
import { ArrowUpIcon, AudioLinesIcon, CaptionsIcon, ChevronDownIcon, GlobeIcon, MoonIcon, PlusIcon, SunIcon } from 'lucide-react';
import logo from '@/assets/fushi-icon.png';
import { LANGS, nativeNameOf, setLanguage } from '@/lib/i18n';
import { useLanguage, useT } from '@/lib/i18n-react';
import type { WorkspaceMode } from '@/lib/types';

/** 点外面或按 Esc 关掉浮层。菜单和窄屏导航面板共用一套关闭规则。 */
function useDismiss(open: boolean, close: () => void) {
  const host = useRef<HTMLDivElement>(null);
  useEffect(() => {
    if (!open) return;
    const outside = (event: MouseEvent) => { if (!host.current?.contains(event.target as Node)) close(); };
    const escape = (event: KeyboardEvent) => { if (event.key === 'Escape') close(); };
    document.addEventListener('pointerdown', outside);
    document.addEventListener('keydown', escape);
    return () => { document.removeEventListener('pointerdown', outside); document.removeEventListener('keydown', escape); };
  }, [open, close]);
  return host;
}

function LanguageMenu() {
  const t = useT(), current = useLanguage();
  const [open, setOpen] = useState(false);
  const host = useDismiss(open, () => setOpen(false));
  const currentName = nativeNameOf(current);
  return <div className="site-nav-lang" ref={host}>
    <button type="button" className="site-nav-lang-btn" aria-expanded={open} aria-haspopup="listbox" aria-label={t('nav.language')} onClick={() => setOpen(value => !value)}>
      <GlobeIcon aria-hidden /><span className="site-nav-lang-current">{currentName}</span><ChevronDownIcon className="chev" aria-hidden />
    </button>
    <ul className="site-nav-lang-menu" role="listbox" aria-label={t('nav.language')} hidden={!open}>
      {LANGS.map(([code, name]) => <li key={code} role="none">
        <button type="button" role="option" aria-selected={code === current} className={code === current ? 'on' : undefined}
          onClick={() => { setLanguage(code); setOpen(false); }}>
          {name}<span className="site-nav-lang-sub">{code}</span>
        </button>
      </li>)}
    </ul>
  </div>;
}

type NavProps = { mode: WorkspaceMode; busy: boolean; dark: boolean; onMode: (mode: WorkspaceMode) => void; onTheme: () => void; onNewTask: () => void };
export function SiteNav({ mode, busy, dark, onMode, onTheme, onNewTask }: NavProps) {
  const t = useT();
  const item = (value: WorkspaceMode, label: string, Icon: typeof CaptionsIcon) =>
    <button type="button" aria-current={mode === value ? 'page' : undefined} disabled={busy}
      onClick={() => onMode(value)}><Icon aria-hidden /><span className="word">{label}</span></button>;
  return <nav className="site-nav" id="top" aria-label={t('nav.sub')}>
    <a className="site-nav-brand" href="#workspace">
      <img className="logo" src={logo} alt="" width={26} height={26} />
      {t('nav.brand')}<span className="sub">{t('nav.sub')}</span>
    </a>
    <div className="site-nav-right">
      <div className="site-nav-modes" role="group" aria-label={t('nav.modes')}>
        {item('generate', t('nav.generate'), CaptionsIcon)}
        {item('retime', t('nav.retime'), AudioLinesIcon)}
      </div>
      <LanguageMenu />
      <button type="button" className="icon-btn" aria-label={dark ? t('nav.themeToLight') : t('nav.themeToDark')} onClick={onTheme}>{dark ? <MoonIcon aria-hidden /> : <SunIcon aria-hidden />}</button>
      <button type="button" className="btn" disabled={busy} onClick={onNewTask}><PlusIcon aria-hidden />{t('nav.newTask')}</button>
    </div>
  </nav>;
}

export function SiteFooter() {
  const t = useT();
  return <footer className="site-footer">
    <p>{t('footer.tagline')}</p>
    <nav className="site-footer-links" aria-label={t('nav.brand')}>
      <a href="https://github.com/hajisensai/fushi-subtitles" target="_blank" rel="noreferrer noopener">{t('footer.repo')}</a>
      <a href="https://fushi.moe" target="_blank" rel="noreferrer noopener">{t('footer.site')}</a>
    </nav>
    <p className="site-footer-legal"><a href="https://www.gnu.org/licenses/gpl-3.0.html" target="_blank" rel="noreferrer noopener">{t('footer.legal')}</a></p>
  </footer>;
}

/** 滚过首屏才出现的浮动小钮，与官网 .site-totop 同一行为。 */
export function ToTop() {
  const t = useT();
  const [show, setShow] = useState(false);
  useEffect(() => {
    const onScroll = () => setShow(window.scrollY > window.innerHeight * 0.6);
    onScroll();
    window.addEventListener('scroll', onScroll, { passive: true });
    return () => window.removeEventListener('scroll', onScroll);
  }, []);
  return <a className={show ? 'site-totop show' : 'site-totop'} href="#top" aria-label={t('nav.totop')} aria-hidden={!show} tabIndex={show ? 0 : -1}><ArrowUpIcon aria-hidden /></a>;
}

/** 官网的分节尺度：整幅背景 + 居中限宽的内容列。 */
export function Section({ id, band, label, children }: { id?: string; band?: boolean; label?: string; children: ReactNode }) {
  return <section id={id} aria-label={label} className={band ? 'band' : undefined}>
    <div className="shell section">{children}</div>
  </section>;
}
