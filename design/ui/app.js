/**
 * cvMaster UI 原型控制器。
 * 所有记录、设置和分组仅存在当前页面内存中；不读写剪贴板、不联网、不使用 JSON 字段存储。
 * @author helele
 * @since 2026-10-19
 */
'use strict';

const icons = {
  clipboard: '<rect x="6" y="5" width="12" height="16" rx="2"/><rect x="9" y="3" width="6" height="4" rx="1"/><path d="M9 12h6m-6 4h4"/>',
  layers: '<rect x="4" y="4" width="16" height="12" rx="2"/><path d="M7 20h10M8 8h8m-8 4h5"/>',
  pin: '<path d="m9 3 6 0-1 6 4 4v2H6v-2l4-4-1-6Zm3 12v6"/>',
  inbox: '<path d="m4 4-2 11v5h20v-5L20 4H4Z"/><path d="M2 15h6l2 3h4l2-3h6"/>',
  plus: '<path d="M12 5v14M5 12h14"/>',
  search: '<circle cx="10.5" cy="10.5" r="6.5"/><path d="m16 16 5 5"/>',
  shield: '<path d="m12 3 8 3v6c0 4-4 7-8 9-4-2-8-5-8-9V6l8-3Z"/><path d="m8 12 3 3 5-6"/>',
  settings: '<path d="m9 3-1 3-3 1-2 3 2 2-1 3 3 2 1 3h4l1-3 3-1 2-3-2-2 1-3-3-2-1-3H9Z"/><circle cx="10" cy="12" r="3"/>',
  command: '<path d="M9 7H6a3 3 0 1 1 3-3v14a3 3 0 1 1-3-3h12a3 3 0 1 1-3 3V4a3 3 0 1 1 3 3H9Z"/>',
  moon: '<path d="M20 14A8.5 8.5 0 0 1 10 3a9 9 0 1 0 10 11Z"/>',
  sun: '<circle cx="12" cy="12" r="4"/><path d="M12 2v2m0 16v2M2 12h2m16 0h2M5 5l1.5 1.5m11 11L19 19M5 19l1.5-1.5m11-11L19 5"/>',
  text: '<path d="M4 5h16M12 5v15m-4 0h8M4 5v3m16-3v3"/>',
  link: '<path d="m10 14 4-4m-6 6-1 1a4 4 0 0 1-6-6l5-5a4 4 0 0 1 6 0m0 2 1-1a4 4 0 0 1 6 6l-5 5a4 4 0 0 1-6 0" transform="translate(2 0)"/>',
  image: '<rect x="3" y="3" width="18" height="18" rx="3"/><circle cx="8" cy="8" r="1.5"/><path d="m3 17 5-5 4 4 4-6 5 6"/>',
  file: '<path d="M5 3h9l5 5v13H5V3Zm9 0v6h5M8 13h8m-8 4h6"/>',
  copy: '<rect x="8" y="8" width="12" height="13" rx="2"/><path d="M16 8V3H3v13h5"/>',
  trash: '<path d="M4 6h16M9 6V3h6v3M6 6l1 15h10l1-15M10 10v7m4-7v7"/>',
  close: '<path d="m6 6 12 12M6 18 18 6"/>',
  'arrow-up-right': '<path d="M6 18 18 6M6 6h12v12"/>',
  lock: '<rect x="5" y="10" width="14" height="11" rx="2"/><path d="M8 10V7a4 4 0 0 1 8 0v3m-4 5v2"/>',
  info: '<circle cx="12" cy="12" r="9"/><path d="M12 11v6m0-10v.1"/>',
  drive: '<rect x="3" y="4" width="18" height="16" rx="3"/><path d="M3 14h18m-5 3h2"/>',
  edit: '<path d="m15 4 5 5M4 20l5-1L21 7l-5-5L4 14v6Z"/>',
  check: '<path d="m5 12 4 4L19 6"/>',
  folder: '<path d="M3 6h7l2 3h9v11H3V6Z"/>',
};

/** 创建受控图标标记；图标路径仅来自静态白名单。 */
function icon(name) {
  return `<svg viewBox="0 0 24 24" aria-hidden="true">${icons[name] || icons.text}</svg>`;
}

/** 转义所有动态文本，防止演示分组名称被当作 HTML 执行。 */
function escapeHTML(value) {
  return String(value).replace(/[&<>"']/g, char => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[char]);
}

const $ = selector => document.querySelector(selector);
const $$ = selector => [...document.querySelectorAll(selector)];
const typeLabels = { all: '全部', text: '文本', link: '链接', image: '图片', file: '文件' };

// 多值分组关系在内存中使用数组，仅用于评审；正式版采用关系表，不序列化到 JSON 字段。
let groups = [
  { id: 'work', name: '工作空间', color: '#b17b50' },
  { id: 'inspiration', name: '灵感收集', color: '#849c7a' },
  { id: 'development', name: '开发片段', color: '#8c8eae' },
];
let entries = [
  { id: 'e1', type: 'text', title: '把灵感留住，把时间还给生活。', body: '把灵感留住，把时间还给生活。\n\n不必记住每一次复制，只需要在想起时，随手找回。\n\n少一点寻找，多一点专注。', excerpt: '不必记住每一次复制，只需要在想起时，随手找回。', source: '备忘录', sourceMark: 'N', size: '186 B', created: '今天 10:24', time: '2 分钟前', period: '今天', pinned: true, groups: ['work'], copies: 6 },
  { id: 'e2', type: 'link', title: 'Apple Human Interface Guidelines', body: 'https://developer.apple.com/design/human-interface-guidelines', excerpt: '为 Apple 平台设计自然、一致且精致的使用体验。', source: 'Safari', sourceMark: 'S', size: '68 B', created: '今天 10:18', time: '8 分钟前', period: '今天', pinned: true, groups: ['inspiration', 'development'], copies: 3 },
  { id: 'e3', type: 'image', title: '山野之间 · 配色参考', body: '山野之间 · 配色参考', excerpt: '柔和的天空、起伏的山野与温暖的自然色。', source: '截图', sourceMark: '截', size: '2.4 MB', created: '今天 10:12', time: '14 分钟前', period: '今天', pinned: false, groups: ['inspiration'], copies: 1 },
  { id: 'e4', type: 'text', title: '一个安静、高效的剪贴板', body: '原生 macOS，轻盈常驻。\n\n⌥ Space 随时唤起\n文字、链接、图片、文件\n分组整理，重要内容置顶\n\n一期只在本地，不上传内容。', excerpt: '原生 macOS，轻盈常驻。文字、链接、图片、文件，一处整理。', source: '备忘录', sourceMark: 'N', size: '248 B', created: '今天 10:03', time: '23 分钟前', period: '今天', pinned: false, groups: ['work'], copies: 2 },
  { id: 'e5', type: 'file', title: '品牌设计素材', body: 'Brand Guidelines.pdf\nApp Icon.sketch\nColor Palette.ase', excerpt: '3 个文件 · 仅保存引用', source: 'Finder', sourceMark: 'F', size: '8.6 MB（原文件）', created: '今天 09:56', time: '30 分钟前', period: '今天', pinned: false, groups: ['work'], copies: 1, fileCount: 3 },
  { id: 'e6', type: 'text', title: 'SwiftUI · 让界面保持轻盈', body: 'struct ClipboardCard: View {\n    let title: String\n\n    var body: some View {\n        Text(title)\n            .lineLimit(2)\n    }\n}', excerpt: 'struct ClipboardCard: View {\n    let title: String', source: 'Xcode', sourceMark: 'X', size: '151 B', created: '今天 09:40', time: '46 分钟前', period: '今天', pinned: false, groups: ['development'], copies: 1, code: true },
  { id: 'e7', type: 'link', title: 'SF Symbols · 原生图标语言', body: 'https://developer.apple.com/sf-symbols/', excerpt: '与 Apple 系统字体自然融合的符号库。', source: 'Safari', sourceMark: 'S', size: '43 B', created: '昨天 17:28', time: '昨天', period: '昨天', pinned: false, groups: [], copies: 1 },
  { id: 'e8', type: 'file', title: '旧版交互草图.fig', body: '旧版交互草图.fig', excerpt: '原文件已移动或不可访问', source: 'Finder', sourceMark: 'F', size: '未知', created: '昨天 15:02', time: '昨天', period: '昨天', pinned: false, groups: [], copies: 1, fileCount: 1, invalid: true },
];
const state = { view: 'all', type: 'all', query: '', selected: 'e1', quickSelected: 'e1', paused: false, editingGroup: null };
let confirmAction = null;
let toastTimer;

/** 根据本地条件筛选，并保证置顶优先、其余维持演示的时间顺序。 */
function visibleEntries() {
  const query = state.query.trim().toLocaleLowerCase();
  return entries.filter(entry => {
    const viewMatches = state.view === 'all' || (state.view === 'pinned' && entry.pinned) || (state.view === 'ungrouped' && !entry.groups.length) || entry.groups.includes(state.view);
    const groupNames = entry.groups.map(id => groups.find(group => group.id === id)?.name || '').join(' ');
    return viewMatches && (state.type === 'all' || entry.type === state.type) && `${entry.title} ${entry.body} ${groupNames}`.toLocaleLowerCase().includes(query);
  }).sort((a, b) => Number(b.pinned) - Number(a.pinned));
}

function selectedEntry() {
  return entries.find(entry => entry.id === state.selected);
}

function showToast(message) {
  const toast = $('#toast');
  toast.textContent = message;
  toast.classList.add('visible');
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => toast.classList.remove('visible'), 2800);
}

function renderNavigation() {
  $('#count-all').textContent = entries.length;
  $('#count-pinned').textContent = entries.filter(entry => entry.pinned).length;
  $('#count-ungrouped').textContent = entries.filter(entry => !entry.groups.length).length;
  $('#footer-count').textContent = entries.length;
  $('#group-nav').innerHTML = groups.map(group => `<div class="group-row"><button class="nav-item ${state.view === group.id ? 'active' : ''}" data-view="${group.id}" ${state.view === group.id ? 'aria-current="page"' : ''}><span class="group-dot" style="--group-color:${group.color}"></span><span>${escapeHTML(group.name)}</span><b>${entries.filter(entry => entry.groups.includes(group.id)).length}</b></button><button class="icon-button group-edit" data-edit-group="${group.id}" aria-label="重命名${escapeHTML(group.name)}" title="重命名分组">${icon('edit')}</button></div>`).join('');
  $$('.library-nav .nav-item').forEach(button => {
    button.classList.toggle('active', button.dataset.view === state.view);
    if (button.dataset.view === state.view) button.setAttribute('aria-current', 'page');
    else button.removeAttribute('aria-current');
  });
  $('#view-title').textContent = state.view === 'all' ? '全部记录' : state.view === 'pinned' ? '置顶' : state.view === 'ungrouped' ? '未分组' : groups.find(group => group.id === state.view)?.name || '全部记录';
  $('#view-description').textContent = state.view === 'pinned' ? '重要的内容，始终触手可及。' : state.view === 'ungrouped' ? '还没找到归属的内容，也不会被忘记。' : state.view === 'all' ? '好内容，复制一次就够了。' : '让相关的内容，自然聚在一起。';
}

function cardMarkup(entry) {
  let content = `<h3 class="card-title">${escapeHTML(entry.title)}</h3><div class="card-excerpt ${entry.code ? 'code' : ''}">${escapeHTML(entry.excerpt)}</div>`;
  if (entry.type === 'image') content = '<div class="card-thumb landscape"><span class="thumbnail-note">示意图片</span></div>';
  if (entry.type === 'file') content = `<div class="file-mini"><span>${icon('file')}</span><div><strong>${escapeHTML(entry.title)}</strong><p class="${entry.invalid ? 'invalid-badge' : ''}">${escapeHTML(entry.excerpt)}</p></div></div>`;
  return `<button class="history-card ${entry.id === state.selected ? 'selected' : ''}" data-entry="${entry.id}" aria-pressed="${entry.id === state.selected}" aria-label="${escapeHTML(entry.title)}${entry.pinned ? '，已置顶' : ''}"><div class="card-top">${icon(entry.type)}<span class="card-type">${typeLabels[entry.type]}</span>${entry.pinned ? `<span class="pin-marker">${icon('pin')}</span>` : ''}</div>${content}<div class="card-bottom"><span class="source-icon">${entry.sourceMark}</span><span>${entry.source}</span><time>${entry.time}</time></div></button>`;
}

function emptyMarkup(title, description) {
  return `<div class="empty-state">${icon('inbox')}<h3>${escapeHTML(title)}</h3><p>${escapeHTML(description)}</p></div>`;
}

function renderHistory() {
  const visible = visibleEntries();
  if (!visible.some(entry => entry.id === state.selected)) state.selected = visible[0]?.id || null;
  $('#result-count').textContent = `${visible.length} 条内容`;
  $('#type-filters').innerHTML = Object.entries(typeLabels).map(([type, label]) => `<button class="filter-button ${state.type === type ? 'active' : ''}" data-type="${type}" aria-pressed="${state.type === type}">${label}</button>`).join('');
  if (!visible.length) {
    $('#history-content').innerHTML = emptyMarkup(state.query ? '没有找到相关内容' : '这里还没有内容', state.query ? '试试其他关键词，或切换内容类型。' : '加入内容后，就会出现在这里。');
    renderDetail();
    return;
  }
  const sections = [
    ['置顶', visible.filter(entry => entry.pinned), true],
    ['今天', visible.filter(entry => !entry.pinned && entry.period === '今天'), false],
    ['昨天', visible.filter(entry => !entry.pinned && entry.period === '昨天'), false],
  ];
  $('#history-content').innerHTML = sections.filter(([, items]) => items.length).map(([title, items, pinned]) => `<div class="section-heading">${pinned ? icon('pin') : ''}<span>${title}</span><span>· ${items.length}</span><span class="section-line"></span></div><div class="card-grid">${items.map(cardMarkup).join('')}</div>`).join('');
  renderDetail();
}

function renderDetail() {
  const entry = selectedEntry();
  const detail = $('#detail-content');
  if (!entry) { detail.innerHTML = emptyMarkup('选择一条内容', '内容预览和操作会显示在这里。'); return; }
  let preview = `<div class="content-preview ${entry.code ? 'code' : ''}">${escapeHTML(entry.body)}</div>`;
  if (entry.type === 'image') preview = '<div class="detail-landscape landscape"><span class="thumbnail-note">CSS 绘制 · 非真实截图</span></div><p class="detail-note">2560 × 1600 · PNG（演示元数据）</p>';
  if (entry.type === 'file') preview += `<p class="detail-note ${entry.invalid ? 'invalid-badge' : ''}">${entry.invalid ? '文件不可访问，无法再次复制。正式版需重新授权或定位原文件。' : '仅保存文件引用，不备份文件本体。原文件移动、删除或权限失效后，可能无法再次复制。'}</p>`;
  detail.innerHTML = `<div class="detail-type">${icon(entry.type)}<span>${typeLabels[entry.type]}</span>${entry.pinned ? `<span style="margin-left:auto">${icon('pin')} 已置顶</span>` : ''}</div><h2 class="detail-title">${escapeHTML(entry.title)}</h2>${preview}<dl class="detail-metadata"><div class="meta-row"><dt>来源应用</dt><dd>${entry.source} <span class="muted">· 推断</span></dd></div><div class="meta-row"><dt>复制时间</dt><dd>${entry.created}</dd></div><div class="meta-row"><dt>${entry.type === 'file' ? '文件大小' : '内容大小'}</dt><dd>${entry.size}</dd></div><div class="meta-row"><dt>复制次数</dt><dd>${entry.copies} 次</dd></div></dl><section class="group-assignment" aria-label="分组归属"><div class="detail-section-label">所属分组 · 点击加入或移出</div><div class="group-tags">${groups.map(group => `<button class="group-tag ${entry.groups.includes(group.id) ? 'active' : ''}" data-toggle-group="${group.id}" aria-pressed="${entry.groups.includes(group.id)}"><span class="group-dot" style="--group-color:${group.color}"></span>${escapeHTML(group.name)}${entry.groups.includes(group.id) ? icon('check') : icon('plus')}</button>`).join('')}</div></section><div class="inspector-spacer"></div><div class="detail-toolbar"><button class="secondary-button" id="toggle-pin" aria-pressed="${entry.pinned}">${icon('pin')}${entry.pinned ? '取消置顶' : '置顶内容'}</button><button class="icon-button" id="delete-entry" aria-label="删除此条记录" title="删除此条记录">${icon('trash')}</button></div><button class="primary-button copy-primary" id="copy-entry" ${entry.invalid ? 'disabled' : ''}>${icon('copy')}模拟复制内容<kbd>↵</kbd></button><p class="copy-caption">原型不写入系统剪贴板</p>`;
}

function render() { renderNavigation(); renderHistory(); }

/** 保持复制反馈与真实能力一致：只更新演示计数，不调用系统剪贴板 API。 */
function simulateCopy(entry) {
  if (!entry || entry.invalid) { showToast('文件引用已失效，无法模拟复制'); return; }
  entry.copies += 1;
  showToast('已模拟复制 · 未写入系统剪贴板');
  renderDetail();
}

function openQuick() {
  $('#quick-search').value = '';
  state.quickSelected = selectedEntry()?.id || entries[0]?.id || null;
  renderQuick();
  $('#quick-dialog').showModal();
  $('#quick-search').focus();
}

function quickEntries() {
  const query = $('#quick-search').value.trim().toLocaleLowerCase();
  return entries.filter(entry => `${entry.title} ${entry.body}`.toLocaleLowerCase().includes(query)).slice(0, 8);
}

function renderQuick() {
  const items = quickEntries();
  if (!items.some(entry => entry.id === state.quickSelected)) state.quickSelected = items[0]?.id || null;
  $('#quick-results').innerHTML = items.length ? items.map(entry => `<button class="quick-item ${entry.id === state.quickSelected ? 'selected' : ''}" data-quick-entry="${entry.id}" aria-pressed="${entry.id === state.quickSelected}"><span class="quick-type">${icon(entry.type)}</span><span class="quick-item-body"><strong>${escapeHTML(entry.title)}</strong><small>${entry.invalid ? '文件引用已失效' : `${entry.source} · ${entry.time} · ${typeLabels[entry.type]}`}</small></span>${entry.id === state.quickSelected ? '<kbd>↵</kbd>' : ''}</button>`).join('') : emptyMarkup('没有找到相关内容', '试试其他关键词。');
}

function setTheme(theme) {
  $('#appearance').value = theme;
  const dark = theme === 'system' ? matchMedia('(prefers-color-scheme: dark)').matches : theme === 'dark';
  document.documentElement.dataset.theme = dark ? 'dark' : 'light';
  $('#theme-toggle').innerHTML = icon(dark ? 'sun' : 'moon');
  $('#theme-toggle').setAttribute('aria-label', dark ? '切换浅色模式' : '切换深色模式');
}

function openGroup(groupId = null) {
  state.editingGroup = groupId;
  $('#group-dialog-title').textContent = groupId ? '重命名分组' : '新建分组';
  $('#group-name').value = groups.find(group => group.id === groupId)?.name || '';
  $('#group-error').textContent = '最多 20 个字符，名称不可重复。';
  $('#group-dialog').showModal();
  $('#group-name').focus();
}

function requestConfirmation(title, description, action) {
  $('#confirm-title').textContent = title;
  $('#confirm-description').textContent = description;
  confirmAction = action;
  $('#confirm-dialog').showModal();
}

// 事件委托避免重绘列表后重复绑定；动态数据在插入标记前统一转义。
document.addEventListener('click', event => {
  const button = event.target.closest('button');
  if (!button) return;
  if (button.dataset.close) { document.getElementById(button.dataset.close).close(); return; }
  if (button.dataset.view) { state.view = button.dataset.view; render(); return; }
  if (button.dataset.type) { state.type = button.dataset.type; renderHistory(); return; }
  // 点击选择时保留原节点，避免重建 DOM 打断浏览器的双击事件识别。
  if (button.dataset.entry) {
    state.selected = button.dataset.entry;
    $$('[data-entry]').forEach(card => {
      const selected = card.dataset.entry === state.selected;
      card.classList.toggle('selected', selected);
      card.setAttribute('aria-pressed', String(selected));
    });
    renderDetail();
    return;
  }
  if (button.dataset.quickEntry) {
    state.quickSelected = button.dataset.quickEntry;
    $$('[data-quick-entry]').forEach(card => {
      const selected = card.dataset.quickEntry === state.quickSelected;
      card.classList.toggle('selected', selected);
      card.setAttribute('aria-pressed', String(selected));
      card.querySelector('kbd')?.remove();
      if (selected) card.insertAdjacentHTML('beforeend', '<kbd>↵</kbd>');
    });
    return;
  }
  if (button.dataset.editGroup) { openGroup(button.dataset.editGroup); return; }
  if (button.dataset.toggleGroup) {
    const entry = selectedEntry();
    if (!entry) return;
    const id = button.dataset.toggleGroup;
    entry.groups = entry.groups.includes(id) ? entry.groups.filter(group => group !== id) : [...entry.groups, id];
    render();
    return;
  }
  if (button.matches('.switch')) { button.setAttribute('aria-checked', String(button.getAttribute('aria-checked') !== 'true')); return; }
  if (button.dataset.settings) {
    $$('.settings-tabs button').forEach(tab => { const active = tab === button; tab.setAttribute('aria-selected', String(active)); tab.tabIndex = active ? 0 : -1; });
    $$('.settings-panel').forEach(panel => { panel.hidden = panel.id !== `settings-${button.dataset.settings}`; });
    return;
  }
  switch (button.id) {
    case 'show-quick': openQuick(); break;
    case 'theme-toggle': setTheme(document.documentElement.dataset.theme === 'dark' ? 'light' : 'dark'); break;
    case 'show-settings': $('#settings-dialog').showModal(); break;
    case 'open-view-help': $('#help-dialog').showModal(); break;
    case 'add-group': openGroup(); break;
    case 'pause-recording':
      state.paused = !state.paused;
      button.classList.toggle('paused', state.paused);
      button.setAttribute('aria-pressed', String(state.paused));
      button.querySelector('span').textContent = state.paused ? '记录已暂停' : '正在记录';
      showToast(state.paused ? '演示：记录已暂停' : '演示：记录已恢复');
      break;
    case 'toggle-pin': {
      const entry = selectedEntry();
      if (entry) { entry.pinned = !entry.pinned; render(); }
      break;
    }
    case 'copy-entry': simulateCopy(selectedEntry()); break;
    case 'delete-entry': {
      const id = state.selected;
      requestConfirmation('删除这条记录？', '将移除内容及其分组关联，仅影响本次演示，不会删除原文件。', () => {
        entries = entries.filter(entry => entry.id !== id);
        render();
        showToast('演示记录已删除，刷新页面可恢复');
      });
      break;
    }
    case 'clear-history':
      requestConfirmation('清空全部演示记录？', '包含置顶和已分组记录。分组本身保留，原始文件不受影响，刷新页面可恢复。', () => {
        entries = [];
        render();
        showToast('全部演示记录已清空');
      });
      break;
    case 'confirm-action': {
      const action = confirmAction;
      confirmAction = null;
      $('#confirm-dialog').close();
      action?.();
      break;
    }
    default: break;
  }
});

document.addEventListener('dblclick', event => {
  const card = event.target.closest('[data-entry], [data-quick-entry]');
  if (!card) return;
  simulateCopy(entries.find(entry => entry.id === (card.dataset.entry || card.dataset.quickEntry)));
});

$('#history-search').addEventListener('input', event => { state.query = event.target.value; renderHistory(); });
$('#quick-search').addEventListener('input', renderQuick);
$('#appearance').addEventListener('change', event => setTheme(event.target.value));
matchMedia('(prefers-color-scheme: dark)').addEventListener('change', () => { if ($('#appearance').value === 'system') setTheme('system'); });
$('#group-form').addEventListener('submit', event => {
  event.preventDefault();
  const name = $('#group-name').value.trim();
  if (!name || groups.some(group => group.id !== state.editingGroup && group.name.toLocaleLowerCase() === name.toLocaleLowerCase())) {
    $('#group-error').textContent = '请输入非空且不重复的分组名称。';
    $('#group-name').focus();
    return;
  }
  if (state.editingGroup) groups.find(group => group.id === state.editingGroup).name = name;
  else groups.push({ id: `group-${Date.now()}`, name, color: '#9a9381' });
  $('#group-dialog').close();
  render();
  showToast('分组已保存，仅在本次演示中有效');
});

/** 键盘操作限定在当前 UI 范围；浏览器页面无法注册系统级全局快捷键。 */
document.addEventListener('keydown', event => {
  const dialog = [...$$('dialog[open]')].pop();
  const typing = event.target.matches('input, textarea, select, [contenteditable="true"]');
  if ((event.metaKey || event.ctrlKey) && event.key.toLowerCase() === 'k' && !dialog) { event.preventDefault(); $('#history-search').focus(); return; }
  if (event.metaKey && event.key === ',' && !dialog) { event.preventDefault(); $('#settings-dialog').showModal(); return; }
  if (event.altKey && event.code === 'Space' && !dialog && !typing) { event.preventDefault(); openQuick(); return; }
  if (dialog && dialog.id !== 'quick-dialog') {
    if (event.target.matches('[role="tab"]') && ['ArrowLeft', 'ArrowRight'].includes(event.key)) {
      event.preventDefault();
      const tabs = $$('.settings-tabs button');
      const index = (tabs.indexOf(event.target) + (event.key === 'ArrowRight' ? 1 : -1) + tabs.length) % tabs.length;
      tabs[index].click(); tabs[index].focus();
    }
    return;
  }
  if (['ArrowDown', 'ArrowUp'].includes(event.key)) {
    if (typing && event.target.id !== 'quick-search' && event.target.id !== 'history-search') return;
    if (!dialog && !typing && !event.target.closest('.history-scroll') && event.target !== document.body) return;
    event.preventDefault();
    const items = dialog ? quickEntries() : visibleEntries();
    if (!items.length) return;
    const key = dialog ? 'quickSelected' : 'selected';
    const current = items.findIndex(entry => entry.id === state[key]);
    const index = Math.max(0, Math.min(items.length - 1, current + (event.key === 'ArrowDown' ? 1 : -1)));
    state[key] = items[index].id;
    if (dialog) renderQuick(); else renderHistory();
    const target = $(`[${dialog ? 'data-quick-entry' : 'data-entry'}="${state[key]}"]`);
    target?.scrollIntoView({ block: 'nearest' });
    if (!typing) target?.focus({ preventScroll: true });
    return;
  }
  if (event.key === 'Enter') {
    const isSearch = ['quick-search', 'history-search'].includes(event.target.id);
    const isCard = event.target.closest('[data-entry], [data-quick-entry]');
    if (!isSearch && !isCard && event.target !== document.body) return;
    event.preventDefault();
    simulateCopy(dialog ? entries.find(entry => entry.id === state.quickSelected) : selectedEntry());
  }
});

$$('[data-icon]').forEach(element => { element.innerHTML = icon(element.dataset.icon); });
setTheme('system');
render();
