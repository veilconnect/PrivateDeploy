# PrivateDeploy Website

This directory is a static Cloudflare Pages site for `privatedeploy.org`.

## Routes

The site provides the same four-page surface in 12 languages:

- Product landing page
- Download page
- Quick start documentation
- Security model

Languages:

- `/`, `/download/`, `/docs/`, `/security/`
- `/zh/`, `/zh/download/`, `/zh/docs/`, `/zh/security/`
- `/es/`, `/es/download/`, `/es/docs/`, `/es/security/`
- `/fr/`, `/fr/download/`, `/fr/docs/`, `/fr/security/`
- `/de/`, `/de/download/`, `/de/docs/`, `/de/security/`
- `/ja/`, `/ja/download/`, `/ja/docs/`, `/ja/security/`
- `/ko/`, `/ko/download/`, `/ko/docs/`, `/ko/security/`
- `/pt/`, `/pt/download/`, `/pt/docs/`, `/pt/security/`
- `/ru/`, `/ru/download/`, `/ru/docs/`, `/ru/security/`
- `/ar/`, `/ar/download/`, `/ar/docs/`, `/ar/security/`
- `/hi/`, `/hi/download/`, `/hi/docs/`, `/hi/security/`
- `/id/`, `/id/download/`, `/id/docs/`, `/id/security/`

The language switcher appears on every public page and maps to the equivalent page in the selected language.

## Release manifest — single source of truth

`website/tools/release-manifest.json` is the single source of truth for the
release the download pages advertise: `version` (stable `X.Y.Z` only — the
release workflow's tag gate rejects prerelease tags and this generator matches
it), `date` (YYYY-MM-DD), and for every artifact its file name, display size
and SHA-256. All three generator paths (full render, `--update-release`,
`--check`) read the manifest; nothing about the published release is
hardcoded in `render-localized-pages.js`.

### Asset policy (keep the pages honest)

- The download pages deep-link **only** artifacts that the tag release
  workflow (`.github/workflows/release.yml`) actually builds and covers in
  `checksums.sha256` — currently the six desktop zips.
- Android APKs are **not** produced by the release workflow. The Android card
  therefore links to the GitHub Releases page neutrally instead of
  deep-linking APK files, and the site promises no APK checksums. Do not add
  a direct link for any asset unless the release workflow produces it and its
  checksum is in the manifest. Unsigned Android "stable" packages must not be
  advertised through this site.

### Modes

```bash
# Point the pages (and the manifest) at a release. The target version comes
# from PD_RELEASE_VERSION or the newest stable vX.Y.Z git tag; the date from
# PD_RELEASE_DATE (YYYY-MM-DD) or that tag's commit date — never the clock.
# PD_RELEASE_CHECKSUMS_FILE=checksums.sha256 refreshes the published checksum
# list (strictly validated: 64-hex + known artifact names, no duplicates,
# full coverage). Refreshing works even when the version is unchanged. The
# file and PD_RELEASE_ASSET_DIR are mandatory when the version changes; sizes
# are derived from those exact built files. Do not pre-commit guessed hashes
# for a future tag: signing/notarization timestamps make them unknowable until
# the final archives exist. The tag workflow runs this against an isolated
# website copy and uploads that verified copy as a deployable handoff.
PD_RELEASE_CHECKSUMS_FILE=checksums.sha256 \
PD_RELEASE_ASSET_DIR=release-assets \
  node website/tools/render-localized-pages.js --update-release

# Verify every localized download page against the manifest: version tokens,
# release-notes/checksums/artifact links, artifact set, every checksum and
# the localized release date. Exits non-zero on any mismatch.
# PD_EXPECT_VERSION=X.Y.Z additionally asserts the manifest itself targets
# that version. The release workflow uses this only on the post-build handoff.
node website/tools/render-localized-pages.js --check

# Compare the checksums and sizes produced by the current build with the
# selected manifest. The release workflow runs this on the generated handoff
# after assembling all artifacts and before publishing the GitHub Release.
PD_RELEASE_CHECKSUMS_FILE=checksums.sha256 \
PD_RELEASE_ASSET_DIR=release-assets \
  node website/tools/render-localized-pages.js --verify-checksums

# Full re-render from a translations JSON array on stdin (the translated
# strings must already embed the manifest release/date in prose):
node website/tools/render-localized-pages.js < translations.json

# Tests (checksum-file validation, same-version refresh, --check pass/fail):
node --test website/tools/render-localized-pages.test.js
```

The committed site may therefore continue to advertise the previous stable
release while a new tag is being built. A successful tag run uploads
`website-release-handoff-vX.Y.Z`; deploy or merge that exact generated tree
after the GitHub release exists. This two-phase process avoids a circular
requirement for precomputing hashes of timestamped signed artifacts.

## Local Preview

Open `website/index.html` directly in a browser, or serve the directory with any static file server.

## Cloudflare Pages

Recommended project settings:

- Project name: `privatedeploy-site`
- Build command: leave empty
- Build output directory: `website`
- Production branch: the release branch used for public site updates
- Custom domains:
  - `privatedeploy.org`
  - `www.privatedeploy.org`

Direct upload:

```bash
npx wrangler pages deploy website --project-name privatedeploy-site
```

The root `wrangler.jsonc` sets `pages_build_output_dir` to `./website`.
