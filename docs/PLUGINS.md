# Plugins: Security Model and Risk Notice

> 中文版：[PLUGINS.zh-CN.md](PLUGINS.zh-CN.md)

## Plugins are fully trusted code

PrivateDeploy desktop plugins (Plugins page → Plugin-Hub or manual add) are
JavaScript programs executed **inside the app itself, with no sandbox**. A
plugin runs with the same privileges as the application and has full access to
the app's native bridge. Concretely, an installed and enabled plugin can:

- **Read and modify your files** — anything the app process can touch,
  including your profiles, subscriptions, and node credentials stored by the
  app.
- **Access the network** — send requests to, and exfiltrate data toward, any
  address.
- **Execute commands on your machine** — spawn native processes via the
  app's exec bridge.

There is no capability or permission manifest: every plugin implicitly holds
all of the above. That is why the app shows a full-trust warning dialog and
requires explicit confirmation **before any plugin is added** (whether from
the Plugin-Hub or via the manual form). If plugins ever gain a capability
declaration, an undeclared plugin must still be treated — and warned about —
as fully trusted.

**Only install plugins whose author and source you trust.** Treat installing
a plugin exactly like running an unknown program on your computer.

## What the app does (and does not) protect

The app applies two low-friction defenses around plugin *delivery* — neither
restricts what approved code can do once it runs:

1. **Source allowlist.** Remote plugin code may only be fetched over HTTPS
   from allowlisted hosts (the official GUI-for-Cores Plugin-Hub on GitHub).
   Redirects are re-validated hop by hop, so an open redirect cannot bounce
   the download to an arbitrary origin.
2. **Code pinning (trust-on-first-use).** Plugin code is pinned by SHA-256
   when first installed. If the code later drifts — a remote update or
   on-disk tampering — the plugin will not load or update until you
   explicitly re-approve the changed code.

These defenses reduce the risk of *receiving* malicious code you did not ask
for. They do **not** limit a plugin you approved: an approved malicious
plugin still has full access as described above.

## Practical guidance

- Prefer plugins from the official Plugin-Hub, and skim their source (the
  in-app **Source** button) before installing.
- When the app reports "plugin code changed", do not re-approve unless you
  understand why it changed (e.g. an update whose changelog you have read).
- Disable or delete plugins you no longer use.
- Never install a plugin sent to you privately or hosted outside the
  allowlisted sources, even if it "just needs one temporary exception".
