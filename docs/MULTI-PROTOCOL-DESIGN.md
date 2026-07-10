# Multi-Protocol Deployment Design

PrivateDeploy provisions one VPS with several proxy protocols and keeps the
resulting credentials available to the desktop app, mobile app, and standalone
API. The goal is to let a node remain useful when a network path blocks one
protocol but still allows another.

## Protocol Layout

New full deployments generate these endpoints:

| Protocol | Purpose | Key fields |
| --- | --- | --- |
| Shadowsocks | Lightweight baseline endpoint | `ssPort`, `ssPassword` |
| Hysteria2 | UDP-friendly high-throughput endpoint | `hysteriaPort`, `hysteriaPassword`, `hysteriaServerName`, `hysteriaInsecure` |
| VLESS-Reality | TLS camouflage endpoint | `vlessPort`, `vlessUUID`, `vlessPublicKey`, `vlessShortId`, `vlessServerName` |
| Trojan | TLS-looking fallback endpoint | `trojanPort`, `trojanPassword`, `trojanServerName`, `trojanInsecure` |
| VLESS relay | Plain VLESS upstream for CDN front-ending | `vlessRelayPort`, `vlessUUID` |

Low-memory deployment policies may intentionally fall back to a smaller
Shadowsocks-only layout. Callers must therefore treat every protocol field as
optional and only generate client outbounds for complete credential sets.

## Deployment Flow

1. The UI/API selects provider, region, plan, and optional tuning fields.
2. `bridge/cloud/deploy` normalizes tuning, assigns ports, and generates
   protocol credentials.
3. The provider sends the rendered cloud-init/user-data bundle to the VPS.
4. The VPS installs sing-box, writes systemd units, configures firewall rules,
   and exposes protocol health material.
5. The provider persists a local node record with every credential needed to
   build client subscriptions.
6. The desktop/mobile client converts the node record into sing-box outbounds
   and inserts them into the active profile.

## Port Profiles

`bridge/cloud/deploy.NormalizePortProfile` supports:

- `random`: random high ports for the full protocol set.
- `edge443`: camouflaged edge layout around `443`.
- `edge8443`: camouflaged edge layout around `8443`.

Unknown values map to `random` to keep deployments predictable.

## TLS And Reality Targets

Hysteria2 and Trojan use configurable SNI labels with an insecure/self-signed
mode by default because the VPS does not require the operator to own a domain.

VLESS-Reality is stricter: the server and client must agree on a live TLS
handshake target. `bridge/cloud/deploy.SelectVLESSRealityTarget` probes a vetted
pool and bakes one target into both the server config and the node record.

## Persistence

Node records include protocol passwords, UUIDs, and Reality material, so they
are treated as secrets. Desktop records are sealed by
`bridge/cloud.EncodeRecords` with AES-256-GCM under a local data-encryption key.
Legacy plaintext records can still be read and are re-encrypted on the next
save.

## Client Generation Rules

Clients should follow these rules when building subscriptions:

- Generate IPv4 and IPv6 variants only for usable addresses.
- Skip incomplete protocol records instead of failing the whole node.
- Preserve `hysteriaInsecure` and `trojanInsecure`; managed nodes default to
  permissive TLS while manually imported nodes should keep the user's explicit
  value.
- For CDN-fronted VLESS, include the per-deployment path secret and use
  `vlessRelayPort` as the VPS upstream.

## Primary Code Paths

- `bridge/cloud/deploy/` - port policy, sing-box version pins, cloud-init bundle.
- `bridge/cloud/interface.go` - provider and node record data model.
- `bridge/cloud/providers/vultr/` - Vultr provisioning and recovery.
- `bridge/cloud/providers/digitalocean/` - DigitalOcean provisioning and recovery.
- `frontend/src/stores/cloud/subscriptionApply.ts` - desktop subscription generation.
- `mobile/lib/features/cloud/cloud_node_config_builder.dart` - mobile subscription generation.
