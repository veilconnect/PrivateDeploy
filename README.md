# PrivateDeploy

PrivateDeploy is a cross-platform desktop application (Vue 3 + Wails) that automates the provisioning of hardened proxy nodes on Vultr. A single deployment script brings up four protocols on one VPS – Shadowsocks, Hysteria2, VLESS-Reality, and Trojan – and the GUI keeps credentials, client profiles, and health information in sync.

## Highlights

- **Multi-protocol stack** – Deploy Shadowsocks, Hysteria2, VLESS-Reality (with Reality public key + short ID), and Trojan in one pass. Low-memory plans automatically fall back to a lightweight Shadowsocks-only setup.
- **Automatic credential sync** – The app persists every protocol credential (ports, passwords, UUID, Reality keys) and exposes them in the cloud panel with one-click copy actions.
- **Subscription integration** – Generated nodes are converted into sing-box compatible subscriptions and injected into the active profile, so local clients rotate across all available protocols.
- **Fire-and-forget provisioning** – User-data scripts handle Docker setup, firewall rules, systemd services, TLS certificates, and health checks directly on the VPS.

## Build From Source

> Requirements: Node.js, pnpm, Go, Wails CLI.

```bash
# install pnpm if needed
npm install -g pnpm

# build the frontend bundle
cd frontend
pnpm install --frozen-lockfile
pnpm build

# build the desktop app
cd ..
go install github.com/wailsapp/wails/v2/cmd/wails@latest
wails build
```

## Using the Cloud Panel

1. Paste a Vultr API key with instance + firewall permissions and save it.
2. Pick a region/plan and deploy – high-memory plans receive all four protocols automatically.
3. After provisioning completes, expand the node row to view protocol details:
   - Shadowsocks port/password and ss:// link
   - Hysteria2 port/password with hysteria2:// link
   - VLESS-Reality UUID, public key, and short ID with vless:// link
   - Trojan port/password with trojan:// link
4. Use *Copy All Links* or per-protocol copy buttons to share credentials.
5. Click *Use Node* to inject the subscription into the current sing-box profile.

Reality parameters (public key + short ID) are stored on the VPS under `/etc/privatedeploy/vless/reality.txt` and surfaced in the UI for clients that need manual configuration.

## Additional Documentation

- `docs/MULTI-PROTOCOL-DESIGN.md` – Deep dive into the multi-protocol deployment flow.
- `docs/DEPLOYMENT-IMPROVEMENTS.md` – Notes on user-data hardening and firewall fixes.
- `docs/GO-NO-GO-CHECKLIST.md` – Release decision checklist with rollback template.

## Quality Gate (Local)

```bash
go test ./...
cd api && go test ./...
cd ../frontend && pnpm run type-check && pnpm run lint:ci
cd .. && python3 e2e/run_cloud_ui_e2e.py
```

The cloud UI regression script always uses an isolated localhost port (`127.0.0.1:4174`) and rejects `7890` to avoid interfering with system proxy settings.

## License

This project is released under the MIT License. See [LICENSE](LICENSE) for details.
