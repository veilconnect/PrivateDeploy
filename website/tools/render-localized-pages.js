const fs = require("fs");
const path = require("path");
const { execFileSync } = require("child_process");

const repoRoot = path.resolve(__dirname, "..", "..");
// PD_WEBSITE_DIR is a test hook: it lets the test suite run --check /
// --update-release against a throwaway copy of the site instead of the
// real one. Production use always operates on <repo>/website.
const websiteDir = process.env.PD_WEBSITE_DIR
  ? path.resolve(process.env.PD_WEBSITE_DIR)
  : path.join(repoRoot, "website");
const manifestPath = path.join(websiteDir, "tools", "release-manifest.json");

const domain = "https://privatedeploy.org";
const repoUrl = "https://github.com/veilconnect/PrivateDeploy";

// ── Release manifest: the single source of truth ───────────────────
//
// website/tools/release-manifest.json holds the published release version,
// its date and, for every artifact, the file name / display size / sha256.
// All three code paths (full render from translations, --update-release,
// --check) read it. Nothing about the published release is hardcoded here.
// A future stable tag must not pre-commit hashes for artifacts that have not
// been signed yet. The tag workflow builds first, then runs --update-release
// against an isolated website copy and uploads that exact deployable handoff.
//
// Only stable X.Y.Z versions are accepted — the release workflow's tag gate
// rejects prerelease tags (-rc/-beta/…) and this generator matches it.

const STABLE_VERSION_RE = /^\d+\.\d+\.\d+$/;
const ISO_DATE_RE = /^\d{4}-\d{2}-\d{2}$/;
const SHA256_RE = /^[0-9a-f]{64}$/;
const ARTIFACT_NAME_RE = /^[A-Za-z0-9][A-Za-z0-9._-]*$/;
const PLATFORMS = ["windows", "macos", "linux"];

function validateManifest(m) {
  if (!m || typeof m !== "object") throw new Error("manifest: not an object");
  if (typeof m.version !== "string" || !STABLE_VERSION_RE.test(m.version)) {
    throw new Error(`manifest: version must be a stable X.Y.Z version, got "${m.version}"`);
  }
  if (typeof m.date !== "string" || !ISO_DATE_RE.test(m.date)) {
    throw new Error(`manifest: date must be YYYY-MM-DD, got "${m.date}"`);
  }
  const parsedDate = parseIsoDate(m.date, "manifest date");
  const date = new Date(Date.UTC(parsedDate.y, parsedDate.m - 1, parsedDate.d));
  if (date.getUTCFullYear() !== parsedDate.y || date.getUTCMonth() + 1 !== parsedDate.m || date.getUTCDate() !== parsedDate.d) {
    throw new Error(`manifest: date is not a real calendar date: "${m.date}"`);
  }
  if (!Array.isArray(m.artifacts) || m.artifacts.length === 0) {
    throw new Error("manifest: artifacts must be a non-empty array");
  }
  const seen = new Set();
  for (const a of m.artifacts) {
    if (!a || typeof a !== "object") throw new Error("manifest: artifact entries must be objects");
    if (typeof a.name !== "string" || !ARTIFACT_NAME_RE.test(a.name)) {
      throw new Error(`manifest: bad artifact name "${a.name}"`);
    }
    if (seen.has(a.name)) throw new Error(`manifest: duplicate artifact "${a.name}"`);
    seen.add(a.name);
    if (!PLATFORMS.includes(a.platform)) {
      throw new Error(`manifest: artifact "${a.name}" has unknown platform "${a.platform}"`);
    }
    if (typeof a.size !== "string" || !a.size.trim()) {
      throw new Error(`manifest: artifact "${a.name}" is missing a display size`);
    }
    if (typeof a.sha256 !== "string" || !SHA256_RE.test(a.sha256)) {
      throw new Error(`manifest: artifact "${a.name}" has an invalid sha256 "${a.sha256}"`);
    }
  }
  return m;
}

function loadManifest() {
  return validateManifest(JSON.parse(fs.readFileSync(manifestPath, "utf8")));
}

// Parses + validates a `sha256sum`-style checksums file (as produced by the
// release workflow). Every line must be `<64-hex>  <name>`, every name must
// belong to `allowedNames` (the manifest artifact set), no duplicates, and
// the file must cover the full artifact set. Returns Map<name, sha256>.
function parseChecksumsFile(text, allowedNames) {
  const out = new Map();
  const lines = text.split("\n").map((l) => l.trim()).filter(Boolean);
  for (const line of lines) {
    const m = /^([0-9a-fA-F]{64})[ \t]+\*?([^\s]+)$/.exec(line);
    if (!m) throw new Error(`checksums file: malformed line (need "<64-hex-sha256>  <file>"): "${line}"`);
    const [, hash, name] = m;
    if (!allowedNames.has(name)) {
      throw new Error(`checksums file: "${name}" is not an allowed release artifact (allowed: ${[...allowedNames].sort().join(", ")})`);
    }
    if (out.has(name)) throw new Error(`checksums file: duplicate entry for "${name}"`);
    out.set(name, hash.toLowerCase());
  }
  const missing = [...allowedNames].filter((n) => !out.has(n)).sort();
  if (missing.length) throw new Error(`checksums file: missing entries for: ${missing.join(", ")}`);
  return out;
}

function checksumLines(manifest) {
  return manifest.artifacts
    .map((a) => `${a.sha256}  ${a.name}`)
    .sort((x, y) => (x.split("  ")[1] < y.split("  ")[1] ? -1 : 1));
}

function artifactsByPlatform(manifest) {
  const grouped = {};
  for (const p of PLATFORMS) grouped[p] = [];
  for (const a of manifest.artifacts) grouped[a.platform].push([a.name, a.size, Boolean(a.primary)]);
  return grouped;
}

function builtArtifactSizes(assetDirValue, artifactList) {
  const assetDir = path.resolve(assetDirValue);
  const found = new Map();
  const walk = (directory) => {
    for (const entry of fs.readdirSync(directory, { withFileTypes: true })) {
      const full = path.join(directory, entry.name);
      if (entry.isDirectory()) walk(full);
      else if (entry.isFile()) {
        if (!found.has(entry.name)) found.set(entry.name, []);
        found.get(entry.name).push(full);
      }
    }
  };
  walk(assetDir);
  const sizes = new Map();
  for (const artifact of artifactList) {
    const matches = found.get(artifact.name) || [];
    if (matches.length !== 1) throw new Error(`${artifact.name}: expected exactly one built file, found ${matches.length}`);
    sizes.set(artifact.name, `${(fs.statSync(matches[0]).size / (1024 * 1024)).toFixed(1)} MB`);
  }
  return sizes;
}

const manifest = loadManifest();
const release = `v${manifest.version}`;
const releaseDate = parseIsoDate(manifest.date, "manifest date");
const releaseBase = `${repoUrl}/releases/download/${release}`;
const checksums = checksumLines(manifest);
const artifacts = artifactsByPlatform(manifest);

function git(args) {
  return execFileSync("git", args, { cwd: repoRoot, encoding: "utf8" }).trim();
}

function parseIsoDate(iso, source) {
  const m = /^(\d{4})-(\d{2})-(\d{2})$/.exec(iso);
  if (!m) throw new Error(`${source} is not a YYYY-MM-DD date: "${iso}"`);
  return { y: Number(m[1]), m: Number(m[2]), d: Number(m[3]) };
}

function isoOf({ y, m, d }) {
  return `${y}-${String(m).padStart(2, "0")}-${String(d).padStart(2, "0")}`;
}

function tagDate(tag) {
  const iso = git(["log", "-1", "--format=%cs", `${tag}^{commit}`]);
  return parseIsoDate(iso, `commit date of ${tag}`);
}

// Target release for --update-release: PD_RELEASE_VERSION (stable X.Y.Z,
// with or without the leading v) or the newest stable vX.Y.Z git tag.
function resolveTargetVersion() {
  const env = (process.env.PD_RELEASE_VERSION || "").trim();
  if (env) {
    const bare = env.startsWith("v") ? env.slice(1) : env;
    if (!STABLE_VERSION_RE.test(bare)) {
      throw new Error(`PD_RELEASE_VERSION must be a stable X.Y.Z version (prereleases are not released): "${env}"`);
    }
    return bare;
  }
  const tags = git(["tag", "--sort=-v:refname"]).split("\n");
  const stable = tags.map((t) => t.trim()).find((t) => /^v\d+\.\d+\.\d+$/.test(t));
  if (!stable) {
    throw new Error("No stable vX.Y.Z tag found and PD_RELEASE_VERSION is not set");
  }
  return stable.slice(1);
}

function resolveTargetDate(version) {
  const env = (process.env.PD_RELEASE_DATE || "").trim();
  if (env) return parseIsoDate(env, "PD_RELEASE_DATE");
  return tagDate(`v${version}`);
}

const languages = [
  { key: "en", hreflang: "en", htmlLang: "en", dir: "ltr", prefix: "" },
  { key: "zh", hreflang: "zh-CN", htmlLang: "zh-CN", dir: "ltr", prefix: "zh" },
  { key: "es", hreflang: "es", htmlLang: "es", dir: "ltr", prefix: "es" },
  { key: "fr", hreflang: "fr", htmlLang: "fr", dir: "ltr", prefix: "fr" },
  { key: "de", hreflang: "de", htmlLang: "de", dir: "ltr", prefix: "de" },
  { key: "ja", hreflang: "ja", htmlLang: "ja", dir: "ltr", prefix: "ja" },
  { key: "ko", hreflang: "ko", htmlLang: "ko", dir: "ltr", prefix: "ko" },
  { key: "pt", hreflang: "pt", htmlLang: "pt", dir: "ltr", prefix: "pt" },
  { key: "ru", hreflang: "ru", htmlLang: "ru", dir: "ltr", prefix: "ru" },
  { key: "ar", hreflang: "ar", htmlLang: "ar", dir: "rtl", prefix: "ar" },
  { key: "hi", hreflang: "hi", htmlLang: "hi", dir: "ltr", prefix: "hi" },
  { key: "id", hreflang: "id", htmlLang: "id", dir: "ltr", prefix: "id" },
];

// Localized "long date" renderings that mirror exactly how the shipped
// translations write dates on the download pages. Used by --update-release
// to swap the previous release date for the new one and by --check to
// assert the manifest date is what each page shows.
const monthNames = {
  en: ["January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December"],
  es: ["enero", "febrero", "marzo", "abril", "mayo", "junio", "julio", "agosto", "septiembre", "octubre", "noviembre", "diciembre"],
  fr: ["janvier", "février", "mars", "avril", "mai", "juin", "juillet", "août", "septembre", "octobre", "novembre", "décembre"],
  de: ["Januar", "Februar", "März", "April", "Mai", "Juni", "Juli", "August", "September", "Oktober", "November", "Dezember"],
  pt: ["janeiro", "fevereiro", "março", "abril", "maio", "junho", "julho", "agosto", "setembro", "outubro", "novembro", "dezembro"],
  ru: ["января", "февраля", "марта", "апреля", "мая", "июня", "июля", "августа", "сентября", "октября", "ноября", "декабря"],
  ar: ["يناير", "فبراير", "مارس", "أبريل", "مايو", "يونيو", "يوليو", "أغسطس", "سبتمبر", "أكتوبر", "نوفمبر", "ديسمبر"],
  hi: ["जनवरी", "फ़रवरी", "मार्च", "अप्रैल", "मई", "जून", "जुलाई", "अगस्त", "सितंबर", "अक्टूबर", "नवंबर", "दिसंबर"],
  id: ["Januari", "Februari", "Maret", "April", "Mei", "Juni", "Juli", "Agustus", "September", "Oktober", "November", "Desember"],
};

const dateFormats = {
  en: ({ y, m, d }) => `${monthNames.en[m - 1]} ${d}, ${y}`,
  zh: ({ y, m, d }) => `${y} 年 ${m} 月 ${d} 日`,
  ja: ({ y, m, d }) => `${y} 年 ${m} 月 ${d} 日`,
  ko: ({ y, m, d }) => `${y}년 ${m}월 ${d}일`,
  es: ({ y, m, d }) => `${d} de ${monthNames.es[m - 1]} de ${y}`,
  fr: ({ y, m, d }) => `${d} ${monthNames.fr[m - 1]} ${y}`,
  de: ({ y, m, d }) => `${d}. ${monthNames.de[m - 1]} ${y}`,
  pt: ({ y, m, d }) => `${d} de ${monthNames.pt[m - 1]} de ${y}`,
  ru: ({ y, m, d }) => `${d} ${monthNames.ru[m - 1]} ${y} года`,
  ar: ({ y, m, d }) => `${d} ${monthNames.ar[m - 1]} ${y}`,
  hi: ({ y, m, d }) => `${d} ${monthNames.hi[m - 1]} ${y}`,
  id: ({ y, m, d }) => `${d} ${monthNames.id[m - 1]} ${y}`,
};

const menuLanguages = [
  ["en", "English", "EN"],
  ["zh-CN", "中文", "ZH"],
  ["es", "Español", "ES"],
  ["fr", "Français", "FR"],
  ["de", "Deutsch", "DE"],
  ["ja", "日本語", "JA"],
  ["ko", "한국어", "KO"],
  ["pt", "Português", "PT"],
  ["ru", "Русский", "RU"],
  ["ar", "العربية", "AR"],
  ["hi", "हिन्दी", "HI"],
  ["id", "Bahasa Indonesia", "ID"],
];

function esc(value) {
  return String(value)
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")
    .replace(/\n/g, "&#10;");
}

function route(lang, section = "") {
  const parts = [lang.prefix, section].filter(Boolean);
  return `/${parts.join("/")}${parts.length ? "/" : ""}`;
}

function canonical(lang, section) {
  return `${domain}${route(lang, section)}`;
}

function alternates(section) {
  const rows = languages.map(
    (lang) => `    <link rel="alternate" hreflang="${lang.hreflang}" href="${canonical(lang, section)}">`,
  );
  rows.push(`    <link rel="alternate" hreflang="x-default" href="${canonical(languages[0], section)}">`);
  return rows.join("\n");
}

function languageMenu(section, t) {
  const links = menuLanguages
    .map(([hreflang, native, code]) => {
      const lang = languages.find((item) => item.hreflang === hreflang);
      return `              <a href="${route(lang, section)}" lang="${hreflang}"><span class="language-native">${esc(native)}</span><span class="language-code">${code}</span></a>`;
    })
    .join("\n");

  return `          <div class="language-menu" data-language-menu>
            <button class="language-toggle" type="button" aria-expanded="false" data-language-toggle>${esc(t.language)}</button>
            <div class="language-options" role="menu" aria-label="${esc(t.languageSelector)}">
${links}
            </div>
          </div>`;
}

function header(lang, t, section) {
  return `    <header class="site-header">
      <nav class="nav" aria-label="${esc(t.navLabel)}">
        <a class="brand" href="${route(lang)}"><img class="brand-logo" src="/assets/logo.svg" alt="" width="36" height="36"><span>PrivateDeploy</span></a>
        <button class="nav-toggle" type="button" aria-label="${esc(t.navToggle)}" aria-expanded="false" data-nav-toggle><span></span></button>
        <div class="nav-links" data-nav-menu>
          <a href="${route(lang)}"${section === "" ? ' aria-current="page"' : ""}>${esc(t.product)}</a>
          <a href="${route(lang, "download")}"${section === "download" ? ' aria-current="page"' : ""}>${esc(t.download)}</a>
          <a href="${route(lang, "docs")}"${section === "docs" ? ' aria-current="page"' : ""}>${esc(t.docs)}</a>
          <a href="${route(lang, "security")}"${section === "security" ? ' aria-current="page"' : ""}>${esc(t.security)}</a>
          <a href="/github">GitHub</a>
${languageMenu(section, t)}
        </div>
      </nav>
    </header>`;
}

function footer(lang, t) {
  return `    <footer class="site-footer">
      <div class="footer-inner">
        <div>PrivateDeploy</div>
        <div class="footer-links">
          <a href="${route(lang, "download")}">${esc(t.download)}</a>
          <a href="${route(lang, "docs")}">${esc(t.docs)}</a>
          <a href="${route(lang, "security")}">${esc(t.security)}</a>
          <a href="/github">GitHub</a>
        </div>
      </div>
    </footer>`;
}

function head(lang, section, title, desc) {
  return `  <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <title>${esc(title)}</title>
    <meta name="description" content="${esc(desc)}">
    <link rel="canonical" href="${canonical(lang, section)}">
${alternates(section)}
    <link rel="icon" href="/favicon.ico">
    <link rel="stylesheet" href="/assets/site-v5.css">
  </head>`;
}

function page(lang, section, title, desc, body, t) {
  const autoLanguage = lang.key === "en" ? " data-auto-language" : "";
  return `<!doctype html>
<html lang="${lang.htmlLang}" dir="${lang.dir}"${autoLanguage}>
${head(lang, section, title, desc)}
  <body>
${header(lang, t, section)}

${body}

${footer(lang, t)}
    <script src="/assets/site-v5.js"></script>
  </body>
</html>
`;
}

function artifactList(items, t) {
  return `<div class="artifact-list">
${items
  .map(
    ([name, size, primary]) => `                <div class="artifact">
                  <div><strong>${name}</strong><span>${size}</span></div>
                  <a class="button${primary ? " primary" : ""}" href="${releaseBase}/${name}">${esc(t.download)}</a>
                </div>`,
  )
  .join("\n")}
              </div>`;
}

// The release workflow does NOT build Android APKs, so the download pages
// must not deep-link (or promise checksums for) APK files. The Android card
// links to the GitHub Releases page neutrally instead. See website/README.md.
const releasePolicyCopy = {
  en: { choose: "This release publishes only the checksum-covered desktop archives listed below.", android: "Android packages are not produced by this release workflow. Build the mobile app from source.", verify: "The published checksum file covers every downloadable artifact linked on this page." },
  zh: { choose: "此版本仅发布下方列出且有校验值的桌面端压缩包。", android: "此发布流程不生成 Android 安装包；移动端需从源码构建。", verify: "已发布的校验文件覆盖本页链接的全部可下载产物。" },
  es: { choose: "Esta versión solo publica los archivos de escritorio con checksum que aparecen abajo.", android: "Este flujo de publicación no genera paquetes Android; compila la app móvil desde el código fuente.", verify: "El archivo de checksums cubre todos los artefactos descargables enlazados en esta página." },
  fr: { choose: "Cette version publie uniquement les archives desktop vérifiées ci-dessous.", android: "Ce workflow ne produit pas de paquet Android ; compilez l’application mobile depuis les sources.", verify: "Le fichier de checksums couvre tous les artefacts téléchargeables liés sur cette page." },
  de: { choose: "Dieses Release veröffentlicht nur die unten aufgeführten Desktop-Archive mit Prüfsumme.", android: "Dieser Release-Workflow erzeugt keine Android-Pakete; bauen Sie die mobile App aus dem Quellcode.", verify: "Die veröffentlichte Prüfsummendatei deckt alle auf dieser Seite verlinkten Downloads ab." },
  ja: { choose: "このリリースで公開するのは、以下のチェックサム付きデスクトップアーカイブのみです。", android: "このリリースワークフローは Android パッケージを生成しません。モバイルアプリはソースからビルドしてください。", verify: "公開済みチェックサムは、このページからリンクされる全ダウンロード成果物を対象とします。" },
  ko: { choose: "이 릴리스는 아래의 체크섬이 제공되는 데스크톱 압축 파일만 배포합니다.", android: "이 릴리스 워크플로는 Android 패키지를 만들지 않습니다. 모바일 앱은 소스에서 빌드하세요.", verify: "게시된 체크섬 파일은 이 페이지에 연결된 모든 다운로드 산출물을 포함합니다." },
  pt: { choose: "Esta versão publica somente os arquivos de desktop com checksum listados abaixo.", android: "Este fluxo de lançamento não produz pacotes Android; compile o aplicativo móvel a partir do código-fonte.", verify: "O arquivo de checksums cobre todos os artefatos para download vinculados nesta página." },
  ru: { choose: "В этом выпуске публикуются только перечисленные ниже настольные архивы с контрольными суммами.", android: "Этот процесс выпуска не создаёт пакеты Android; соберите мобильное приложение из исходного кода.", verify: "Файл контрольных сумм охватывает все загружаемые артефакты, указанные на этой странице." },
  ar: { choose: "ينشر هذا الإصدار أرشيفات سطح المكتب المغطاة بقيم التحقق أدناه فقط.", android: "لا ينشئ مسار الإصدار هذا حزم Android؛ ابنِ تطبيق الهاتف من المصدر.", verify: "يغطي ملف قيم التحقق المنشور كل الملفات القابلة للتنزيل المرتبطة في هذه الصفحة." },
  hi: { choose: "यह रिलीज़ केवल नीचे दिए checksum-सत्यापित desktop archives प्रकाशित करती है।", android: "यह release workflow Android package नहीं बनाता; mobile app को source से build करें।", verify: "प्रकाशित checksum file इस पेज पर लिंक किए गए सभी downloadable artifacts को कवर करती है।" },
  id: { choose: "Rilis ini hanya menerbitkan arsip desktop dengan checksum yang tercantum di bawah.", android: "Alur rilis ini tidak membuat paket Android; bangun aplikasi seluler dari sumber.", verify: "Berkas checksum mencakup semua artefak unduhan yang ditautkan di halaman ini." },
};

function androidUnavailableCard(lang, t) {
  return `<article class="download-card"><div><h3>Android</h3><p>${esc(releasePolicyCopy[lang.key].android)}</p></div><span class="badge warn">${esc(t.buildRequired)}</span></article>`;
}

function applyReleasePolicyCopy(html, lang, t = { buildRequired: "Build required" }) {
  const copy = releasePolicyCopy[lang.key];
  const existingBuildLabel = /<h3>iOS<\/h3>[\s\S]*?<span class="badge warn">([^<]+)<\/span>/.exec(html)?.[1];
  const effectiveT = { ...t, buildRequired: existingBuildLabel || t.buildRequired };
  html = html.replace(
    /(<div class="section-heading"><h2>[^<]+<\/h2>)<p>[\s\S]*?<\/p>(<\/div>\s*<div class="download-grid">)/,
    `$1<p>${esc(copy.choose)}</p>$2`,
  );
  html = html.replace(
    /<article class="download-card"><div><h3>Android<\/h3>[\s\S]*?<\/article>/,
    androidUnavailableCard(lang, effectiveT),
  );
  html = html.replace(
    /(<div><h2>[^<]+<\/h2>)<p class="muted">[\s\S]*?<\/p>(<\/div>\s*<div class="terminal">)/,
    `$1<p class="muted">${esc(copy.verify)}</p>$2`,
  );
  return html;
}

function copyButton(t, value) {
  return `<button class="button" type="button" data-copy="${esc(value)}" data-copied="${esc(t.copied)}" data-copy-failed="${esc(t.copyFailed)}">${esc(t.copy)}</button>`;
}

function downloadPage(lang, t) {
  // NOTE: t.downloadIntro comes from the translations JSON and embeds the
  // release version and localized release date in prose. When running a full
  // re-render, the translations you feed on stdin must already reference the
  // manifest release/date (--check verifies the result).
  const checksumCommand = `curl -L -O ${releaseBase}/checksums.sha256\nsha256sum -c checksums.sha256`;
  const body = `    <main>
      <section class="page-title">
        <div class="container">
          <p class="eyebrow"><span class="status-dot"></span> ${esc(t.dist)}</p>
          <h1>${esc(t.downloadH1)}</h1>
          <p>${esc(t.downloadIntro)}</p>
          <div class="button-row" style="margin-top: 22px">
            <a class="button primary" href="${repoUrl}/releases/tag/${release}">${esc(t.releaseNotes)}</a>
            <a class="button" href="${releaseBase}/checksums.sha256">${esc(t.checksums)}</a>
          </div>
        </div>
      </section>

      <section class="section alt">
        <div class="container">
          <div class="section-heading"><h2>${esc(t.choosePlatform)}</h2><p>${esc(releasePolicyCopy[lang.key].choose)}</p></div>
          <div class="download-grid">
            <article class="download-card"><div><h3>Windows</h3><p>${esc(t.winText)}</p></div>${artifactList(artifacts.windows, t)}</article>
            <article class="download-card"><div><h3>macOS</h3><p>${esc(t.macText)}</p></div>${artifactList(artifacts.macos, t)}</article>
            <article class="download-card"><div><h3>Linux</h3><p>${esc(t.linuxText)}</p></div>${artifactList(artifacts.linux, t)}</article>
            ${androidUnavailableCard(lang, t)}
            <article class="download-card"><div><h3>iOS</h3><p>${esc(t.iosText)}</p></div><span class="badge warn">${esc(t.buildRequired)}</span></article>
          </div>
        </div>
      </section>

      <section class="section">
        <div class="container">
          <div class="grid two">
            <div><h2>${esc(t.verifyH)}</h2><p class="muted">${esc(releasePolicyCopy[lang.key].verify)}</p></div>
            <div class="terminal"><div class="terminal-head"><span>${esc(t.checksumTerminal)}</span>${copyButton(t, checksumCommand)}</div><pre><code>${esc(checksumCommand)}</code></pre></div>
          </div>
        </div>
      </section>

      <section class="section alt">
        <div class="container">
          <div class="section-heading"><h2>${esc(t.publishedH)}</h2><p>${esc(t.publishedP)}</p></div>
          <div class="card"><ul class="checksum-list">
${checksums.map((item) => `              <li>${esc(item)}</li>`).join("\n")}
          </ul></div>
        </div>
      </section>

      <section class="section"><div class="container"><div class="notice"><p>${esc(t.previewNotice)}</p></div></div></section>
    </main>`;
  return page(lang, "download", t.downloadTitle, t.downloadMeta, body, t);
}

function docsPage(lang, t) {
  const body = `    <main>
      <section class="page-title"><div class="container"><p class="eyebrow"><span class="status-dot"></span> ${esc(t.quickStart)}</p><h1>${esc(t.docsH1)}</h1><p>${esc(t.docsIntro)}</p></div></section>
      <section class="section alt"><div class="container"><div class="grid three workflow">
${t.steps.map(([title, text]) => `        <article class="card step"><h3>${esc(title)}</h3><p>${esc(text)}</p></article>`).join("\n")}
      </div></div></section>
      <section class="section"><div class="container"><div class="section-heading"><h2>${esc(t.endpointsH)}</h2><p>${esc(t.endpointsP)}</p></div><div class="grid three">
        <article class="card dark"><h3>Mixed</h3><p>${esc(t.mixedP)}</p><div class="terminal"><pre><code>127.0.0.1:7890</code></pre></div></article>
        <article class="card dark"><h3>HTTP</h3><p>${esc(t.httpP)}</p><div class="terminal"><pre><code>http://127.0.0.1:7891</code></pre></div></article>
        <article class="card dark"><h3>SOCKS</h3><p>${esc(t.socksP)}</p><div class="terminal"><pre><code>socks5://127.0.0.1:7892</code></pre></div></article>
      </div></div></section>
      <section class="section alt"><div class="container"><div class="section-heading"><h2>${esc(t.providerH)}</h2><p>${esc(t.providerP)}</p></div><div class="grid three">
        <article class="card"><h3>Vultr</h3><p>${esc(t.vultrP)}</p></article>
        <article class="card"><h3>DigitalOcean</h3><p>${esc(t.doP)}</p></article>
        <article class="card"><h3>SSH host</h3><p>${esc(t.sshP)}</p></article>
      </div></div></section>
      <section class="section"><div class="container"><div class="section-heading"><h2>${esc(t.failuresH)}</h2><p>${esc(t.failuresP)}</p></div><div class="grid three">
${t.failures.map(([title, text]) => `        <article class="card"><h3>${esc(title)}</h3><p>${esc(text)}</p></article>`).join("\n")}
      </div></div></section>
      <section class="section alt"><div class="container"><div class="grid two"><div><h2>${esc(t.deeperH)}</h2><p class="muted">${esc(t.deeperP)}</p></div><ul class="link-list">
        <li><a href="/github">${esc(t.repoReadme)}</a></li>
        <li><a href="https://github.com/veilconnect/PrivateDeploy/blob/main/docs/ARCHITECTURE.md">${esc(t.architecture)}</a></li>
        <li><a href="https://github.com/veilconnect/PrivateDeploy/blob/main/docs/API_DESIGN.md">${esc(t.apiDesign)}</a></li>
        <li><a href="https://github.com/veilconnect/PrivateDeploy/blob/main/docs/GO-NO-GO-CHECKLIST.md">${esc(t.releaseChecklist)}</a></li>
      </ul></div></div></section>
    </main>`;
  return page(lang, "docs", t.docsTitle, t.docsMeta, body, t);
}

function securityPage(lang, t) {
  const gateCommand = "bash scripts/check_versions.sh\nscripts/secret_scan.sh";
  const badge = (kind) => {
    const label = kind === "required" ? t.required : kind === "providerSpecific" ? t.providerSpecific : t.conditional;
    return `<span class="badge${kind === "required" ? "" : " warn"}">${esc(label)}</span>`;
  };
  const body = `    <main>
      <section class="page-title"><div class="container"><p class="eyebrow"><span class="status-dot"></span> ${esc(t.securityEyebrow)}</p><h1>${esc(t.securityH1)}</h1><p>${esc(t.securityIntro)}</p></div></section>
      <section class="section alt"><div class="container"><div class="grid four">
${t.secretCards.map(([icon, title, text]) => `        <article class="card"><div class="icon-tile">${esc(icon)}</div><h3>${esc(title)}</h3><p>${esc(text)}</p></article>`).join("\n")}
      </div></div></section>
      <section class="section"><div class="container"><div class="section-heading"><h2>${esc(t.checklistH)}</h2><p>${esc(t.checklistP)}</p></div><div class="matrix">
        <div class="matrix-row matrix-head"><div>${esc(t.area)}</div><div>${esc(t.gate)}</div><div>${esc(t.outcome)}</div></div>
${t.checklistRows.map(([area, kind, outcome]) => `        <div class="matrix-row"><div>${esc(area)}</div><div>${badge(kind)}</div><div>${esc(outcome)}</div></div>`).join("\n")}
      </div></div></section>
      <section class="section alt"><div class="container"><div class="section-heading"><h2>${esc(t.dataH)}</h2><p>${esc(t.dataP)}</p></div><div class="grid three">
${t.dataCards.map(([title, text]) => `        <article class="card"><h3>${esc(title)}</h3><p>${esc(text)}</p></article>`).join("\n")}
      </div></div></section>
      <section class="section"><div class="container"><div class="grid two"><div><h2>${esc(t.responsibleH)}</h2><p class="muted">${esc(t.responsibleP)}</p></div><div class="terminal"><div class="terminal-head"><span>${esc(t.releaseGate)}</span>${copyButton(t, gateCommand)}</div><pre><code>${esc(gateCommand)}</code></pre></div></div></div></section>
    </main>`;
  return page(lang, "security", t.securityTitle, t.securityMeta, body, t);
}

function writeLocalizedPages(items) {
  for (const t of items) {
    const lang = languages.find((item) => item.key === t.key);
    if (!lang) throw new Error(`Unknown language: ${t.key}`);
    for (const section of ["download", "docs", "security"]) {
      const file = path.join(websiteDir, lang.prefix, section, "index.html");
      fs.mkdirSync(path.dirname(file), { recursive: true });
      const html = section === "download" ? downloadPage(lang, t) : section === "docs" ? docsPage(lang, t) : securityPage(lang, t);
      fs.writeFileSync(file, html);
    }
  }
}

function updateHomePages() {
  for (const lang of languages.filter((item) => item.prefix)) {
    const file = path.join(websiteDir, lang.prefix, "index.html");
    if (!fs.existsSync(file)) continue;
    let html = fs.readFileSync(file, "utf8");
    html = html
      .replaceAll('href="/download/"', `href="/${lang.prefix}/download/"`)
      .replaceAll('href="/docs/"', `href="/${lang.prefix}/docs/"`)
      .replaceAll('href="/security/"', `href="/${lang.prefix}/security/"`)
      .replaceAll("/assets/site-v3.css", "/assets/site-v5.css")
      .replaceAll("/assets/site-v4.css", "/assets/site-v5.css")
      .replaceAll("/assets/site-v3.js", "/assets/site-v5.js")
      .replaceAll("/assets/site-v4.js", "/assets/site-v5.js");
    fs.writeFileSync(file, html);
  }

  for (const file of fs.readdirSync(websiteDir, { recursive: true })) {
    if (!file.endsWith("index.html")) continue;
    const full = path.join(websiteDir, file);
    let html = fs.readFileSync(full, "utf8");
    html = html
      .replaceAll("/assets/site-v3.css", "/assets/site-v5.css")
      .replaceAll("/assets/site-v4.css", "/assets/site-v5.css")
      .replaceAll("/assets/site-v3.js", "/assets/site-v5.js")
      .replaceAll("/assets/site-v4.js", "/assets/site-v5.js");
    fs.writeFileSync(full, html);
  }
}

function readmeContent() {
  const routeRows = languages
    .map((lang) => `- \`${route(lang)}\`, \`${route(lang, "download")}\`, \`${route(lang, "docs")}\`, \`${route(lang, "security")}\``)
    .join("\n");
  return `# PrivateDeploy Website

This directory is a static Cloudflare Pages site for \`privatedeploy.org\`.

## Routes

The site provides the same four-page surface in 12 languages:

- Product landing page
- Download page
- Quick start documentation
- Security model

Languages:

${routeRows}

The language switcher appears on every public page and maps to the equivalent page in the selected language.

## Release manifest — single source of truth

\`website/tools/release-manifest.json\` is the single source of truth for the
release the download pages advertise: \`version\` (stable \`X.Y.Z\` only — the
release workflow's tag gate rejects prerelease tags and this generator matches
it), \`date\` (YYYY-MM-DD), and for every artifact its file name, display size
and SHA-256. All three generator paths (full render, \`--update-release\`,
\`--check\`) read the manifest; nothing about the published release is
hardcoded in \`render-localized-pages.js\`.

### Asset policy (keep the pages honest)

- The download pages deep-link **only** artifacts that the tag release
  workflow (\`.github/workflows/release.yml\`) actually builds and covers in
  \`checksums.sha256\` — currently the six desktop zips.
- Android APKs are **not** produced by the release workflow. The Android card
  therefore links to the GitHub Releases page neutrally instead of
  deep-linking APK files, and the site promises no APK checksums. Do not add
  a direct link for any asset unless the release workflow produces it and its
  checksum is in the manifest. Unsigned Android "stable" packages must not be
  advertised through this site.

### Modes

\`\`\`bash
# Point the pages (and the manifest) at a release. The target version comes
# from PD_RELEASE_VERSION or the newest stable vX.Y.Z git tag; the date from
# PD_RELEASE_DATE (YYYY-MM-DD) or that tag's commit date — never the clock.
# PD_RELEASE_CHECKSUMS_FILE=checksums.sha256 refreshes the published checksum
# list (strictly validated: 64-hex + known artifact names, no duplicates,
# full coverage). The checksum file and PD_RELEASE_ASSET_DIR are mandatory
# when the version changes, and display sizes come from those exact files.
# Do not pre-commit guessed hashes for a future tag: the tag workflow runs
# this against an isolated website copy after signed artifacts exist and
# uploads the verified copy as a deployable handoff.
PD_RELEASE_CHECKSUMS_FILE=checksums.sha256 \\
PD_RELEASE_ASSET_DIR=release-assets \\
node website/tools/render-localized-pages.js --update-release

# Verify every localized download page against the manifest: version tokens,
# release-notes/checksums/artifact links, artifact set, every checksum and
# the localized release date. Exits non-zero on any mismatch.
# PD_EXPECT_VERSION=X.Y.Z additionally asserts the manifest itself targets
# that version. The release workflow uses this on its post-build handoff.
node website/tools/render-localized-pages.js --check

# Compare current build checksums and sizes with the selected manifest.
PD_RELEASE_CHECKSUMS_FILE=checksums.sha256 \\
PD_RELEASE_ASSET_DIR=release-assets \\
node website/tools/render-localized-pages.js --verify-checksums

# Full re-render from a translations JSON array on stdin (the translated
# strings must already embed the manifest release/date in prose):
node website/tools/render-localized-pages.js < translations.json

# Tests (checksum-file validation, same-version refresh, --check pass/fail):
node --test website/tools/render-localized-pages.test.js
\`\`\`

The committed site may continue to advertise the previous stable release
while a new tag is being built. A successful tag run uploads
\`website-release-handoff-vX.Y.Z\`; deploy or merge that exact generated tree
after the GitHub release exists. This avoids a circular requirement for
precomputing hashes of timestamped signed artifacts.

## Local Preview

Open \`website/index.html\` directly in a browser, or serve the directory with any static file server.

## Cloudflare Pages

Recommended project settings:

- Project name: \`privatedeploy-site\`
- Build command: leave empty
- Build output directory: \`website\`
- Production branch: the release branch used for public site updates
- Custom domains:
  - \`privatedeploy.org\`
  - \`www.privatedeploy.org\`

Direct upload:

\`\`\`bash
npx wrangler pages deploy website --project-name privatedeploy-site
\`\`\`

The root \`wrangler.jsonc\` sets \`pages_build_output_dir\` to \`./website\`.
`;
}

function writeSiteFiles() {
  const sitemapUrls = [];
  for (const lang of languages) {
    for (const section of ["", "download", "docs", "security"]) {
      sitemapUrls.push(canonical(lang, section));
    }
  }
  fs.writeFileSync(
    path.join(websiteDir, "sitemap.xml"),
    `<?xml version="1.0" encoding="UTF-8"?>\n<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">\n${sitemapUrls
      .map((url) => `  <url>\n    <loc>${url}</loc>\n  </url>`)
      .join("\n")}\n</urlset>\n`,
  );

  const redirects = [];
  for (const section of ["download", "docs", "security"]) redirects.push(`/${section} /${section}/ 301`);
  for (const lang of languages.filter((item) => item.prefix)) {
    redirects.push(`/${lang.prefix} /${lang.prefix}/ 301`);
    for (const section of ["download", "docs", "security"]) redirects.push(`/${lang.prefix}/${section} /${lang.prefix}/${section}/ 301`);
  }
  redirects.push("/github https://github.com/veilconnect/PrivateDeploy 302");
  redirects.push("/releases https://github.com/veilconnect/PrivateDeploy/releases 302");
  redirects.push("/latest https://github.com/veilconnect/PrivateDeploy/releases/latest 302");
  fs.writeFileSync(path.join(websiteDir, "_redirects"), `${redirects.join("\n")}\n`);

  fs.writeFileSync(path.join(websiteDir, "README.md"), readmeContent());
}

// ── Maintenance modes ──────────────────────────────────────────────

const RELEASE_TAG_RE = /\bv\d+\.\d+\.\d+\b/g;
const DOWNLOAD_LINK_RE = /releases\/download\/([^/"'\s<&]+)\/([^"'\s<&]+)/g;
const CHECKSUM_LI_RE = /<li>\s*([0-9a-fA-F]{64})\s+([^\s<]+)\s*<\/li>/g;

function downloadPagePath(lang) {
  return path.join(websiteDir, lang.prefix, "download", "index.html");
}

// --check: every localized download page must agree with the manifest on
// version (all vX.Y.Z tokens), release-notes/checksums/artifact links, the
// artifact set, every published checksum, and the localized release date.
// Returns a list of problems (empty = OK).
function collectCheckProblems() {
  const problems = [];
  const artifactNames = new Set(manifest.artifacts.map((a) => a.name));
  const allowedDownloads = new Set([...artifactNames, "checksums.sha256"]);
  const expectedChecksums = checksumLines(manifest);

  for (const lang of languages) {
    const file = downloadPagePath(lang);
    const rel = path.relative(repoRoot, file);
    if (!fs.existsSync(file)) {
      problems.push(`${rel}: missing`);
      continue;
    }
    const html = fs.readFileSync(file, "utf8");

    // 1. Version tokens: exactly one distinct vX.Y.Z, equal to the manifest.
    const tags = [...new Set(html.match(RELEASE_TAG_RE) || [])];
    if (tags.length !== 1) {
      problems.push(`${rel}: expected exactly one release tag, found: ${tags.join(", ") || "(none)"}`);
    } else if (tags[0] !== release) {
      problems.push(`${rel}: references ${tags[0]}, expected ${release}`);
    }

    // 2. Release-notes link.
    if (!html.includes(`releases/tag/${release}`)) {
      problems.push(`${rel}: missing release notes link releases/tag/${release}`);
    }

    // 3. Every download link must use the manifest version and an allowed file.
    for (const m of html.matchAll(DOWNLOAD_LINK_RE)) {
      const [, tag, fileName] = m;
      if (tag !== release) problems.push(`${rel}: download link uses ${tag}, expected ${release} (${fileName})`);
      if (!allowedDownloads.has(fileName)) {
        problems.push(`${rel}: download link to "${fileName}" which the release workflow does not produce/checksum`);
      }
    }

    // 4. Every manifest artifact and checksums.sha256 must be linked.
    for (const name of [...artifactNames, "checksums.sha256"]) {
      if (!html.includes(`${releaseBase}/${name}`)) {
        problems.push(`${rel}: missing download link for ${name}`);
      }
    }

    // Display metadata is part of the manifest contract too. A stale or
    // invented size is misleading even when the filename/checksum is right.
    for (const artifact of manifest.artifacts) {
      if (!html.includes(`<strong>${esc(artifact.name)}</strong><span>${esc(artifact.size)}</span>`)) {
        problems.push(`${rel}: display size for ${artifact.name} does not match manifest value "${artifact.size}"`);
      }
    }

    const policy = releasePolicyCopy[lang.key];
    for (const [field, value] of Object.entries(policy)) {
      if (!html.includes(value)) problems.push(`${rel}: release policy copy "${field}" is missing or stale`);
    }
    if (html.includes("<strong>Android APK</strong>")) {
      problems.push(`${rel}: advertises an Android APK that the release workflow does not produce`);
    }

    // 5. Published checksum list must equal the manifest exactly.
    const listMatch = /<ul class="checksum-list">([\s\S]*?)<\/ul>/.exec(html);
    if (!listMatch) {
      problems.push(`${rel}: checksum list block not found`);
    } else {
      const found = [...listMatch[1].matchAll(CHECKSUM_LI_RE)].map((m) => `${m[1].toLowerCase()}  ${m[2]}`).sort();
      const expected = [...expectedChecksums].sort();
      if (found.join("\n") !== expected.join("\n")) {
        problems.push(`${rel}: published checksum list does not match the manifest\n      page:     ${found.join("\n                ") || "(none)"}\n      manifest: ${expected.join("\n                ")}`);
      }
    }

    // 6. Localized release date must match the manifest date.
    const dateStr = dateFormats[lang.key](releaseDate);
    if (!html.includes(dateStr)) {
      problems.push(`${rel}: localized release date "${dateStr}" (${isoOf(releaseDate)}) not found`);
    }
  }
  return problems;
}

function checkDownloadPages() {
  const expect = (process.env.PD_EXPECT_VERSION || "").trim().replace(/^v/, "");
  if (expect && expect !== manifest.version) {
    console.error(`Release manifest targets ${manifest.version} but PD_EXPECT_VERSION=${expect}. Generate an exact post-build handoff with --update-release.`);
    process.exit(1);
  }
  const problems = collectCheckProblems();
  if (problems.length) {
    console.error(`Localized download pages are NOT aligned with the release manifest (${release}, ${isoOf(releaseDate)}):`);
    for (const p of problems) console.error(`  - ${p}`);
    process.exit(1);
  }
  console.log(`OK: all ${languages.length} localized download pages match the manifest: ${release} (${isoOf(releaseDate)}), ${manifest.artifacts.length} artifacts, checksums verified`);
}

// --update-release: rewrite the localized download pages in place and the
// manifest, swapping the manifest's version/date for the target release and
// (optionally) refreshing the published checksums from
// PD_RELEASE_CHECKSUMS_FILE. A checksum refresh is applied even when the
// version is unchanged. For a new release this must run only after the final
// signed artifacts exist; the tag workflow does so in an isolated website
// copy before it publishes the GitHub Release. This does not touch translated
// prose beyond the version/date substrings, so it works without the original
// translations JSON.
function updateReleaseInPlace() {
  const newVersion = resolveTargetVersion();
  const newTag = `v${newVersion}`;
  const newDate = resolveTargetDate(newVersion);
  const oldTag = release;
  const oldDate = releaseDate;

  let newChecksumMap = null;
  const checksumsFile = (process.env.PD_RELEASE_CHECKSUMS_FILE || "").trim();
  if (checksumsFile) {
    const allowed = new Set(manifest.artifacts.map((a) => a.name));
    newChecksumMap = parseChecksumsFile(fs.readFileSync(checksumsFile, "utf8"), allowed);
  }

  let newSizeMap = null;
  const assetDir = (process.env.PD_RELEASE_ASSET_DIR || "").trim();
  if (assetDir) newSizeMap = builtArtifactSizes(assetDir, manifest.artifacts);

  if (newVersion !== manifest.version && !newChecksumMap) {
    throw new Error("PD_RELEASE_CHECKSUMS_FILE is required when changing release versions; reusing the previous release's hashes is forbidden");
  }
  if (newVersion !== manifest.version && !newSizeMap) {
    throw new Error("PD_RELEASE_ASSET_DIR is required when changing release versions; reusing the previous release's display sizes is forbidden");
  }

  const newManifest = {
    version: newVersion,
    date: isoOf(newDate),
    artifacts: manifest.artifacts.map((a) => {
      const next = { ...a };
      if (newChecksumMap) next.sha256 = newChecksumMap.get(a.name);
      if (newSizeMap) next.size = newSizeMap.get(a.name);
      return next;
    }),
  };
  const newChecksumLinesList = checksumLines(newManifest);

  // Two-phase: compute every page first so a failure never leaves the set
  // half-updated.
  const pending = [];
  for (const lang of languages) {
    const file = downloadPagePath(lang);
    const rel = path.relative(repoRoot, file);
    let html = fs.readFileSync(file, "utf8");
    html = applyReleasePolicyCopy(html, lang);

    if (newTag !== oldTag) {
      if (!html.includes(oldTag)) throw new Error(`${rel}: previous tag ${oldTag} not found`);
      html = html.split(oldTag).join(newTag);
    }

    const fmt = dateFormats[lang.key];
    const oldDateStr = fmt(oldDate);
    const newDateStr = fmt(newDate);
    if (oldDateStr !== newDateStr) {
      if (!html.includes(oldDateStr)) {
        throw new Error(`${rel}: expected previous release date "${oldDateStr}" (${lang.key} rendering of the manifest date) not found — update dateFormats or fix the page`);
      }
      html = html.split(oldDateStr).join(newDateStr);
    }

    // Artifact sizes are rendered beside their file names. Signed binaries,
    // notarization tickets and newly bundled notices can all change archive
    // size between releases, so update the exact name+size pair instead of
    // leaving the previous release's display metadata behind.
    for (const oldArtifact of manifest.artifacts) {
      const newArtifact = newManifest.artifacts.find((item) => item.name === oldArtifact.name);
      const oldMarker = `<strong>${esc(oldArtifact.name)}</strong><span>${esc(oldArtifact.size)}</span>`;
      const newMarker = `<strong>${esc(newArtifact.name)}</strong><span>${esc(newArtifact.size)}</span>`;
      if (!html.includes(oldMarker)) {
        throw new Error(`${rel}: previous display size for ${oldArtifact.name} not found`);
      }
      html = html.split(oldMarker).join(newMarker);
    }

    const listBlock = /(<ul class="checksum-list">\n)([\s\S]*?)(\n\s*<\/ul>)/;
    const m = listBlock.exec(html);
    if (!m) throw new Error(`${rel}: checksum list block not found`);
    const items = newChecksumLinesList.map((line) => `              <li>${esc(line)}</li>`).join("\n");
    html = html.replace(listBlock, `$1${items}$3`);

    pending.push([file, rel, html]);
  }
  for (const [file, rel, html] of pending) {
    fs.writeFileSync(file, html);
    console.log(`updated ${rel}: ${oldTag} -> ${newTag}${newChecksumMap ? " (checksums refreshed)" : ""}`);
  }
  fs.writeFileSync(manifestPath, `${JSON.stringify(newManifest, null, 2)}\n`);
  console.log(`updated ${path.relative(repoRoot, manifestPath)}: ${manifest.version} (${manifest.date}) -> ${newManifest.version} (${newManifest.date})`);
  writeSiteFiles();
}

function verifyChecksumsAgainstManifest() {
  const checksumsFile = (process.env.PD_RELEASE_CHECKSUMS_FILE || "").trim();
  if (!checksumsFile) throw new Error("PD_RELEASE_CHECKSUMS_FILE is required for --verify-checksums");
  const parsed = parseChecksumsFile(fs.readFileSync(checksumsFile, "utf8"), new Set(manifest.artifacts.map((a) => a.name)));
  const mismatches = manifest.artifacts.filter((a) => parsed.get(a.name) !== a.sha256);
  if (mismatches.length) {
    throw new Error(`built artifact checksums differ from release manifest: ${mismatches.map((a) => a.name).join(", ")}`);
  }

  const assetDirValue = (process.env.PD_RELEASE_ASSET_DIR || "").trim();
  if (assetDirValue) {
    const sizes = builtArtifactSizes(assetDirValue, manifest.artifacts);
    const sizeProblems = [];
    for (const artifact of manifest.artifacts) {
      const actual = sizes.get(artifact.name);
      if (actual !== artifact.size) sizeProblems.push(`${artifact.name}: built size ${actual}, manifest says ${artifact.size}`);
    }
    if (sizeProblems.length) throw new Error(`built artifact sizes differ from release manifest:\n${sizeProblems.join("\n")}`);
  }
  console.log(`OK: built checksums${assetDirValue ? " and sizes" : ""} match the ${release} manifest (${manifest.artifacts.length} artifacts)`);
}

// ── Entry point ────────────────────────────────────────────────────

function main() {
  const mode = process.argv[2] || "";
  if (mode === "--check") {
    checkDownloadPages();
  } else if (mode === "--update-release") {
    updateReleaseInPlace();
  } else if (mode === "--verify-checksums") {
    verifyChecksumsAgainstManifest();
  } else if (mode === "") {
    let input = "";
    process.stdin.setEncoding("utf8");
    process.stdin.on("data", (chunk) => {
      input += chunk;
    });
    process.stdin.on("end", () => {
      const items = input.trim() ? JSON.parse(input) : [];
      writeLocalizedPages(items);
      updateHomePages();
      writeSiteFiles();
    });
  } else {
    console.error(`Unknown mode: ${mode}\nUsage: node ${path.relative(repoRoot, __filename)} [--check | --update-release | --verify-checksums] (no args = full render from stdin translations JSON)`);
    process.exit(2);
  }
}

if (require.main === module) {
  main();
}

module.exports = {
  manifest,
  release,
  releaseDate,
  languages,
  dateFormats,
  validateManifest,
  parseChecksumsFile,
  checksumLines,
  collectCheckProblems,
  downloadPagePath,
  downloadPage,
};
