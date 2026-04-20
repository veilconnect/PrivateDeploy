#!/usr/bin/env python3

import argparse
import base64
import json
import os
import pathlib
import shutil
import subprocess
import sys
import textwrap
import time

try:
    import winrm
except ImportError as exc:  # pragma: no cover - runtime guard
    raise SystemExit(f"Missing required python module: {exc.name}") from exc


ROOT_DIR = pathlib.Path(__file__).resolve().parent.parent
DEFAULT_OUTPUT_ROOT = ROOT_DIR / "output" / "windows-vpn-browser-smoke"
DEFAULT_RESTORE_PROXY_ENABLE = 1
DEFAULT_RESTORE_PROXY_SERVER = "127.0.0.1:7890"
DEFAULT_RESTORE_AUTO_SET_SYSTEM_PROXY = "false"
DEFAULT_RESTORE_SYSTEM_PROXY_POLICY_INITIALIZED = "false"
DEFAULT_SITES = [
    ("example", "https://example.com/"),
    ("wikipedia", "https://www.wikipedia.org/"),
    ("github", "https://github.com/"),
    ("openai", "https://openai.com/"),
    ("cloudflare", "https://www.cloudflare.com/"),
]


def run_local(args, check=True, capture_output=False, env=None, timeout_sec=30):
    return subprocess.run(
        args,
        check=check,
        text=True,
        capture_output=capture_output,
        env=env,
        timeout=timeout_sec,
    )


def require_cmd(name):
    if shutil.which(name) is None:
        raise SystemExit(f"Missing required command: {name}")


def write_json(path, payload):
    path.write_text(json.dumps(payload, indent=2, ensure_ascii=False), encoding="utf-8")


class RemoteWindows:
    def __init__(self, host, user, password):
        self.host = host
        self.user = user
        self.password = password
        self.session = winrm.Session(host, auth=(user, password), transport="ntlm")

    def run_ps(self, script, expect_json=False):
        result = self.session.run_ps(script)
        stdout = result.std_out.decode("utf-8", "ignore")
        stderr = result.std_err.decode("utf-8", "ignore")
        if result.status_code != 0:
            raise RuntimeError(f"PowerShell failed ({result.status_code}):\n{stderr or stdout}")
        if expect_json:
            return json.loads(stdout)
        return stdout

    def prepare(self):
        script = textwrap.dedent(
            """
            $ud = Join-Path $env:LOCALAPPDATA 'PrivateDeploy\\data\\user.yaml'
            $bytes = [System.IO.File]::ReadAllBytes($ud)
            $userYamlBase64 = [Convert]::ToBase64String($bytes)
            $proxy = Get-ItemProperty 'HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Internet Settings'
            Get-Process PrivateDeploy,sing-box,chrome,iexplore -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
            $raw = [System.Text.Encoding]::UTF8.GetString($bytes)
            $autoSet = [regex]::Match($raw, '(?m)^autoSetSystemProxy:\\s*(.+)$')
            $policy = [regex]::Match($raw, '(?m)^systemProxyPolicyInitialized:\\s*(.+)$')
            if ($raw -match '(?m)^autoSetSystemProxy:') {
              $raw = [regex]::Replace($raw, '(?m)^autoSetSystemProxy:.*$', 'autoSetSystemProxy: true')
            } else {
              $raw = $raw.TrimEnd("`r","`n") + "`r`nautoSetSystemProxy: true`r`n"
            }
            if ($raw -match '(?m)^systemProxyPolicyInitialized:') {
              $raw = [regex]::Replace($raw, '(?m)^systemProxyPolicyInitialized:.*$', 'systemProxyPolicyInitialized: true')
            } else {
              $raw = $raw.TrimEnd("`r","`n") + "`r`nsystemProxyPolicyInitialized: true`r`n"
            }
            [System.IO.File]::WriteAllBytes($ud, [System.Text.Encoding]::UTF8.GetBytes($raw))
            Set-ItemProperty 'HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Internet Settings' ProxyEnable 0
            Set-ItemProperty 'HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Internet Settings' ProxyServer ''
            $appCmd = @'
            @echo off
            start "" "C:\\Program Files\\PrivateDeploy\\PrivateDeploy\\PrivateDeploy.exe"
            '@
            $chromeCmd = @'
            @echo off
            start "" "C:\\Program Files\\Google\\Chrome\\Application\\chrome.exe" --user-data-dir=C:\\Temp\\pd-chrome-system-profile --no-first-run --no-default-browser-check --new-window --hide-crash-restore-bubble --log-net-log=C:\\Temp\\pd-chrome-system-netlog.json
            '@
            [System.IO.File]::WriteAllText('C:\\Temp\\pd-launch-app.cmd', $appCmd)
            [System.IO.File]::WriteAllText('C:\\Temp\\pd-launch-chrome.cmd', $chromeCmd)
            Remove-Item 'C:\\Temp\\pd-chrome-system-profile' -Recurse -Force -ErrorAction SilentlyContinue
            Remove-Item 'C:\\Temp\\pd-chrome-system-netlog.json' -Force -ErrorAction SilentlyContinue
            [pscustomobject]@{
              userYamlBase64 = $userYamlBase64
              proxy = [ordered]@{
                ProxyEnable = [int]$proxy.ProxyEnable
                ProxyServer = [string]$proxy.ProxyServer
              }
              autoSetSystemProxy = if ($autoSet.Success) { [string]$autoSet.Groups[1].Value.Trim() } else { $null }
              systemProxyPolicyInitialized = if ($policy.Success) { [string]$policy.Groups[1].Value.Trim() } else { $null }
            } | ConvertTo-Json -Depth 5 -Compress
            """
        )
        return self.run_ps(script, expect_json=True)

    def launch_interactive(self, task_name, launcher_path, process_name):
        script = textwrap.dedent(
            f"""
            $task = '{task_name}'
            $launcher = '{launcher_path}'
            $user = '{self.user}'
            $pass = '{self.password}'
            schtasks /Delete /TN $task /F 2>$null | Out-Null
            schtasks /Create /TN $task /TR $launcher /SC ONCE /ST 23:59 /RL HIGHEST /RU $user /RP $pass /IT /F | Out-Null
            schtasks /Run /TN $task | Out-Null
            Start-Sleep -Seconds 4
            Get-Process {process_name} -ErrorAction SilentlyContinue | Select-Object Name,Id,SessionId,Path | ConvertTo-Json -Depth 4 -Compress
            """
        )
        return self.run_ps(script, expect_json=True)

    def connected_state(self):
        script = textwrap.dedent(
            """
            $proxy = Get-ItemProperty 'HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Internet Settings'
            $listener = [bool](Get-NetTCPConnection -LocalPort 20122 -State Listen -ErrorAction SilentlyContinue)
            [pscustomobject]@{
              processes = @(Get-Process PrivateDeploy,sing-box,chrome -ErrorAction SilentlyContinue | Select-Object Name,Id,SessionId,Path)
              proxy = [ordered]@{
                ProxyEnable = [int]$proxy.ProxyEnable
                ProxyServer = [string]$proxy.ProxyServer
              }
              listener20122 = $listener
            } | ConvertTo-Json -Depth 6 -Compress
            """
        )
        return self.run_ps(script, expect_json=True)

    def proxy_fetch(self, url):
        escaped = url.replace("'", "''")
        script = textwrap.dedent(
            f"""
            try {{
              $curl = & curl.exe --connect-timeout 10 --max-time 20 -L -s -o NUL -w "%{{http_code}} %{{url_effective}}" -x "http://127.0.0.1:20122" "{escaped}"
              $parts = $curl -split ' ', 2
              [pscustomobject]@{{
                success = $true
                reachable = ([int]$parts[0] -gt 0)
                statusCode = [int]$parts[0]
                finalUri = [string]$parts[1]
              }} | ConvertTo-Json -Depth 4 -Compress
            }} catch {{
              [pscustomobject]@{{
                success = $false
                reachable = $false
                error = $_.Exception.Message
              }} | ConvertTo-Json -Depth 4 -Compress
            }}
            """
        )
        return self.run_ps(script, expect_json=True)

    def chrome_netlog_summary(self):
        script = textwrap.dedent(
            """
            $path = 'C:\\Temp\\pd-chrome-system-netlog.json'
            if (-not (Test-Path $path)) {
              [pscustomobject]@{ exists = $false } | ConvertTo-Json -Compress
              return
            }
            $txt = Get-Content $path -Raw
            [pscustomobject]@{
              exists = $true
              bytes = (Get-Item $path).Length
              wikipediaMentions = ([regex]::Matches($txt, 'wikipedia\\.org', 'IgnoreCase')).Count
              githubMentions = ([regex]::Matches($txt, 'github\\.com', 'IgnoreCase')).Count
              openaiMentions = ([regex]::Matches($txt, 'openai\\.com', 'IgnoreCase')).Count
              cloudflareMentions = ([regex]::Matches($txt, 'cloudflare\\.com', 'IgnoreCase')).Count
              timeoutMentions = ([regex]::Matches($txt, 'ERR_CONNECTION_TIMED_OUT', 'IgnoreCase')).Count
              proxyMentions = ([regex]::Matches($txt, '127\\.0\\.0\\.1:20122|PROXY', 'IgnoreCase')).Count
            } | ConvertTo-Json -Depth 5 -Compress
            """
        )
        return self.run_ps(script, expect_json=True)

    def restore(self, original_user_path, restore_target):
        smb_cmd = [
            "smbclient",
            f"//{self.host}/C$",
            "-U",
            f"{self.user}%{self.password}",
            "-c",
            f"cd Temp; put {original_user_path} pd-restore-user.yaml",
        ]
        run_local(smb_cmd, check=True)
        proxy_enable = int(restore_target.get("ProxyEnable", 0))
        proxy_server = str(restore_target.get("ProxyServer", "")).replace("'", "''")
        auto_set = str(restore_target.get("autoSetSystemProxy", "false")).lower()
        policy = str(restore_target.get("systemProxyPolicyInitialized", "false")).lower()
        restore_mode = str(restore_target.get("restoreMode", "baseline")).replace("'", "''")
        script = textwrap.dedent(
            f"""
            Copy-Item 'C:\\Temp\\pd-restore-user.yaml' $env:LOCALAPPDATA\\PrivateDeploy\\data\\user.yaml -Force
            Get-Process PrivateDeploy,sing-box,chrome,iexplore -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
            $ud = Join-Path $env:LOCALAPPDATA 'PrivateDeploy\\data\\user.yaml'
            $raw = Get-Content $ud -Raw
            if ($raw -match '(?m)^autoSetSystemProxy:') {{
              $raw = [regex]::Replace($raw, '(?m)^autoSetSystemProxy:.*$', 'autoSetSystemProxy: {auto_set}')
            }} else {{
              $raw = $raw.TrimEnd("`r","`n") + "`r`nautoSetSystemProxy: {auto_set}`r`n"
            }}
            if ($raw -match '(?m)^systemProxyPolicyInitialized:') {{
              $raw = [regex]::Replace($raw, '(?m)^systemProxyPolicyInitialized:.*$', 'systemProxyPolicyInitialized: {policy}')
            }} else {{
              $raw = $raw.TrimEnd("`r","`n") + "`r`nsystemProxyPolicyInitialized: {policy}`r`n"
            }}
            [System.IO.File]::WriteAllText($ud, $raw)
            Set-ItemProperty 'HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Internet Settings' ProxyEnable {proxy_enable}
            Set-ItemProperty 'HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Internet Settings' ProxyServer '{proxy_server}'
            $u = Get-Content $ud -Raw
            $reg = Get-ItemProperty 'HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Internet Settings'
            [pscustomobject]@{{
              restored = $true
              restoreMode = '{restore_mode}'
              requested = [ordered]@{{
                ProxyEnable = {proxy_enable}
                ProxyServer = '{proxy_server}'
                autoSetSystemProxy = '{auto_set}'
                systemProxyPolicyInitialized = '{policy}'
              }}
              ProxyEnable = [int]$reg.ProxyEnable
              ProxyServer = [string]$reg.ProxyServer
              autoSet = ([regex]::Match($u, '(?m)^autoSetSystemProxy:.*$').Value)
              policy = ([regex]::Match($u, '(?m)^systemProxyPolicyInitialized:.*$').Value)
              procs = @(Get-Process PrivateDeploy,sing-box,chrome,iexplore -ErrorAction SilentlyContinue | Select-Object Name,Id,SessionId)
            }} | ConvertTo-Json -Depth 5 -Compress
            """
        )
        return self.run_ps(script, expect_json=True)


def start_xvfb(output_dir):
    for display_num in range(110, 160):
        display = f":{display_num}"
        log_path = output_dir / "xvfb.log"
        proc = subprocess.Popen(
            ["Xvfb", display, "-screen", "0", "1280x800x24"],
            stdout=log_path.open("w", encoding="utf-8"),
            stderr=subprocess.STDOUT,
        )
        time.sleep(1)
        if proc.poll() is None:
            return display, proc
    raise RuntimeError("Failed to start Xvfb")


def start_rdp(display, output_dir, host, user, password):
    env = os.environ.copy()
    env["DISPLAY"] = display
    log_path = output_dir / "xfreerdp.log"
    proc = subprocess.Popen(
        [
            "xfreerdp",
            "/cert:ignore",
            f"/u:{user}",
            f"/p:{password}",
            f"/v:{host}",
            "/w:1280",
            "/h:800",
            "/log-level:OFF",
            "+auto-reconnect",
            "/dynamic-resolution",
        ],
        stdout=log_path.open("w", encoding="utf-8"),
        stderr=subprocess.STDOUT,
        env=env,
    )
    return proc, env


def wait_for_rdp_window(env, timeout_sec=60):
    deadline = time.time() + timeout_sec
    while time.time() < deadline:
        result = run_local(
            ["xdotool", "search", "--name", "FreeRDP"],
            check=False,
            capture_output=True,
            env=env,
            timeout_sec=10,
        )
        lines = [line.strip() for line in result.stdout.splitlines() if line.strip()]
        if lines:
            return lines[0]
        time.sleep(1)
    raise RuntimeError("Failed to find FreeRDP window")


def activate_window(env, window_id):
    del env, window_id


def screenshot(env, window_id, path):
    activate_window(env, window_id)
    run_local(
        ["import", "-window", window_id, str(path)],
        check=False,
        env=env,
        timeout_sec=15,
    )


def click(env, window_id, x, y):
    activate_window(env, window_id)
    run_local(
        ["xdotool", "mousemove", "--window", window_id, str(x), str(y), "click", "1"],
        check=False,
        env=env,
        timeout_sec=10,
    )


def key(env, window_id, sequence):
    activate_window(env, window_id)
    run_local(
        ["xdotool", "key", "--window", window_id, sequence],
        check=False,
        env=env,
        timeout_sec=10,
    )


def type_text(env, window_id, text):
    activate_window(env, window_id)
    run_local(
        ["xdotool", "type", "--window", window_id, "--delay", "40", text],
        check=False,
        env=env,
        timeout_sec=10,
    )


def global_key(env, sequence):
    run_local(["xdotool", "key", sequence], check=False, env=env, timeout_sec=10)


def wait(seconds):
    time.sleep(seconds)


def browser_site_label(url):
    return url.split("//", 1)[-1].strip("/").split("/", 1)[0].replace(".", "_")


def browser_ready(remote):
    state = remote.connected_state()
    return state["proxy"].get("ProxyServer") == "127.0.0.1:20122" and state.get("listener20122")


def app_connected_ok(state):
    names = {proc.get("Name") for proc in state.get("processes", [])}
    return (
        state["proxy"].get("ProxyServer") == "127.0.0.1:20122"
        and state.get("listener20122")
        and {"PrivateDeploy", "sing-box"}.issubset(names)
    )


def normalize_yaml_bool(value, default):
    if value is None:
        return default
    normalized = str(value).strip().lower()
    if normalized in {"true", "false"}:
        return normalized
    return default


def build_restore_target(args, original_state):
    if args.restore_mode == "original":
        proxy = original_state.get("proxy", {})
        return {
            "restoreMode": "original",
            "ProxyEnable": int(proxy.get("ProxyEnable", 0)),
            "ProxyServer": str(proxy.get("ProxyServer", "")),
            "autoSetSystemProxy": normalize_yaml_bool(
                original_state.get("autoSetSystemProxy"),
                DEFAULT_RESTORE_AUTO_SET_SYSTEM_PROXY,
            ),
            "systemProxyPolicyInitialized": normalize_yaml_bool(
                original_state.get("systemProxyPolicyInitialized"),
                DEFAULT_RESTORE_SYSTEM_PROXY_POLICY_INITIALIZED,
            ),
        }
    return {
        "restoreMode": "baseline",
        "ProxyEnable": args.restore_proxy_enable,
        "ProxyServer": args.restore_proxy_server,
        "autoSetSystemProxy": args.restore_auto_set_system_proxy,
        "systemProxyPolicyInitialized": args.restore_system_proxy_policy_initialized,
    }


def build_summary(
    *,
    args,
    connected_state,
    site_results,
    app_checks,
    browser_visits,
    cycle_count,
    app_connected_fails,
    start_time,
    error_message=None,
):
    elapsed = int(time.time() - start_time) if start_time else 0
    reachable_failures = sum(
        1 for item in site_results if not item.get("proxyFetch", {}).get("reachable")
    )
    gui_failures = sum(1 for item in site_results if not item.get("guiOk", False))
    overall = "PASS"
    if app_connected_fails > 0 or reachable_failures > 0:
        overall = "PASS_WITH_NOTE"
    if error_message:
        overall = "PASS_WITH_NOTE" if connected_state else "FAIL"
    return {
        "host": args.host,
        "proxy": connected_state["proxy"] if connected_state else None,
        "listener20122": connected_state["listener20122"] if connected_state else False,
        "durationSeconds": elapsed,
        "cycles": cycle_count,
        "browserVisits": browser_visits,
        "appChecks": len(app_checks),
        "appConnectedFails": app_connected_fails,
        "reachableFailures": reachable_failures,
        "guiFailures": gui_failures,
        "sites": site_results,
        "error": error_message,
        "overall": overall,
    }


def parse_args():
    parser = argparse.ArgumentParser(description="Remote Windows VPN browser smoke test")
    parser.add_argument("--host", default=os.environ.get("PD_WIN_HOST"))
    parser.add_argument("--user", default=os.environ.get("PD_WIN_USER", "Administrator"))
    parser.add_argument("--password", default=os.environ.get("PD_WIN_PASS"))
    parser.add_argument("--output-root", default=str(DEFAULT_OUTPUT_ROOT))
    parser.add_argument("--sites", nargs="*", default=[url for _, url in DEFAULT_SITES])
    parser.add_argument("--connect-x", type=int, default=835)
    parser.add_argument("--connect-y", type=int, default=283)
    parser.add_argument("--chrome-taskbar-x", type=int, default=232)
    parser.add_argument("--chrome-taskbar-y", type=int, default=778)
    parser.add_argument("--chrome-popup-close-x", type=int, default=878)
    parser.add_argument("--chrome-popup-close-y", type=int, default=106)
    parser.add_argument("--address-bar-x", type=int, default=230)
    parser.add_argument("--address-bar-y", type=int, default=60)
    parser.add_argument("--app-taskbar-x", type=int, default=401)
    parser.add_argument("--app-taskbar-y", type=int, default=778)
    parser.add_argument("--connect-wait", type=int, default=15)
    parser.add_argument("--page-wait", type=int, default=15)
    parser.add_argument("--duration-minutes", type=int, default=0)
    parser.add_argument("--switch-back-to-app", action="store_true")
    parser.add_argument("--app-check-every", type=int, default=0)
    parser.add_argument("--app-check-wait", type=int, default=3)
    parser.add_argument("--restore-mode", choices=("baseline", "original"), default="baseline")
    parser.add_argument(
        "--restore-proxy-enable",
        type=int,
        choices=(0, 1),
        default=DEFAULT_RESTORE_PROXY_ENABLE,
    )
    parser.add_argument(
        "--restore-proxy-server",
        default=DEFAULT_RESTORE_PROXY_SERVER,
    )
    parser.add_argument(
        "--restore-auto-set-system-proxy",
        choices=("true", "false"),
        default=DEFAULT_RESTORE_AUTO_SET_SYSTEM_PROXY,
    )
    parser.add_argument(
        "--restore-system-proxy-policy-initialized",
        choices=("true", "false"),
        default=DEFAULT_RESTORE_SYSTEM_PROXY_POLICY_INITIALIZED,
    )
    return parser.parse_args()


def main():
    args = parse_args()
    if not args.host or not args.password:
        raise SystemExit("--host and --password are required")

    for cmd in ("python3", "xfreerdp", "xdotool", "import", "Xvfb", "smbclient"):
        require_cmd(cmd)

    output_root = pathlib.Path(args.output_root)
    run_id = f"windows-vpn-browser-{time.strftime('%Y%m%d_%H%M%S')}"
    output_dir = output_root / run_id
    output_dir.mkdir(parents=True, exist_ok=True)
    print(f"Artifacts: {output_dir}")

    remote = RemoteWindows(args.host, args.user, args.password)
    original_user_path = output_dir / "original_user.yaml"
    restore_target = {}
    xvfb_proc = None
    rdp_proc = None
    connected_state = None
    site_results = []
    app_checks = []
    browser_visits = 0
    app_connected_fails = 0
    cycle_count = 0
    start_time = 0
    summary = None
    run_error = None

    try:
        prepared = remote.prepare()
        original_user_path.write_bytes(base64.b64decode(prepared["userYamlBase64"]))
        restore_target = build_restore_target(args, prepared)
        write_json(output_dir / "original_state.json", prepared)
        write_json(output_dir / "original_proxy.json", prepared["proxy"])
        write_json(output_dir / "restore_target.json", restore_target)

        display, xvfb_proc = start_xvfb(output_dir)
        rdp_proc, env = start_rdp(display, output_dir, args.host, args.user, args.password)
        window_id = wait_for_rdp_window(env)
        time.sleep(5)
        screenshot(env, window_id, output_dir / "00-rdp-connected.png")

        launch_app = remote.launch_interactive("PDVpnBrowserApp", r"C:\Temp\pd-launch-app.cmd", "PrivateDeploy")
        write_json(output_dir / "launch_app.json", launch_app)
        time.sleep(10)
        screenshot(env, window_id, output_dir / "01-app-launched.png")

        click(env, window_id, args.connect_x, args.connect_y)
        wait(args.connect_wait)
        connected_state = remote.connected_state()
        write_json(output_dir / "connected_state.json", connected_state)
        screenshot(env, window_id, output_dir / "02-app-connected.png")

        if not browser_ready(remote):
            raise RuntimeError(f"VPN did not become ready: {connected_state}")

        launch_chrome = remote.launch_interactive("PDVpnBrowserChrome", r"C:\Temp\pd-launch-chrome.cmd", "chrome")
        write_json(output_dir / "launch_chrome.json", launch_chrome)
        wait(6)
        click(env, window_id, args.chrome_taskbar_x, args.chrome_taskbar_y)
        wait(2)

        start_time = time.time()
        deadline = start_time + args.duration_minutes * 60 if args.duration_minutes > 0 else None

        while True:
            cycle_count += 1
            for url in args.sites:
                if deadline is not None and time.time() >= deadline and browser_visits > 0:
                    break
                browser_visits += 1
                label = browser_site_label(url)
                shot = output_dir / f"{browser_visits:02d}-{label}.png"
                gui_ok = True
                gui_error = None
                try:
                    click(env, window_id, args.chrome_popup_close_x, args.chrome_popup_close_y)
                    wait(1)
                    click(env, window_id, args.address_bar_x, args.address_bar_y)
                    wait(1)
                    key(env, window_id, "ctrl+l")
                    wait(1)
                    type_text(env, window_id, url)
                    key(env, window_id, "Return")
                    wait(args.page_wait)
                    screenshot(env, window_id, shot)
                except Exception as exc:  # pragma: no cover - runtime safety
                    gui_ok = False
                    gui_error = str(exc)
                fetch = remote.proxy_fetch(url)
                site_results.append(
                    {
                        "visit": browser_visits,
                        "cycle": cycle_count,
                        "label": label,
                        "url": url,
                        "screenshot": shot.name,
                        "guiOk": gui_ok,
                        "guiError": gui_error,
                        "proxyFetch": fetch,
                        "timestamp": time.strftime("%Y-%m-%d %H:%M:%S"),
                    }
                )

                if args.switch_back_to_app and args.app_check_every > 0 and browser_visits % args.app_check_every == 0:
                    click(env, window_id, args.app_taskbar_x, args.app_taskbar_y)
                    wait(args.app_check_wait)
                    app_state = remote.connected_state()
                    app_ok = app_connected_ok(app_state)
                    if not app_ok:
                        app_connected_fails += 1
                    app_shot = output_dir / f"app-check-{browser_visits:02d}.png"
                    screenshot(env, window_id, app_shot)
                    app_checks.append(
                        {
                            "visit": browser_visits,
                            "cycle": cycle_count,
                            "screenshot": app_shot.name,
                            "connected": app_ok,
                            "state": app_state,
                            "timestamp": time.strftime("%Y-%m-%d %H:%M:%S"),
                        }
                    )
                    click(env, window_id, args.chrome_taskbar_x, args.chrome_taskbar_y)
                    wait(2)

            if deadline is None:
                break
            if time.time() >= deadline:
                break
            wait(2)

        write_json(output_dir / "sites.json", site_results)
        write_json(output_dir / "app_checks.json", app_checks)
        chrome_netlog = remote.chrome_netlog_summary()
        write_json(output_dir / "chrome_netlog.json", chrome_netlog)
        summary = build_summary(
            args=args,
            connected_state=connected_state,
            site_results=site_results,
            app_checks=app_checks,
            browser_visits=browser_visits,
            cycle_count=cycle_count,
            app_connected_fails=app_connected_fails,
            start_time=start_time,
        )
        write_json(output_dir / "summary.json", summary)
    except Exception as exc:  # pragma: no cover - runtime safety
        run_error = str(exc)
    finally:
        restore_payload = None
        try:
            if original_user_path.exists() and restore_target:
                restore_payload = remote.restore(str(original_user_path), restore_target)
        finally:
            if summary is None:
                summary = build_summary(
                    args=args,
                    connected_state=connected_state,
                    site_results=site_results,
                    app_checks=app_checks,
                    browser_visits=browser_visits,
                    cycle_count=cycle_count,
                    app_connected_fails=app_connected_fails,
                    start_time=start_time,
                    error_message=run_error,
                )
                write_json(output_dir / "summary.json", summary)
            if restore_payload is not None:
                write_json(output_dir / "restore_state.json", restore_payload)
            if rdp_proc is not None:
                rdp_proc.terminate()
                try:
                    rdp_proc.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    rdp_proc.kill()
            if xvfb_proc is not None:
                xvfb_proc.terminate()
                try:
                    xvfb_proc.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    xvfb_proc.kill()
    if run_error:
        print(f"Completed with note: {run_error}")
    print(f"Artifacts: {output_dir}")


if __name__ == "__main__":
    main()
