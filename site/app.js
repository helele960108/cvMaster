"use strict";

const ITEMS = [
  { id: 1, type: "text", group: "work", pinned: true,
    text: { zh: "周五前把发布说明发给团队，附上已知问题列表。", en: "Send the release notes to the team by Friday, with the known-issues list." },
    app: { zh: "备忘录", en: "Notes" }, time: { zh: "2 分钟前", en: "2 min ago" } },
  { id: 2, type: "link", group: "work", pinned: false,
    text: { zh: "https://github.com/helele960108/cvMaster", en: "https://github.com/helele960108/cvMaster" },
    app: { zh: "Safari", en: "Safari" }, time: { zh: "18 分钟前", en: "18 min ago" } },
  { id: 3, type: "image", group: "design", pinned: false,
    text: { zh: "截图 2026-11-12 15.03.41.png", en: "Screenshot 2026-11-12 at 15.03.41.png" },
    app: { zh: "截图", en: "Screenshot" }, time: { zh: "1 小时前", en: "1 hr ago" } },
  { id: 4, type: "file", group: "work", pinned: false,
    text: { zh: "季度汇报.key", en: "Quarterly review.key" },
    app: { zh: "访达", en: "Finder" }, time: { zh: "昨天", en: "Yesterday" } },
  { id: 5, type: "text", group: "design", pinned: false,
    text: { zh: "标题字号 30，正文 16，行高 1.6，卡片间距 9。", en: "Heading 30, body 16, line height 1.6, card gap 9." },
    app: { zh: "Figma", en: "Figma" }, time: { zh: "昨天", en: "Yesterday" } },
  { id: 6, type: "text", group: "work", pinned: false,
    text: { zh: "git log --oneline --since=\"1 week ago\"", en: "git log --oneline --since=\"1 week ago\"" },
    app: { zh: "终端", en: "Terminal" }, time: { zh: "周一", en: "Monday" } }
];

const PRIVACY = "https://github.com/helele960108/cvMaster/blob/main/docs/隐私与数据说明.md";
const REPO = "https://github.com/helele960108/cvMaster";

const T = {
  zh: {
    "hero.title": "剪贴板历史，<br>不离开这台电脑。",
    "hero.lede": "macOS 与 Windows 上的原生剪贴板工具。应用不联网，不需要账号，默认不记录。",
    "hero.cta": "在 GitHub 查看源码",
    "hero.status": `0.1.0 预览版：<a href="${REPO}/releases">下载 macOS 预览包</a>（Apple Silicon，未经公证）；Windows 需<a href="${REPO}#快速开始">从源码构建</a>。`,
    "demo.local": "仅本机", "demo.search": "搜索", "demo.count": n => `${n} 条记录`,
    "demo.caption": "示意浮层，可点击或用 ↑ ↓ 回车操作。网页不会读取你的剪贴板。",
    "demo.groups": ["全部", "置顶", "工作", "设计"],
    "demo.typeNames": { text: "文本", link: "链接", image: "图片", file: "文件" },
    "demo.pinned": "置顶", "demo.empty": "没有匹配的记录", "demo.pasted": "已粘贴",
    "p.title": "四条承诺",
    "p.net": "不联网",
    "p.netd": "应用不发起网络请求。没有账号、云同步、遥测、广告或崩溃上传，代码里没有 HTTP 客户端和 WebView。",
    "p.local": "只存在本机",
    "p.locald": "历史、设置和原始内容都在本机用户目录。macOS 版把数据目录权限收紧为仅自己可读写。",
    "p.off": "默认不记录",
    "p.offd": "由你手动开启，只记录开启后的新复制。锁屏、睡眠和安全输入期间自动跳过。",
    "p.safe": "避开敏感内容",
    "p.safed": "识别剪贴板的隐私标记，默认排除常见密码管理器。剪贴板内容不进日志，HTML 不渲染。",
    "p.limits": `限制也写在这里：没有应用级静态加密；不是所有密码管理器都会设置隐私标记；检查文件引用时，系统可能访问你复制的云盘或网络共享路径。完整说明见<a href="${PRIVACY}">隐私与数据说明</a>。`,
    "foot.platforms": "macOS 26.5+（Apple Silicon，SwiftUI）与 Windows 10/11（.NET 10，WPF），两端都是原生应用。",
    "foot.license": `以 <a href="${REPO}/blob/main/LICENSE">Apache License 2.0</a> 开源。安全问题请按 <a href="${REPO}/blob/main/SECURITY.md">SECURITY.md</a> 私下报告。`
  },
  en: {
    "hero.title": "Clipboard history<br>that never leaves your computer.",
    "hero.lede": "A native clipboard manager for macOS and Windows. It makes no network requests, needs no account, and records nothing until you turn it on.",
    "hero.cta": "Source on GitHub",
    "hero.status": `0.1.0 preview: <a href="${REPO}/releases">download the macOS build</a> (Apple Silicon, not notarized). Windows: <a href="${REPO}#快速开始">build from source</a>.`,
    "demo.local": "Local only", "demo.search": "Search", "demo.count": n => `${n} items`,
    "demo.caption": "A mock panel you can click, or drive with ↑ ↓ and Return. This page never reads your clipboard.",
    "demo.groups": ["All", "Pinned", "Work", "Design"],
    "demo.typeNames": { text: "Text", link: "Link", image: "Image", file: "File" },
    "demo.pinned": "Pinned", "demo.empty": "No matches", "demo.pasted": "Pasted",
    "p.title": "Four promises",
    "p.net": "No network",
    "p.netd": "The app makes no network requests. No account, cloud sync, telemetry, ads or crash uploads, and no HTTP client or WebView in the code.",
    "p.local": "Stored on your machine",
    "p.locald": "History, settings and raw content stay in your local user directory. On macOS the data directory is restricted to your user only.",
    "p.off": "Off by default",
    "p.offd": "You turn recording on, and only copies made after that are kept. Nothing is recorded while the screen is locked, the computer is asleep, or secure input is on.",
    "p.safe": "Steers clear of secrets",
    "p.safed": "Honors the clipboard privacy flag and excludes common password managers by default. Clipboard contents never go into logs, and HTML is never rendered.",
    "p.limits": `The limits, too: there is no app-level encryption at rest; not every password manager sets the privacy flag; checking a copied file reference may make the system reach a cloud drive or network share. Details in the <a href="${PRIVACY}">privacy notes</a>.`,
    "foot.platforms": "macOS 26.5+ (Apple Silicon, SwiftUI) and Windows 10/11 (.NET 10, WPF). Both are native apps.",
    "foot.license": `Open source under the <a href="${REPO}/blob/main/LICENSE">Apache License 2.0</a>. Report security issues privately as described in <a href="${REPO}/blob/main/SECURITY.md">SECURITY.md</a>.`
  }
};

const GROUP_KEYS = ["all", "pinned", "work", "design"];

let lang = localStorage.getItem("cv-lang") || ((navigator.language || "").toLowerCase().startsWith("zh") ? "zh" : "en");
let group = "all";
let query = "";
let selected = 0;

function t(key) { return T[lang][key]; }

function esc(value) {
  return value.replace(/[&<>"]/g, c => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" })[c]);
}

function applyLang() {
  document.documentElement.lang = lang === "zh" ? "zh-CN" : "en";
  document.title = lang === "zh" ? "cvMaster：本地优先的剪贴板管理工具" : "cvMaster: a local-first clipboard manager";
  document.querySelector('meta[name="description"]').content = lang === "zh"
    ? "cvMaster 是 macOS 与 Windows 上的原生剪贴板管理工具。历史只保存在本机，应用不发起网络请求，没有账号、云同步和遥测。"
    : "cvMaster is a native clipboard manager for macOS and Windows. History stays on your machine, the app makes no network requests, and there is no account, cloud sync or telemetry.";
  document.querySelectorAll("[data-i18n]").forEach(el => { el.textContent = t(el.dataset.i18n); });
  document.querySelectorAll("[data-i18n-html]").forEach(el => { el.innerHTML = t(el.dataset.i18nHtml); });
  document.querySelectorAll("[data-i18n-placeholder]").forEach(el => { el.placeholder = t(el.dataset.i18nPlaceholder); });
  const toggle = document.getElementById("lang-toggle");
  toggle.textContent = lang === "zh" ? "English" : "中文";
  toggle.lang = lang === "zh" ? "en" : "zh-CN";
  renderFilters();
  renderList();
}

function renderFilters() {
  document.getElementById("demo-groups").innerHTML = GROUP_KEYS.map((key, i) =>
    `<button class="chip" role="tab" aria-selected="${key === group}" data-group="${key}">${t("demo.groups")[i]}</button>`).join("");
}

function visible() {
  const q = query.trim().toLowerCase();
  return ITEMS.filter(item => {
    if (group === "pinned" && !item.pinned) return false;
    if (group === "work" || group === "design") { if (item.group !== group) return false; }
    if (q && item.type === "image") return false;
    if (q && !item.text[lang].toLowerCase().includes(q)) return false;
    return true;
  });
}

function renderList() {
  const items = visible();
  if (selected >= items.length) selected = Math.max(0, items.length - 1);
  const list = document.getElementById("demo-list");
  if (!items.length) {
    list.innerHTML = `<li class="empty">${t("demo.empty")}</li>`;
  } else {
    list.innerHTML = items.map((item, i) => {
      const body = item.type === "image" ? `<div class="thumb"></div><div class="text">${esc(item.text[lang])}</div>` : `<div class="text">${esc(item.text[lang])}</div>`;
      const pin = item.pinned ? `<span class="pin">${t("demo.pinned")}</span>` : "";
      return `<li role="option" aria-selected="${i === selected}"><button class="row" data-index="${i}" aria-selected="${i === selected}">${body}<div class="meta">${pin}<span>${t("demo.typeNames")[item.type]}</span><span>${item.app[lang]}</span><span>${item.time[lang]}</span></div></button></li>`;
    }).join("");
  }
  document.getElementById("demo-feedback").textContent = items.length ? t("demo.count")(items.length) : "";
}

document.getElementById("lang-toggle").addEventListener("click", () => {
  lang = lang === "zh" ? "en" : "zh";
  localStorage.setItem("cv-lang", lang);
  applyLang();
});

document.getElementById("demo-groups").addEventListener("click", e => {
  const key = e.target.dataset.group;
  if (!key) return;
  group = key;
  selected = 0;
  renderFilters();
  renderList();
});
document.getElementById("demo-search").addEventListener("input", e => {
  query = e.target.value;
  selected = 0;
  renderList();
});
document.getElementById("demo-list").addEventListener("click", e => {
  const row = e.target.closest(".row");
  if (!row) return;
  selected = Number(row.dataset.index);
  renderList();
});
document.getElementById("demo-list").addEventListener("dblclick", e => {
  if (e.target.closest(".row")) paste();
});
document.getElementById("demo-list").addEventListener("keydown", e => {
  const items = visible();
  if (e.key === "ArrowDown") { selected = Math.min(items.length - 1, selected + 1); renderList(); e.preventDefault(); }
  if (e.key === "ArrowUp") { selected = Math.max(0, selected - 1); renderList(); e.preventDefault(); }
  if (e.key === "Enter") { paste(); e.preventDefault(); }
});

function paste() {
  if (!visible().length) return;
  document.getElementById("demo-feedback").textContent = t("demo.pasted");
}

applyLang();
