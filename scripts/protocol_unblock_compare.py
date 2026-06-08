#!/usr/bin/env python3
"""Protocol-level unblock/reachability benchmark for PrivateDeploy nodes.

For each node/protocol combo, this script launches an isolated sing-box SOCKS
inbound on a random localhost port (never 7890), then probes target URLs via
curl and reports per-URL success plus aggregate success rates.
"""

from __future__ import annotations

import argparse
import json
import os
import signal
import socket
import statistics
import subprocess
import tempfile
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Dict, Iterable, List


DEFAULT_URLS = [
    "https://www.google.com/generate_204",
    "https://www.youtube.com/",
    "https://www.wikipedia.org/",
    "https://api.openai.com/v1/models",
    "https://www.reddit.com/",
]


@dataclass
class ProtocolTarget:
    protocol: str
    outbound: Dict[str, Any]


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Benchmark unblock reachability via isolated sing-box SOCKS endpoints")
    parser.add_argument("--nodes", default="data/cloud/vultr-nodes.json", help="Path to node records JSON")
    parser.add_argument("--singbox", default="data/sing-box/sing-box", help="Path to sing-box executable")
    parser.add_argument("--timeout", type=int, default=15, help="Per-URL curl timeout seconds")
    parser.add_argument("--urls", default=",".join(DEFAULT_URLS), help="Comma-separated URLs for reachability tests")
    parser.add_argument("--output-dir", default="output/benchmarks", help="Directory for output JSON/TSV")
    return parser.parse_args()


def load_nodes(path: Path) -> List[Dict[str, Any]]:
    raw = json.loads(path.read_text(encoding="utf-8"))
    if isinstance(raw, dict):
        return list(raw.values())
    if isinstance(raw, list):
        return raw
    raise ValueError(f"Unsupported node file format: {path}")


def normalize_ip(node: Dict[str, Any]) -> str:
    return str(node.get("ipv4") or node.get("IPv4") or node.get("ip") or "").strip()


def safe_label(node: Dict[str, Any]) -> str:
    return str(node.get("label") or node.get("Label") or node.get("instanceId") or node.get("id") or "unknown")


def get_instance_id(node: Dict[str, Any]) -> str:
    return str(node.get("instanceId") or node.get("InstanceID") or node.get("id") or "unknown")


def provider_of(node: Dict[str, Any]) -> str:
    return str(node.get("provider") or "unknown")


def urlsafe_base64(value: str) -> str:
    return value.replace("+", "-").replace("/", "_").rstrip("=")


def build_targets(node: Dict[str, Any], ip: str) -> List[ProtocolTarget]:
    targets: List[ProtocolTarget] = []

    ss_port = int(node.get("ssPort") or node.get("port") or 0)
    ss_password = str(node.get("ssPassword") or node.get("password") or "")
    if ss_port > 0 and ss_password:
        targets.append(
            ProtocolTarget(
                protocol="shadowsocks",
                outbound={
                    "type": "shadowsocks",
                    "tag": "bench",
                    "server": ip,
                    "server_port": ss_port,
                    "method": "aes-256-gcm",
                    "password": ss_password,
                },
            )
        )

    hy_port = int(node.get("hysteriaPort") or 0)
    hy_password = str(node.get("hysteriaPassword") or "")
    if hy_port > 0 and hy_password:
        hy_server_name = str(node.get("hysteriaServerName") or "www.bing.com")
        hy_insecure = bool(node.get("hysteriaInsecure", True))
        targets.append(
            ProtocolTarget(
                protocol="hysteria2",
                outbound={
                    "type": "hysteria2",
                    "tag": "bench",
                    "server": ip,
                    "server_port": hy_port,
                    "password": hy_password,
                    "up_mbps": 100,
                    "down_mbps": 100,
                    "tls": {
                        "enabled": True,
                        "server_name": hy_server_name,
                        "insecure": hy_insecure,
                    },
                },
            )
        )

    vless_port = int(node.get("vlessPort") or 0)
    vless_uuid = str(node.get("vlessUUID") or "")
    vless_pk = str(node.get("vlessPublicKey") or "")
    vless_sid = str(node.get("vlessShortId") or "")
    if vless_port > 0 and vless_uuid and vless_pk and vless_sid:
        vless_server_name = str(node.get("vlessServerName") or "www.microsoft.com")
        targets.append(
            ProtocolTarget(
                protocol="vless-reality",
                outbound={
                    "type": "vless",
                    "tag": "bench",
                    "server": ip,
                    "server_port": vless_port,
                    "uuid": vless_uuid,
                    "flow": "xtls-rprx-vision",
                    "tls": {
                        "enabled": True,
                        "server_name": vless_server_name,
                        "utls": {"enabled": True, "fingerprint": "chrome"},
                        "reality": {
                            "enabled": True,
                            "public_key": urlsafe_base64(vless_pk),
                            "short_id": vless_sid,
                        },
                    },
                },
            )
        )

    trojan_port = int(node.get("trojanPort") or 0)
    trojan_password = str(node.get("trojanPassword") or "")
    if trojan_port > 0 and trojan_password:
        trojan_server_name = str(node.get("trojanServerName") or "www.microsoft.com")
        trojan_insecure = bool(node.get("trojanInsecure", True))
        targets.append(
            ProtocolTarget(
                protocol="trojan",
                outbound={
                    "type": "trojan",
                    "tag": "bench",
                    "server": ip,
                    "server_port": trojan_port,
                    "password": trojan_password,
                    "tls": {
                        "enabled": True,
                        "server_name": trojan_server_name,
                        "insecure": trojan_insecure,
                    },
                },
            )
        )

    return targets


def find_free_port() -> int:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
        sock.bind(("127.0.0.1", 0))
        return int(sock.getsockname()[1])


def wait_for_port(port: int, timeout_s: float = 5.0) -> bool:
    deadline = time.time() + timeout_s
    while time.time() < deadline:
        with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
            sock.settimeout(0.5)
            if sock.connect_ex(("127.0.0.1", port)) == 0:
                return True
        time.sleep(0.1)
    return False


def launch_singbox(singbox_path: Path, outbound: Dict[str, Any], socks_port: int, tmpdir: Path) -> subprocess.Popen:
    cfg = {
        "log": {"level": "warn"},
        "inbounds": [
            {
                "type": "socks",
                "tag": "socks-in",
                "listen": "127.0.0.1",
                "listen_port": socks_port,
            }
        ],
        "outbounds": [outbound, {"type": "direct", "tag": "direct"}],
        "route": {"final": "bench"},
    }
    cfg_path = tmpdir / "singbox-unblock.json"
    cfg_path.write_text(json.dumps(cfg, ensure_ascii=False, indent=2), encoding="utf-8")

    stdout_path = tmpdir / "singbox.stdout.log"
    stderr_path = tmpdir / "singbox.stderr.log"
    stdout_file = stdout_path.open("w", encoding="utf-8")
    stderr_file = stderr_path.open("w", encoding="utf-8")

    proc = subprocess.Popen(
        [str(singbox_path), "run", "-c", str(cfg_path)],
        stdout=stdout_file,
        stderr=stderr_file,
        preexec_fn=os.setsid,
    )
    proc._bench_stdout = stdout_file  # type: ignore[attr-defined]
    proc._bench_stderr = stderr_file  # type: ignore[attr-defined]
    return proc


def stop_process(proc: subprocess.Popen) -> None:
    try:
        if proc.poll() is None:
            os.killpg(proc.pid, signal.SIGTERM)
            try:
                proc.wait(timeout=3)
            except subprocess.TimeoutExpired:
                os.killpg(proc.pid, signal.SIGKILL)
                proc.wait(timeout=2)
    finally:
        for attr in ("_bench_stdout", "_bench_stderr"):
            f = getattr(proc, attr, None)
            if f is not None:
                try:
                    f.close()
                except Exception:
                    pass


def probe_url(socks_port: int, url: str, timeout_s: int) -> Dict[str, Any]:
    cmd = [
        "curl",
        "-sS",
        "-L",
        "--socks5-hostname",
        f"127.0.0.1:{socks_port}",
        "--max-time",
        str(timeout_s),
        "-o",
        "/dev/null",
        "-w",
        "%{http_code} %{time_total}",
        url,
    ]
    proc = subprocess.run(cmd, capture_output=True, text=True)
    if proc.returncode != 0:
        return {
            "success": False,
            "http_code": "000",
            "time_total": 0.0,
            "error": proc.stderr.strip() or f"curl_exit_{proc.returncode}",
        }
    parts = proc.stdout.strip().split()
    if len(parts) != 2:
        return {
            "success": False,
            "http_code": "000",
            "time_total": 0.0,
            "error": "invalid_curl_output",
        }
    code = parts[0]
    total = float(parts[1])
    return {
        "success": code != "000",
        "http_code": code,
        "time_total": total,
        "error": "",
    }


def median(values: Iterable[float]) -> float:
    seq = [v for v in values if v > 0]
    if not seq:
        return 0.0
    return float(statistics.median(seq))


def run_unblock_for_target(
    singbox_path: Path,
    node: Dict[str, Any],
    ip: str,
    target: ProtocolTarget,
    urls: List[str],
    timeout_s: int,
) -> Dict[str, Any]:
    provider = provider_of(node)
    label = safe_label(node)
    instance_id = get_instance_id(node)

    socks_port = find_free_port()
    if socks_port == 7890:
        socks_port = find_free_port()

    checks: List[Dict[str, Any]] = []
    with tempfile.TemporaryDirectory(prefix="protocol-unblock-") as temp_dir:
        proc = launch_singbox(singbox_path, target.outbound, socks_port, Path(temp_dir))
        try:
            if not wait_for_port(socks_port, timeout_s=6.0):
                for url in urls:
                    checks.append(
                        {
                            "url": url,
                            "success": False,
                            "http_code": "000",
                            "time_total": 0.0,
                            "error": "socks_not_ready",
                        }
                    )
            else:
                for url in urls:
                    result = probe_url(socks_port, url, timeout_s)
                    result["url"] = url
                    checks.append(result)
        finally:
            stop_process(proc)

    success_rows = [c for c in checks if c["success"]]
    return {
        "provider": provider,
        "instance_id": instance_id,
        "label": label,
        "ip": ip,
        "protocol": target.protocol,
        "total_urls": len(checks),
        "success_urls": len(success_rows),
        "success_rate": (len(success_rows) / len(checks)) if checks else 0.0,
        "median_success_time_s": median(float(c["time_total"]) for c in success_rows),
        "checks": checks,
    }


def write_outputs(rows: List[Dict[str, Any]], output_dir: Path) -> Dict[str, Path]:
    output_dir.mkdir(parents=True, exist_ok=True)
    timestamp = time.strftime("%Y%m%d_%H%M%S")
    json_path = output_dir / f"protocol_unblock_compare_{timestamp}.json"
    tsv_path = output_dir / f"protocol_unblock_compare_{timestamp}.tsv"

    json_path.write_text(json.dumps(rows, ensure_ascii=False, indent=2), encoding="utf-8")

    with tsv_path.open("w", encoding="utf-8") as f:
        f.write("provider\tinstance_id\tlabel\tip\tprotocol\ttotal_urls\tsuccess_urls\tsuccess_rate\tmedian_success_time_s\n")
        for row in rows:
            f.write(
                "\t".join(
                    [
                        str(row.get("provider", "")),
                        str(row.get("instance_id", "")),
                        str(row.get("label", "")),
                        str(row.get("ip", "")),
                        str(row.get("protocol", "")),
                        str(row.get("total_urls", 0)),
                        str(row.get("success_urls", 0)),
                        str(row.get("success_rate", 0)),
                        str(row.get("median_success_time_s", 0)),
                    ]
                )
                + "\n"
            )

    return {"json": json_path, "tsv": tsv_path}


def main() -> int:
    args = parse_args()
    nodes_path = Path(args.nodes)
    if not nodes_path.exists():
        print(f"[protocol-unblock] node file not found: {nodes_path}")
        return 1

    singbox_path = Path(args.singbox)
    if not singbox_path.exists():
        print(f"[protocol-unblock] sing-box not found: {singbox_path}")
        return 1

    urls = [u.strip() for u in args.urls.split(",") if u.strip()]
    if not urls:
        print("[protocol-unblock] no URLs configured")
        return 2

    nodes = load_nodes(nodes_path)
    rows: List[Dict[str, Any]] = []
    for node in nodes:
        ip = normalize_ip(node)
        if not ip:
            continue
        for target in build_targets(node, ip):
            print(f"[protocol-unblock] {safe_label(node)} {target.protocol} ...")
            rows.append(run_unblock_for_target(singbox_path, node, ip, target, urls, args.timeout))

    if not rows:
        print("[protocol-unblock] no benchmarkable protocol records found")
        return 3

    outputs = write_outputs(rows, Path(args.output_dir))
    print(f"[protocol-unblock] JSON: {outputs['json']}")
    print(f"[protocol-unblock] TSV : {outputs['tsv']}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

