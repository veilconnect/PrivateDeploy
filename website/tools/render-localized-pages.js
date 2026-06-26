const fs = require("fs");
const path = require("path");

const domain = "https://privatedeploy.org";
const release = "v2.0.12";
const releaseBase = `https://github.com/veilconnect/PrivateDeploy/releases/download/${release}`;

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

const checksums = [
  "c591335c0657608e399ce24065972f64f06dcce9b82422679b22b9bafc7e391a  PrivateDeploy-darwin-amd64.zip",
  "3213b38834ae0642726f1449e5cdccaec044f97bb723a1b39504eadc46a86443  PrivateDeploy-darwin-arm64.zip",
  "100b9debafbbc33db775128b4d8fb8740002471b647fd5982ffd38418fdd83cb  PrivateDeploy-linux-amd64.zip",
  "2c0d0ebae889cd10475f1161435cf7a5864b42332095ddff3abc15736c47d232  PrivateDeploy-windows-386.zip",
  "d3b4af04637b61740cf740f00fe799dd36201a910a938fc7ce58bc44a943a374  PrivateDeploy-windows-amd64.zip",
  "866449264367a9af6b7ccfb4e3d6ab22cb5de4bfd035c871d13f7a71ffe82588  PrivateDeploy-windows-arm64.zip",
];

const artifacts = {
  windows: [
    ["PrivateDeploy-windows-amd64.zip", "6.5 MB", true],
    ["PrivateDeploy-windows-arm64.zip", "6.0 MB", false],
    ["PrivateDeploy-windows-386.zip", "6.4 MB", false],
  ],
  macos: [
    ["PrivateDeploy-darwin-arm64.zip", "5.7 MB", true],
    ["PrivateDeploy-darwin-amd64.zip", "6.2 MB", false],
  ],
  linux: [["PrivateDeploy-linux-amd64.zip", "6.1 MB", true]],
  android: [
    ["PrivateDeploy-android-arm64.apk", "51.3 MB", true],
    ["PrivateDeploy-android-universal.apk", "150.2 MB", false],
  ],
};

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

function copyButton(t, value) {
  return `<button class="button" type="button" data-copy="${esc(value)}" data-copied="${esc(t.copied)}" data-copy-failed="${esc(t.copyFailed)}">${esc(t.copy)}</button>`;
}

function downloadPage(lang, t) {
  const checksumCommand = `curl -L -O ${releaseBase}/checksums.sha256\nsha256sum -c checksums.sha256`;
  const body = `    <main>
      <section class="page-title">
        <div class="container">
          <p class="eyebrow"><span class="status-dot"></span> ${esc(t.dist)}</p>
          <h1>${esc(t.downloadH1)}</h1>
          <p>${esc(t.downloadIntro)}</p>
          <div class="button-row" style="margin-top: 22px">
            <a class="button primary" href="https://github.com/veilconnect/PrivateDeploy/releases/tag/${release}">${esc(t.releaseNotes)}</a>
            <a class="button" href="${releaseBase}/checksums.sha256">${esc(t.checksums)}</a>
          </div>
        </div>
      </section>

      <section class="section alt">
        <div class="container">
          <div class="section-heading"><h2>${esc(t.choosePlatform)}</h2><p>${esc(t.chooseText)}</p></div>
          <div class="download-grid">
            <article class="download-card"><div><h3>Windows</h3><p>${esc(t.winText)}</p></div>${artifactList(artifacts.windows, t)}</article>
            <article class="download-card"><div><h3>macOS</h3><p>${esc(t.macText)}</p></div>${artifactList(artifacts.macos, t)}</article>
            <article class="download-card"><div><h3>Linux</h3><p>${esc(t.linuxText)}</p></div>${artifactList(artifacts.linux, t)}</article>
            <article class="download-card"><div><h3>Android</h3><p>${esc(t.androidText)}</p></div>${artifactList(artifacts.android, t)}</article>
            <article class="download-card"><div><h3>iOS</h3><p>${esc(t.iosText)}</p></div><span class="badge warn">${esc(t.buildRequired)}</span></article>
          </div>
        </div>
      </section>

      <section class="section">
        <div class="container">
          <div class="grid two">
            <div><h2>${esc(t.verifyH)}</h2><p class="muted">${esc(t.verifyP)}</p></div>
            <div class="terminal"><div class="terminal-head"><span>${esc(t.checksumTerminal)}</span>${copyButton(t, checksumCommand)}</div><pre><code>${esc(checksumCommand)}</code></pre></div>
          </div>
        </div>
      </section>

      <section class="section alt">
        <div class="container">
          <div class="section-heading"><h2>${esc(t.publishedH)}</h2><p>${esc(t.publishedP)}</p></div>
          <div class="card"><ul class="checksum-list">
${checksums.map((item) => `              <li>${item}</li>`).join("\n")}
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
      const file = path.join("website", lang.prefix, section, "index.html");
      fs.mkdirSync(path.dirname(file), { recursive: true });
      const html = section === "download" ? downloadPage(lang, t) : section === "docs" ? docsPage(lang, t) : securityPage(lang, t);
      fs.writeFileSync(file, html);
    }
  }
}

function updateHomePages() {
  for (const lang of languages.filter((item) => item.prefix)) {
    const file = path.join("website", lang.prefix, "index.html");
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

  for (const file of fs.readdirSync("website", { recursive: true })) {
    if (!file.endsWith("index.html")) continue;
    const full = path.join("website", file);
    let html = fs.readFileSync(full, "utf8");
    html = html
      .replaceAll("/assets/site-v3.css", "/assets/site-v5.css")
      .replaceAll("/assets/site-v4.css", "/assets/site-v5.css")
      .replaceAll("/assets/site-v3.js", "/assets/site-v5.js")
      .replaceAll("/assets/site-v4.js", "/assets/site-v5.js");
    fs.writeFileSync(full, html);
  }
}

function writeSiteFiles() {
  const sitemapUrls = [];
  for (const lang of languages) {
    for (const section of ["", "download", "docs", "security"]) {
      sitemapUrls.push(canonical(lang, section));
    }
  }
  fs.writeFileSync(
    "website/sitemap.xml",
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
  fs.writeFileSync("website/_redirects", `${redirects.join("\n")}\n`);

  const routeRows = languages
    .map((lang) => `- \`${route(lang)}\`, \`${route(lang, "download")}\`, \`${route(lang, "docs")}\`, \`${route(lang, "security")}\``)
    .join("\n");
  fs.writeFileSync(
    "website/README.md",
    `# PrivateDeploy Website\n\nThis directory is a static Cloudflare Pages site for \`privatedeploy.org\`.\n\n## Routes\n\nThe site provides the same four-page surface in 12 languages:\n\n- Product landing page\n- Download page\n- Quick start documentation\n- Security model\n\nLanguages:\n\n${routeRows}\n\nThe language switcher appears on every public page and maps to the equivalent page in the selected language.\n\n## Local Preview\n\nOpen \`website/index.html\` directly in a browser, or serve the directory with any static file server.\n\n## Cloudflare Pages\n\nRecommended project settings:\n\n- Project name: \`privatedeploy-site\`\n- Build command: leave empty\n- Build output directory: \`website\`\n- Production branch: the release branch used for public site updates\n- Custom domains:\n  - \`privatedeploy.org\`\n  - \`www.privatedeploy.org\`\n\nDirect upload:\n\n\`\`\`bash\nnpx wrangler pages deploy website --project-name privatedeploy-site\n\`\`\`\n\nThe root \`wrangler.jsonc\` sets \`pages_build_output_dir\` to \`./website\`.\n`,
  );
}

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
