/// 服务端自带的最小网页界面。
///
/// 刻意做成**单文件、零外部资源**：服务端常跑在内网或离线机器上，界面依赖 CDN
/// 就等于在最需要它的场合打不开。也因此没有构建步骤——改这里就是改界面。
library;

/// 生成界面 HTML。
String buildWebUi() => r'''<!doctype html>
<html lang="zh">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>asr · 生成字幕</title>
<style>
  :root {
    color-scheme: light dark;
    --bg: #fbfbfa; --fg: #1a1a19; --muted: #6b6b68;
    --line: #e0e0dc; --accent: #2f6f4e; --card: #ffffff;
  }
  @media (prefers-color-scheme: dark) {
    :root { --bg:#17181a; --fg:#e9e9e6; --muted:#9a9a95;
            --line:#2e2f32; --accent:#6fbf8f; --card:#1f2023; }
  }
  * { box-sizing: border-box; }
  body { margin:0; padding:32px 20px; background:var(--bg); color:var(--fg);
         font:15px/1.6 system-ui, -apple-system, "Segoe UI", sans-serif; }
  main { max-width: 760px; margin: 0 auto; }
  h1 { font-size:22px; margin:0 0 4px; letter-spacing:-0.01em; }
  p.sub { color:var(--muted); margin:0 0 28px; }
  .card { background:var(--card); border:1px solid var(--line);
          border-radius:12px; padding:20px; margin-bottom:16px; }
  #drop { border:1.5px dashed var(--line); border-radius:12px; padding:36px 20px;
          text-align:center; color:var(--muted); cursor:pointer;
          transition:border-color .15s, color .15s; }
  #drop.over, #drop:hover { border-color:var(--accent); color:var(--fg); }
  #drop strong { color:var(--fg); }
  .row { display:flex; gap:12px; flex-wrap:wrap; align-items:flex-end;
         margin-top:16px; }
  label { display:block; font-size:13px; color:var(--muted); margin-bottom:4px; }
  select, button, input {
    font:inherit; padding:8px 12px; border-radius:8px;
    border:1px solid var(--line); background:var(--card); color:var(--fg);
  }
  button { background:var(--accent); color:#fff; border-color:transparent;
           cursor:pointer; font-weight:600; }
  button:disabled { opacity:.5; cursor:default; }
  progress { width:100%; height:8px; margin-top:16px; }
  #status { font-variant-numeric: tabular-nums; color:var(--muted);
            margin-top:8px; min-height:1.6em; white-space:pre-wrap; }
  textarea { width:100%; min-height:280px; margin-top:8px; resize:vertical;
             font:13px/1.5 ui-monospace, Menlo, Consolas, monospace;
             padding:12px; border-radius:8px; border:1px solid var(--line);
             background:var(--bg); color:var(--fg); }
  .hidden { display:none; }
  .err { color:#c0392b; }
  @media (prefers-color-scheme: dark) { .err { color:#ff8a7a; } }
</style>
</head>
<body>
<main>
  <h1>生成字幕</h1>
  <p class="sub">选一个音频或视频文件，选语言，开跑。转录在这台服务器上完成。</p>

  <div class="card">
    <div id="drop">
      把文件拖进来，或<strong>点这里选择</strong>
      <div id="picked" class="hidden"></div>
    </div>
    <input id="file" type="file" class="hidden"
           accept="audio/*,video/*,.m4b,.mka,.opus">
    <div class="row">
      <div>
        <label for="lang">语言</label>
        <select id="lang"></select>
      </div>
      <div>
        <label for="fmt">格式</label>
        <select id="fmt">
          <option value="srt">SRT</option>
          <option value="vtt">WebVTT</option>
          <option value="json">JSON</option>
        </select>
      </div>
      <div>
        <label for="token">令牌（服务端设了才需要）</label>
        <input id="token" type="password" placeholder="可留空" size="16">
      </div>
      <button id="go" disabled>开始转录</button>
    </div>
    <progress id="bar" class="hidden" max="1" value="0"></progress>
    <div id="status"></div>
  </div>

  <div class="card hidden" id="outCard">
    <div class="row" style="margin-top:0; justify-content:space-between">
      <strong id="outTitle">字幕</strong>
      <button id="dl">下载</button>
    </div>
    <textarea id="out" spellcheck="false" readonly></textarea>
  </div>
</main>
<script>
(function () {
  var fileInput = document.getElementById('file');
  var drop = document.getElementById('drop');
  var picked = document.getElementById('picked');
  var langSel = document.getElementById('lang');
  var fmtSel = document.getElementById('fmt');
  var tokenInput = document.getElementById('token');
  var go = document.getElementById('go');
  var bar = document.getElementById('bar');
  var status = document.getElementById('status');
  var outCard = document.getElementById('outCard');
  var out = document.getElementById('out');
  var dl = document.getElementById('dl');
  var chosen = null;

  function auth() {
    var t = tokenInput.value.trim();
    return t ? { 'Authorization': 'Bearer ' + t } : {};
  }

  function setStatus(text, isError) {
    status.textContent = text;
    status.className = isError ? 'err' : '';
  }

  function loadLanguages() {
    fetch('v1/models', { headers: auth() })
      .then(function (r) {
        if (!r.ok) throw new Error('HTTP ' + r.status);
        return r.json();
      })
      .then(function (json) {
        langSel.innerHTML = '';
        (json.languages || []).forEach(function (l) {
          var o = document.createElement('option');
          o.value = l.tag;
          o.textContent = l.nativeName + '  (' + l.tag + ')';
          langSel.appendChild(o);
        });
        setStatus('');
      })
      .catch(function (e) {
        setStatus('取语言列表失败：' + e.message +
                  '（服务端设了令牌的话先填上再刷新）', true);
      });
  }

  function choose(f) {
    chosen = f;
    picked.textContent = f.name + '  ·  ' +
      (f.size / (1024 * 1024)).toFixed(1) + ' MB';
    picked.classList.remove('hidden');
    go.disabled = false;
  }

  drop.addEventListener('click', function () { fileInput.click(); });
  fileInput.addEventListener('change', function () {
    if (fileInput.files.length) choose(fileInput.files[0]);
  });
  ['dragenter', 'dragover'].forEach(function (t) {
    drop.addEventListener(t, function (e) {
      e.preventDefault(); drop.classList.add('over');
    });
  });
  ['dragleave', 'drop'].forEach(function (t) {
    drop.addEventListener(t, function (e) {
      e.preventDefault(); drop.classList.remove('over');
    });
  });
  drop.addEventListener('drop', function (e) {
    if (e.dataTransfer.files.length) choose(e.dataTransfer.files[0]);
  });
  tokenInput.addEventListener('change', loadLanguages);

  go.addEventListener('click', function () {
    if (!chosen) return;
    go.disabled = true;
    outCard.classList.add('hidden');
    bar.classList.remove('hidden');
    bar.value = 0;
    setStatus('上传中…');

    var url = 'v1/transcribe?language=' + encodeURIComponent(langSel.value) +
      '&format=' + encodeURIComponent(fmtSel.value) +
      '&filename=' + encodeURIComponent(chosen.name);

    fetch(url, { method: 'POST', body: chosen, headers: auth() })
      .then(function (r) {
        if (!r.ok) {
          return r.text().then(function (t) {
            throw new Error('HTTP ' + r.status + ' ' + t);
          });
        }
        // 流式 NDJSON：一行一个事件，最后一行是结果或错误。
        var reader = r.body.getReader();
        var decoder = new TextDecoder();
        var buffer = '';
        function pump() {
          return reader.read().then(function (res) {
            if (res.done) {
              if (!out.value) throw new Error('连接结束但没收到结果');
              return;
            }
            buffer += decoder.decode(res.value, { stream: true });
            var lines = buffer.split('\n');
            buffer = lines.pop();
            lines.forEach(handleLine);
            return pump();
          });
        }
        return pump();
      })
      .catch(function (e) { setStatus('失败：' + e.message, true); })
      .then(function () { go.disabled = false; });
  });

  function handleLine(line) {
    if (!line.trim()) return;
    var ev;
    try { ev = JSON.parse(line); } catch (e) { return; }
    if (ev.phase === 'error') {
      setStatus('失败：' + ev.error, true);
      return;
    }
    if (ev.phase === 'result') {
      bar.value = 1;
      var speed = ev.elapsedMs > 0
        ? (ev.audioMs / ev.elapsedMs).toFixed(1) + '× 实时'
        : '';
      setStatus('完成：' + ev.cueCount + ' 条 · ' +
        (ev.elapsedMs / 1000).toFixed(1) + ' s · ' + speed +
        ' · EP=' + ev.provider + (ev.fellBack ? '（已降级）' : ''));
      out.value = ev.text;
      outCard.classList.remove('hidden');
      dl.onclick = function () { download(ev.text, ev.format); };
      return;
    }
    bar.value = ev.fraction || 0;
    var pct = ((ev.fraction || 0) * 100).toFixed(1) + '%';
    setStatus(phaseName(ev.phase) + ' ' + pct +
              (ev.detail ? '  ' + ev.detail : ''));
  }

  function phaseName(p) {
    return { queued: '排队中', download: '下载模型', load: '装载模型',
             transcribe: '转录中', done: '收尾' }[p] || p;
  }

  function download(text, format) {
    var base = chosen.name.replace(/\.[^.]+$/, '');
    var blob = new Blob([text], { type: 'text/plain;charset=utf-8' });
    var a = document.createElement('a');
    a.href = URL.createObjectURL(blob);
    a.download = base + '.' + (format || 'srt');
    document.body.appendChild(a);
    a.click();
    document.body.removeChild(a);
    URL.revokeObjectURL(a.href);
  }

  loadLanguages();
})();
</script>
</body>
</html>
''';
