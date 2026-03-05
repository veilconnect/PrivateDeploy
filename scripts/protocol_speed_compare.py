#!/usr/bin/env python3
"""Protocol-level benchmark for PrivateDeploy nodes.

This script measures per-protocol proxy performance by launching an isolated
sing-box process on ephemeral localhost ports (never 7890), then executing a
curl download through that local SOCKS endpoint.
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
from typing import Any, Dict, Iterable, List, Optional


DEFAULT_URL = "https://speed.cloudflare.com/__down?bytes=2000000"
DEFAULT_TIMEOUT = 20


@dataclass
class ProbeSample:
    protocol: str
    instance_id: str
    label: str
    ip: str
    success: bool
    error: str
    connect_s: float
    ttfb_s: float
    total_s: float
    speed_mbps: float


@dataclass
class ProtocolTarget:
    protocol: str
    outbound: Dict[str, Any]


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Benchmark node protocols via isolated sing-box SOCKS endpoints")
    parser.add_argument("--nodes", default="data/cloud/vultr-nodes.json", help="Path to node records JSON")
    parser.add_argument("--singbox", default="data/sing-box/sing-box", help="Path to sing-box executable")
    parser.add_argument("--rounds", type=int, default=3, help="Rounds per protocol")
    parser.add_argument("--url", default=DEFAULT_URL, help="Download URL used for speed test")
    parser.add_argument("--timeout", type=int, default=DEFAULT_TIMEOUT, help="Per-round curl timeout seconds")
    parser.add_argument("--output-dir", default="output/benchmarks", help="Directory for output JSON/TSV")
    parser.add_argument("--label-filter", default="", help="Only include nodes whose label contains this text")
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
                        "server_name": "www.microsoft.com",
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
    cfg_path = tmpdir / "singbox-bench.json"
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
    proc._bench_stdout_path = stdout_path  # type: ignore[attr-defined]
    proc._bench_stderr_path = stderr_path  # type: ignore[attr-defined]
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


def run_curl_probe(socks_port: int, url: str, timeout_s: int) -> ProbeSample:
    output_format = "%{time_connect} %{time_starttransfer} %{time_total} %{speed_download}"
    cmd = [
        "curl",
        "-sS",
        "--socks5-hostname",
        f"127.0.0.1:{socks_port}",
        "--max-time",
        str(timeout_s),
        "-o",
        "/dev/null",
        "-w",
        output_format,
        url,
    ]

    start = time.time()
    proc = subprocess.run(cmd, capture_output=True, text=True)
    _elapsed = time.time() - start

    if proc.returncode != 0:
        return ProbeSample(
            protocol="",
            instance_id="",
            label="",
            ip="",
            success=False,
            error=(proc.stderr.strip() or f"curl_exit_{proc.returncode}"),
            connect_s=0.0,
            ttfb_s=0.0,
            total_s=0.0,
            speed_mbps=0.0,
        )

    parts = proc.stdout.strip().split()
    if len(parts) != 4:
        return ProbeSample(
            protocol="",
            instance_id="",
            label="",
            ip="",
            success=False,
            error="invalid_curl_output",
            connect_s=0.0,
            ttfb_s=0.0,
            total_s=0.0,
            speed_mbps=0.0,
        )

    connect_s = float(parts[0])
    ttfb_s = float(parts[1])
    total_s = float(parts[2])
    speed_bytes_s = float(parts[3])
    speed_mbps = speed_bytes_s * 8 / 1_000_000

    return ProbeSample(
        protocol="",
        instance_id="",
        label="",
        ip="",
        success=True,
        error="",
        connect_s=connect_s,
        ttfb_s=ttfb_s,
        total_s=total_s,
        speed_mbps=speed_mbps,
    )


def median(values: Iterable[float]) -> float:
    seq = [v for v in values if v > 0]
    if not seq:
        return 0.0
    return float(statistics.median(seq))


def benchmark_protocol(
    singbox_path: Path,
    node: Dict[str, Any],
    ip: str,
    target: ProtocolTarget,
    rounds: int,
    url: str,
    timeout_s: int,
) -> Dict[str, Any]:
    samples: List[ProbeSample] = []
    instance_id = get_instance_id(node)
    label = safe_label(node)

    for _ in range(rounds):
        socks_port = find_free_port()
        if socks_port == 7890:
            socks_port = find_free_port()

        with tempfile.TemporaryDirectory(prefix="protocol-bench-") as temp_dir:
            tmpdir = Path(temp_dir)
            proc = launch_singbox(singbox_path, target.outbound, socks_port, tmpdir)
            try:
                if not wait_for_port(socks_port, timeout_s=5.0):
                    samples.append(
                        ProbeSample(
                            protocol=target.protocol,
                            instance_id=instance_id,
                            label=label,
                            ip=ip,
                            success=False,
                            error="socks_not_ready",
                            connect_s=0.0,
                            ttfb_s=0.0,
                            total_s=0.0,
                            speed_mbps=0.0,
                        )
                    )
                    continue

                sample = run_curl_probe(socks_port, url, timeout_s)
                sample.protocol = target.protocol
                sample.instance_id = instance_id
                sample.label = label
                sample.ip = ip
                samples.append(sample)
            finally:
                stop_process(proc)

    successes = [s for s in samples if s.success]
    return {
        "instance_id": instance_id,
        "label": label,
        "ip": ip,
        "protocol": target.protocol,
        "rounds": rounds,
        "success_rounds": len(successes),
        "status": "ok" if successes else "error",
        "median_connect_s": median(s.connect_s for s in successes),
        "median_ttfb_s": median(s.ttfb_s for s in successes),
        "median_total_s": median(s.total_s for s in successes),
        "median_speed_mbps": median(s.speed_mbps for s in successes),
        "errors": [s.error for s in samples if not s.success],
    }


def write_outputs(results: List[Dict[str, Any]], output_dir: Path) -> None:
    output_dir.mkdir(parents=True, exist_ok=True)
    timestamp = time.strftime("%Y%m%d_%H%M%S")

    json_path = output_dir / f"protocol_speed_compare_{timestamp}.json"
    json_path.write_text(json.dumps(results, ensure_ascii=False, indent=2), encoding="utf-8")

    tsv_path = output_dir / f"protocol_speed_compare_{timestamp}.tsv"
    headers = [
        "instance_id",
        "label",
        "ip",
        "protocol",
        "status",
        "rounds",
        "success_rounds",
        "median_connect_s",
        "median_ttfb_s",
        "median_total_s",
        "median_speed_mbps",
        "errors",
    ]

    with tsv_path.open("w", encoding="utf-8") as f:
        f.write("\t".join(headers) + "\n")
        for row in results:
            values = [
                str(row.get("instance_id", "")),
                str(row.get("label", "")),
                str(row.get("ip", "")),
                str(row.get("protocol", "")),
                str(row.get("status", "")),
                str(row.get("rounds", "")),
                str(row.get("success_rounds", "")),
                str(row.get("median_connect_s", "")),
                str(row.get("median_ttfb_s", "")),
                str(row.get("median_total_s", "")),
                str(row.get("median_speed_mbps", "")),
                "|".join(row.get("errors", [])),
            ]
            f.write("\t".join(values) + "\n")

    print(f"[protocol-benchmark] JSON: {json_path}")
    print(f"[protocol-benchmark] TSV : {tsv_path}")


def main() -> int:
    args = parse_args()

    nodes_path = Path(args.nodes)
    if not nodes_path.exists():
        print(f"[protocol-benchmark] node file not found: {nodes_path}")
        return 1

    singbox_path = Path(args.singbox)
    if not singbox_path.exists():
        candidates = [
            Path("build/bin/data/sing-box/sing-box"),
            Path("data/sing-box/sing-box-latest"),
            Path("build/bin/data/sing-box/sing-box-latest"),
        ]
        for candidate in candidates:
            if candidate.exists():
                singbox_path = candidate
                break
        else:
            print(f"[protocol-benchmark] sing-box not found: {singbox_path}")
            return 1

    nodes = load_nodes(nodes_path)
    if args.label_filter:
        nodes = [n for n in nodes if args.label_filter.lower() in safe_label(n).lower()]

    results: List[Dict[str, Any]] = []
    for node in nodes:
        ip = normalize_ip(node)
        if not ip:
            continue

        targets = build_targets(node, ip)
        for target in targets:
            print(f"[protocol-benchmark] {safe_label(node)} {target.protocol} ...")
            row = benchmark_protocol(
                singbox_path=singbox_path,
                node=node,
                ip=ip,
                target=target,
                rounds=args.rounds,
                url=args.url,
                timeout_s=args.timeout,
            )
            results.append(row)

    if not results:
        print("[protocol-benchmark] no benchmarkable protocol records found")
        return 2

    write_outputs(results, Path(args.output_dir))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
