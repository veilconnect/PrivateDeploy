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
