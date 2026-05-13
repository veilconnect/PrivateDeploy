# PrivateDeploy 2.0.1 Linux

## Fixes

- Fixed Linux cloud deployments that use the `edge443` port profile. The generated systemd services now grant non-root `sing-box` processes `CAP_NET_BIND_SERVICE`, allowing Hysteria2 and Trojan to bind privileged port `443`.
- Updated the real Vultr GUI smoke flow to select an available plan before clicking Create & Deploy.
- Added smoke diagnostics for failed real deployments, including systemd status, listening ports, firewall status, cloud-init output, and relevant service journals.
- Scrubbed temporary cloud provider config and file-backed secrets from the isolated smoke app directory on exit.

## Verified

- Ubuntu 24.04 DEB upgrade/install on `user@192.168.10.16`: `privatedeploy 2.0.1`.
- Ubuntu 24.04 installed-DEB GUI smoke at 100%, 125%, and 150% scaling.
- Ubuntu 24.04 AppImage GUI smoke at 100%, 125%, and 150% scaling.
- Fedora RPM container install using `dnf install /tmp/privatedeploy-2.0.1-1.x86_64.rpm`.
- Real Vultr deploy smoke in `nrt` with `vc2-1c-1gb`.
- Ports verified open: `22`, `24443`, `8443`, `443`.
- Temporary Vultr smoke instance was destroyed after verification.
- Bundled `sing-box` verified as `1.12.12`.

## Artifacts

- `build/bin/privatedeploy_2.0.1_amd64.deb`
- `build/bin/privatedeploy-2.0.1-1.x86_64.rpm`
- `build/bin/jammy/PrivateDeploy-2.0.1-x86_64.AppImage`

## SHA256

- `privatedeploy_2.0.1_amd64.deb`: `dd9325354e33467910efcb04324223e8d5fa9beb4f0ef96d57d3168933e17a93`
- `privatedeploy-2.0.1-1.x86_64.rpm`: `7f93ec3587d0f46cbfead3a84b3d5f9d5b9e16605e30d92d03128f8cb04f9e1a`
- `PrivateDeploy-2.0.1-x86_64.AppImage`: `92814f7a0606dc2a9754a56d02162dbef9d587211dca4b6ecb5aabe67f5f5f79`
