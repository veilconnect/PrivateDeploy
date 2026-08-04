// Tests for website/tools/render-localized-pages.js.
//
// Run with:  node --test website/tools/render-localized-pages.test.js
// (also works as plain `node website/tools/render-localized-pages.test.js`).
//
// Covers:
//   - checksum file validation (bad hex / unknown file / duplicates / gaps)
//   - manifest validation (stable versions only)
//   - the committed pages agree with the committed manifest (direct assertion)
//   - --check pass and fail scenarios (subprocess on a throwaway site copy)
//   - --update-release same-version checksum refresh and version bump

const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("fs");
const os = require("os");
const path = require("path");
const { execFileSync } = require("child_process");

const toolPath = path.join(__dirname, "render-localized-pages.js");
const websiteDir = path.join(__dirname, "..");
const tool = require(toolPath);

const HEX = "0123456789abcdef".repeat(4); // 64 lowercase hex chars

function manifestNames() {
  return new Set(tool.manifest.artifacts.map((a) => a.name));
}

function validChecksumText(mutate) {
  const lines = tool.manifest.artifacts.map((a) => `${a.sha256}  ${a.name}`);
  return (mutate ? mutate(lines) : lines).join("\n") + "\n";
}

// Runs the tool as a subprocess against `siteDir` (via the PD_WEBSITE_DIR
// test hook). Returns { status, stdout, stderr }.
function runTool(args, env, siteDir) {
  try {
    const stdout = execFileSync(process.execPath, [toolPath, ...args], {
      env: { ...process.env, PD_WEBSITE_DIR: siteDir, ...env },
      encoding: "utf8",
      stdio: ["ignore", "pipe", "pipe"],
    });
    return { status: 0, stdout, stderr: "" };
  } catch (err) {
    return { status: err.status, stdout: err.stdout || "", stderr: err.stderr || "" };
  }
}

function makeSiteCopy() {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "pd-website-test-"));
  fs.cpSync(websiteDir, dir, { recursive: true });
  return dir;
}

function makeBuiltAssets(site) {
  const assets = path.join(site, "release-assets");
  fs.mkdirSync(assets, { recursive: true });
  for (const artifact of tool.manifest.artifacts) {
    const file = path.join(assets, artifact.name);
    fs.closeSync(fs.openSync(file, "w"));
    fs.truncateSync(file, Math.round(Number.parseFloat(artifact.size) * 1024 * 1024));
  }
  return assets;
}

// ── checksum file validation ───────────────────────────────────────

test("parseChecksumsFile accepts a valid sha256sum file", () => {
  const map = tool.parseChecksumsFile(validChecksumText(), manifestNames());
  assert.equal(map.size, tool.manifest.artifacts.length);
  for (const a of tool.manifest.artifacts) assert.equal(map.get(a.name), a.sha256);
});

test("parseChecksumsFile rejects bad hex (wrong length)", () => {
  assert.throws(
    () => tool.parseChecksumsFile(validChecksumText((l) => [`${"ab".repeat(31)}  ${tool.manifest.artifacts[0].name}`, ...l.slice(1)]), manifestNames()),
    /malformed line/,
  );
});

test("parseChecksumsFile rejects bad hex (non-hex characters)", () => {
  const bad = "z".repeat(64);
  assert.throws(
    () => tool.parseChecksumsFile(validChecksumText((l) => [`${bad}  ${tool.manifest.artifacts[0].name}`, ...l.slice(1)]), manifestNames()),
    /malformed line/,
  );
});

test("parseChecksumsFile rejects unknown artifact names", () => {
  assert.throws(
    () => tool.parseChecksumsFile(validChecksumText((l) => [...l, `${HEX}  PrivateDeploy-android-arm64.apk`]), manifestNames()),
    /not an allowed release artifact/,
  );
});

test("parseChecksumsFile rejects duplicate entries", () => {
  assert.throws(
    () => tool.parseChecksumsFile(validChecksumText((l) => [...l, l[0]]), manifestNames()),
    /duplicate entry/,
  );
});

test("parseChecksumsFile rejects files that do not cover every artifact", () => {
  assert.throws(
    () => tool.parseChecksumsFile(validChecksumText((l) => l.slice(1)), manifestNames()),
    /missing entries/,
  );
});

// ── manifest validation ────────────────────────────────────────────

test("validateManifest accepts the committed manifest", () => {
  const raw = JSON.parse(fs.readFileSync(path.join(__dirname, "release-manifest.json"), "utf8"));
  assert.equal(tool.validateManifest(raw).version, tool.manifest.version);
});

test("validateManifest rejects prerelease versions", () => {
  assert.throws(() => tool.validateManifest({ ...tool.manifest, version: "2.0.14-rc1" }), /stable X\.Y\.Z/);
});

test("validateManifest rejects bad sha256 values", () => {
  const artifacts = tool.manifest.artifacts.map((a, i) => (i === 0 ? { ...a, sha256: "nothex" } : a));
  assert.throws(() => tool.validateManifest({ ...tool.manifest, artifacts }), /invalid sha256/);
});

test("validateManifest rejects impossible calendar dates", () => {
  assert.throws(() => tool.validateManifest({ ...tool.manifest, date: "2026-99-99" }), /real calendar date/);
});

// ── committed pages vs committed manifest ─────────────────────────

test("every committed localized download page matches the manifest", () => {
  const problems = tool.collectCheckProblems();
  assert.deepEqual(problems, []);
  const expected = tool.checksumLines(tool.manifest).sort();
  for (const lang of tool.languages) {
    const html = fs.readFileSync(tool.downloadPagePath(lang), "utf8");
    const found = [...html.matchAll(/<li>\s*([0-9a-f]{64})\s+(\S+?)\s*<\/li>/g)]
      .map((m) => `${m[1]}  ${m[2]}`)
      .sort();
    assert.deepEqual(found, expected, `checksum list mismatch in ${lang.key} page`);
    assert.ok(!/releases\/download\/[^"'\s<&]+\/[^"'\s<&]*\.apk/.test(html), `${lang.key} page must not deep-link APK files`);
  }
});

// ── --check pass/fail (subprocess, throwaway copy) ─────────────────

test("--check passes on a pristine copy", () => {
  const site = makeSiteCopy();
  const res = runTool(["--check"], {}, site);
  assert.equal(res.status, 0, res.stderr);
  assert.match(res.stdout, /OK: all 12 localized download pages match the manifest/);
});

test("--check fails when a published checksum is tampered", () => {
  const site = makeSiteCopy();
  const page = path.join(site, "de", "download", "index.html");
  const html = fs.readFileSync(page, "utf8");
  const tampered = html.replace(tool.manifest.artifacts[0].sha256, HEX);
  assert.notEqual(tampered, html);
  fs.writeFileSync(page, tampered);
  const res = runTool(["--check"], {}, site);
  assert.equal(res.status, 1);
  assert.match(res.stderr, /checksum list does not match the manifest/);
});

test("--check fails when a page references the wrong version", () => {
  const site = makeSiteCopy();
  const page = path.join(site, "download", "index.html");
  fs.writeFileSync(page, fs.readFileSync(page, "utf8").replaceAll(tool.release, "v9.9.9"));
  const res = runTool(["--check"], {}, site);
  assert.equal(res.status, 1);
  assert.match(res.stderr, /references v9\.9\.9|expected v/);
});

test("--check fails when a page grows an unlisted download link", () => {
  const site = makeSiteCopy();
  const page = path.join(site, "download", "index.html");
  const html = fs.readFileSync(page, "utf8").replace(
    "</main>",
    `<a href="https://github.com/veilconnect/PrivateDeploy/releases/download/${tool.release}/PrivateDeploy-android-arm64.apk">x</a></main>`,
  );
  fs.writeFileSync(page, html);
  const res = runTool(["--check"], {}, site);
  assert.equal(res.status, 1);
  assert.match(res.stderr, /does not produce\/checksum/);
});

test("--check fails when an artifact display size drifts", () => {
  const site = makeSiteCopy();
  const page = path.join(site, "download", "index.html");
  fs.writeFileSync(page, fs.readFileSync(page, "utf8").replace(tool.manifest.artifacts[0].size, "999 GB"));
  const res = runTool(["--check"], {}, site);
  assert.equal(res.status, 1);
  assert.match(res.stderr, /display size/);
});

test("--check honors PD_EXPECT_VERSION (release workflow gate)", () => {
  const site = makeSiteCopy();
  const ok = runTool(["--check"], { PD_EXPECT_VERSION: tool.manifest.version }, site);
  assert.equal(ok.status, 0, ok.stderr);
  const bad = runTool(["--check"], { PD_EXPECT_VERSION: "9.9.9" }, site);
  assert.equal(bad.status, 1);
  assert.match(bad.stderr, /Generate an exact post-build handoff/);
});

test("--verify-checksums compares built artifacts with the manifest", () => {
  const site = makeSiteCopy();
  const checksumsFile = path.join(site, "built-checksums.sha256");
  fs.writeFileSync(checksumsFile, validChecksumText());
  const ok = runTool(["--verify-checksums"], { PD_RELEASE_CHECKSUMS_FILE: checksumsFile }, site);
  assert.equal(ok.status, 0, ok.stderr);

  fs.writeFileSync(checksumsFile, validChecksumText((lines) => [`${HEX}  ${tool.manifest.artifacts[0].name}`, ...lines.slice(1)]));
  const bad = runTool(["--verify-checksums"], { PD_RELEASE_CHECKSUMS_FILE: checksumsFile }, site);
  assert.notEqual(bad.status, 0);
  assert.match(bad.stderr, /differ from release manifest/);
});

test("--verify-checksums compares display sizes with the built files", () => {
  const site = makeSiteCopy();
  const checksumsFile = path.join(site, "built-checksums.sha256");
  const assets = makeBuiltAssets(site);
  fs.writeFileSync(checksumsFile, validChecksumText());
  const ok = runTool(["--verify-checksums"], {
    PD_RELEASE_CHECKSUMS_FILE: checksumsFile,
    PD_RELEASE_ASSET_DIR: assets,
  }, site);
  assert.equal(ok.status, 0, ok.stderr);

  fs.truncateSync(path.join(assets, tool.manifest.artifacts[0].name), 1);
  const bad = runTool(["--verify-checksums"], {
    PD_RELEASE_CHECKSUMS_FILE: checksumsFile,
    PD_RELEASE_ASSET_DIR: assets,
  }, site);
  assert.notEqual(bad.status, 0);
  assert.match(bad.stderr, /built artifact sizes differ/);
});

// ── --update-release ───────────────────────────────────────────────

test("--update-release refreshes checksums for the SAME version", () => {
  const site = makeSiteCopy();
  const newHash = HEX;
  const target = tool.manifest.artifacts[0];
  const checksumsFile = path.join(site, "new-checksums.sha256");
  fs.writeFileSync(checksumsFile, validChecksumText((lines) => lines.map((l) => (l.endsWith(`  ${target.name}`) ? `${newHash}  ${target.name}` : l))));

  const res = runTool(["--update-release"], {
    PD_RELEASE_VERSION: tool.manifest.version,
    PD_RELEASE_DATE: tool.manifest.date,
    PD_RELEASE_CHECKSUMS_FILE: checksumsFile,
  }, site);
  assert.equal(res.status, 0, res.stderr);
  assert.match(res.stdout, /checksums refreshed/);

  const newManifest = JSON.parse(fs.readFileSync(path.join(site, "tools", "release-manifest.json"), "utf8"));
  assert.equal(newManifest.version, tool.manifest.version);
  assert.equal(newManifest.artifacts.find((a) => a.name === target.name).sha256, newHash);
  for (const lang of tool.languages) {
    const html = fs.readFileSync(path.join(site, lang.prefix, "download", "index.html"), "utf8");
    assert.ok(html.includes(`${newHash}  ${target.name}`), `${lang.key} page missing refreshed checksum`);
    assert.ok(!html.includes(`${target.sha256}  ${target.name}`), `${lang.key} page still has the stale checksum`);
  }
  const check = runTool(["--check"], {}, site);
  assert.equal(check.status, 0, check.stderr);
});

test("--update-release rejects an invalid checksums file", () => {
  const site = makeSiteCopy();
  const checksumsFile = path.join(site, "bad-checksums.sha256");
  fs.writeFileSync(checksumsFile, `deadbeef  ${tool.manifest.artifacts[0].name}\n`);
  const res = runTool(["--update-release"], {
    PD_RELEASE_VERSION: tool.manifest.version,
    PD_RELEASE_DATE: tool.manifest.date,
    PD_RELEASE_CHECKSUMS_FILE: checksumsFile,
  }, site);
  assert.notEqual(res.status, 0);
  assert.match(res.stderr, /malformed line/);
  // Pages must be untouched (two-phase write).
  const check = runTool(["--check"], {}, site);
  assert.equal(check.status, 0, check.stderr);
});

test("--update-release rejects prerelease target versions", () => {
  const site = makeSiteCopy();
  const res = runTool(["--update-release"], { PD_RELEASE_VERSION: "3.0.0-rc1", PD_RELEASE_DATE: "2026-07-13" }, site);
  assert.notEqual(res.status, 0);
  assert.match(res.stderr, /stable X\.Y\.Z/);
});

test("--update-release refuses a version change without fresh checksums", () => {
  const site = makeSiteCopy();
  const res = runTool(["--update-release"], {
    PD_RELEASE_VERSION: "9.9.8",
    PD_RELEASE_DATE: "2026-07-13",
  }, site);
  assert.notEqual(res.status, 0);
  assert.match(res.stderr, /PD_RELEASE_CHECKSUMS_FILE is required/);
});

test("--update-release refuses a version change without fresh built sizes", () => {
  const site = makeSiteCopy();
  const checksumsFile = path.join(site, "next-checksums.sha256");
  fs.writeFileSync(checksumsFile, validChecksumText());
  const res = runTool(["--update-release"], {
    PD_RELEASE_VERSION: "9.9.8",
    PD_RELEASE_DATE: "2026-07-13",
    PD_RELEASE_CHECKSUMS_FILE: checksumsFile,
  }, site);
  assert.notEqual(res.status, 0);
  assert.match(res.stderr, /PD_RELEASE_ASSET_DIR is required/);
});

test("--update-release bumps version + date + checksums across all languages", () => {
  const site = makeSiteCopy();
  const assets = makeBuiltAssets(site);
  // A real signed/notarized release will not retain the previous archives'
  // exact sizes. Exercise that change so the generated pages cannot keep
  // stale display metadata while only the manifest changes.
  fs.truncateSync(path.join(assets, tool.manifest.artifacts[0].name), 1024 * 1024);
  const checksumsFile = path.join(site, "next-checksums.sha256");
  fs.writeFileSync(checksumsFile, validChecksumText((lines) => lines.map((l) => `${HEX}  ${l.split("  ")[1]}`)));

  const res = runTool(["--update-release"], {
    PD_RELEASE_VERSION: "9.1.2",
    PD_RELEASE_DATE: "2026-07-13",
    PD_RELEASE_CHECKSUMS_FILE: checksumsFile,
    PD_RELEASE_ASSET_DIR: assets,
  }, site);
  assert.equal(res.status, 0, res.stderr);

  const newManifest = JSON.parse(fs.readFileSync(path.join(site, "tools", "release-manifest.json"), "utf8"));
  assert.equal(newManifest.version, "9.1.2");
  assert.equal(newManifest.date, "2026-07-13");
  assert.equal(newManifest.artifacts[0].size, "1.0 MB");
  for (const lang of tool.languages) {
    const html = fs.readFileSync(path.join(site, lang.prefix, "download", "index.html"), "utf8");
    assert.ok(html.includes("v9.1.2"), `${lang.key} page not bumped`);
    assert.ok(!html.includes(tool.release), `${lang.key} page still references ${tool.release}`);
    assert.ok(html.includes(tool.dateFormats[lang.key]({ y: 2026, m: 7, d: 13 })), `${lang.key} page missing new localized date`);
    assert.ok(
      html.includes(`<strong>${tool.manifest.artifacts[0].name}</strong><span>1.0 MB</span>`),
      `${lang.key} page kept the previous display size`,
    );
  }
  const check = runTool(["--check"], {}, site);
  assert.equal(check.status, 0, check.stderr);
});
