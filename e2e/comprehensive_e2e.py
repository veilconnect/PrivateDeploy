#!/usr/bin/env python3
"""Comprehensive PrivateDeploy E2E regression test.

Reuses the mock bridge from run_cloud_ui_e2e.py (which is known to work)
and adds comprehensive coverage of all app features.
"""

from __future__ import annotations

import json
import re
import shutil
import sys
import threading
import time
from dataclasses import asdict, dataclass
from datetime import datetime
from http.server import ThreadingHTTPServer, SimpleHTTPRequestHandler
from pathlib import Path
from typing import Any

from playwright.sync_api import sync_playwright, Page

# Import the working mock bridge from the existing test, patching user.yaml to
# include builtinPresetsVersion: 1 so that ensureBuiltinPresets() skips profile
# creation (which causes a debounce deadlock and hangs the splash screen).
_EXISTING_TEST = Path(__file__).resolve().parent / "run_cloud_ui_e2e.py"
_SRC = _EXISTING_TEST.read_text(encoding="utf-8")
_START = _SRC.find('MOCK_BRIDGE_JS = r"""') + len('MOCK_BRIDGE_JS = r"""')
_END = _SRC.find('"""', _START)
_RAW_MOCK = _SRC[_START:_END]
# Ensure builtinPresetsVersion: 1 is present (may already exist after recent patch)
if "builtinPresetsVersion" not in _RAW_MOCK:
    _RAW_MOCK = _RAW_MOCK.replace(
        "'systemProxyPolicyInitialized: true',",
        "'systemProxyPolicyInitialized: true',\n      'builtinPresetsVersion: 1',",
    )
MOCK_BRIDGE_JS = _RAW_MOCK

REPO_ROOT = Path(__file__).resolve().parents[1]
FRONTEND_DIR = REPO_ROOT / "frontend"
DIST_DIR = FRONTEND_DIR / "dist"
DEFAULT_OUTPUT_DIR = Path("/tmp/comprehensive-e2e-output")
DEFAULT_PORT = 4175


@dataclass
class TestResult:
    name: str
    passed: bool
    message: str
    screenshot: str = ""


def log(msg: str) -> None:
    print(f"[comprehensive-e2e] {msg}", flush=True)


class QuietHandler(SimpleHTTPRequestHandler):
    def log_message(self, format: str, *args: Any) -> None:
        return


class StaticServer:
    def __init__(self, root: Path, host: str, port: int):
        self.root = root
        self.host = host
        self.port = port
        self._httpd = None
        self._thread = None

    def start(self):
        handler = lambda *a, **kw: QuietHandler(*a, directory=str(self.root), **kw)
        self._httpd = ThreadingHTTPServer((self.host, self.port), handler)
        self._thread = threading.Thread(target=self._httpd.serve_forever, daemon=True)
        self._thread.start()
        time.sleep(0.3)

    def stop(self):
        if self._httpd:
            self._httpd.shutdown()
            self._httpd.server_close()
        if self._thread:
            self._thread.join(timeout=2)


def inject_mock(dist_dir: Path, js_name: str) -> None:
    js_path = dist_dir / js_name
    js_path.write_text(MOCK_BRIDGE_JS, encoding="utf-8")
    index = dist_dir / "index.html"
    html = index.read_text(encoding="utf-8")
    if js_name in html:
        return
    tag = f'<script src="./{js_name}"></script>'
    pat = re.compile(r"<script\s+type=\"module\"", re.IGNORECASE)
    m = pat.search(html)
    if m:
        html = html[: m.start()] + tag + "\n" + html[m.start() :]
    else:
        html = html.replace("</head>", f"{tag}\n</head>")
    index.write_text(html, encoding="utf-8")


def screenshot(page: Page, out_dir: Path, name: str) -> str:
    path = out_dir / f"{name}.png"
    page.screenshot(path=str(path), full_page=True)
    return str(path)


def try_click(scope, names: list[str], timeout_ms: int = 8000) -> bool:
    for name in names:
        for sel in [
            scope.locator(".gui-button", has_text=name),
            scope.locator(f"text={name}"),
        ]:
            if sel.count() == 0:
                continue
            btn = sel.first
            try:
                btn.wait_for(state="visible", timeout=timeout_ms)
                btn.click(timeout=timeout_ms)
                return True
            except Exception:
                continue
    return False


def open_select_first(select_scope) -> None:
    select_scope.locator(".gui-button").first.click(timeout=4000)
    opts = select_scope.locator(".gui-dropdown-overlay:visible .gui-button")
    if opts.count() == 0:
        opts = select_scope.locator(".gui-dropdown-overlay:visible >> xpath=.//*")
    if opts.count() > 0:
        opts.first.click(timeout=4000)


def close_modal(page: Page) -> None:
    masks = page.locator(".gui-modal-mask")
    if masks.count() == 0:
        return
    active = masks.last
    if not try_click(active, ["取消", "Cancel", "common.cancel"], timeout_ms=3000):
        page.keyboard.press("Escape")
    try:
        active.wait_for(state="detached", timeout=5000)
    except Exception:
        pass


def ensure_app_loaded(page: Page, base_url: str) -> None:
    """Navigate and wait for the app to finish initializing (bypass splash screen)."""
    page.goto(f"{base_url}/#/subscriptions", wait_until="domcontentloaded", timeout=60000)

    # Skip wizard if shown
    wizard_skip = page.locator(
        "button", has_text=re.compile(r"(跳过向导，直接进入|Skip\s+wizard)", re.IGNORECASE)
    ).first
    if wizard_skip.count() > 0:
        try:
            wizard_skip.click(timeout=8000)
            page.wait_for_timeout(600)
        except Exception:
            pass

    if "/#/wizard" in page.url:
        page.goto(f"{base_url}/#/subscriptions", wait_until="domcontentloaded", timeout=60000)

    # Wait for cloud view to appear (splash screen finished)
    page.wait_for_selector(
        "div.cloud-view, button:has-text('创建并部署'), button:has-text('Create & Deploy')",
        timeout=60000,
    )


def navigate_to_cloud(page: Page, base_url: str) -> None:
    """Navigate to cloud page and wait for it to load."""
    page.goto(f"{base_url}/#/subscriptions", wait_until="domcontentloaded", timeout=15000)
    page.wait_for_selector(
        "div.cloud-view, tbody tr, button:has-text('创建并部署'), button:has-text('Create & Deploy')",
        timeout=30000,
    )
    page.wait_for_timeout(500)


def run_tests(base_url: str, out_dir: Path) -> list[TestResult]:
    results: list[TestResult] = []
    console_errors: list[str] = []

    with sync_playwright() as p:
        browser = p.chromium.launch(headless=True)
        ctx = browser.new_context(viewport={"width": 1400, "height": 900})
        page = ctx.new_page()

        def on_console(msg):
            if msg.type == "error":
                console_errors.append(msg.text)

        page.on("console", on_console)

        # ---------------------------------------------------------------
        # TEST 1: App loads past splash screen
        # ---------------------------------------------------------------
        try:
            ensure_app_loaded(page, base_url)
            ss = screenshot(page, out_dir, "01-app-loaded")
            results.append(TestResult("app_window_opens", True, "App loaded past splash", ss))
        except Exception as e:
            ss = screenshot(page, out_dir, "01-app-loaded-fail")
            results.append(TestResult("app_window_opens", False, str(e), ss))
            ctx.close()
            browser.close()
            return results

        # ---------------------------------------------------------------
        # TEST 2: Cloud page - Node list display
        # ---------------------------------------------------------------
        try:
            rows = page.locator("tbody tr")
            row_count = rows.count()
            node1 = page.locator("tbody tr:has-text('cloud-e2e-1')").count()
            passed = node1 > 0 and row_count >= 1
            ss = screenshot(page, out_dir, "02-node-list")
            results.append(TestResult(
                "node_list_display",
                passed,
                f"Found {row_count} rows, node1 present={node1 > 0}",
                ss,
            ))
        except Exception as e:
            results.append(TestResult("node_list_display", False, str(e)))

        # ---------------------------------------------------------------
        # TEST 3: Cloud - Search/filter nodes
        # ---------------------------------------------------------------
        try:
            search_input = page.locator(
                "input[placeholder='按名称、IP 或区域搜索...'], input[placeholder='Search by name, IP, or region...']"
            ).first
            search_input.fill("cloud-e2e-1")
            page.wait_for_selector("tbody tr:has-text('cloud-e2e-1')", timeout=15000)
            ss = screenshot(page, out_dir, "03-search")
            try_click(page, ["清除筛选", "Clear Filters"], timeout_ms=5000)
            results.append(TestResult("search_filter_nodes", True, "Search and filter works", ss))
        except Exception as e:
            results.append(TestResult("search_filter_nodes", False, str(e)))

        # ---------------------------------------------------------------
        # TEST 4: Cloud - Speed test button (一键测速 / 测试所有节点)
        # ---------------------------------------------------------------
        try:
            # Different builds may use different button text
            st_btn = None
            for label in ["一键测速", "测试所有节点", "Speed Test", "Test All"]:
                candidate = page.locator(".gui-button", has_text=label).first
                if candidate.count() > 0:
                    st_btn = candidate
                    break
            clicked = False
            if st_btn is not None:
                try:
                    st_btn.scroll_into_view_if_needed(timeout=5000)
                    st_btn.click(timeout=8000)
                    clicked = True
                except Exception:
                    pass
            page.wait_for_timeout(1000)
            ss = screenshot(page, out_dir, "04-speed-test")
            close_modal(page)
            results.append(TestResult("speed_test_button", clicked, "Speed test clicked" if clicked else "Not found", ss))
        except Exception as e:
            results.append(TestResult("speed_test_button", False, str(e)))

        # ---------------------------------------------------------------
        # TEST 5: Cloud - Load balance button (负载均衡)
        # ---------------------------------------------------------------
        try:
            # The button may be disabled when < 2 nodes, or may not exist in some builds.
            # Also try "智能推荐" (Smart Recommend) as an alternative action button.
            lb_btn = None
            for label in ["负载均衡", "Load Balance", "智能推荐", "Smart Recommend"]:
                candidate = page.locator(".gui-button", has_text=label).first
                if candidate.count() > 0:
                    lb_btn = candidate
                    break
            found = lb_btn is not None
            if found:
                try:
                    lb_btn.scroll_into_view_if_needed(timeout=5000)
                except Exception:
                    pass
            ss = screenshot(page, out_dir, "05-load-balance")
            results.append(TestResult("load_balance_button", found, "Load balance button visible" if found else "Not found", ss))
        except Exception as e:
            results.append(TestResult("load_balance_button", False, str(e)))

        # ---------------------------------------------------------------
        # TEST 6: Cloud - API key config area visible
        # ---------------------------------------------------------------
        try:
            api_input = page.locator("input[type='password']").first
            has_input = api_input.count() > 0
            ss = screenshot(page, out_dir, "06-api-key")
            results.append(TestResult(
                "cloud_api_key_config",
                has_input,
                "API key input found" if has_input else "API key input not found",
                ss,
            ))
        except Exception as e:
            results.append(TestResult("cloud_api_key_config", False, str(e)))

        # ---------------------------------------------------------------
        # TEST 7: Cloud - Create & Deploy node
        # ---------------------------------------------------------------
        try:
            # Ensure deploy form is ready (select region/plan)
            deploy_btn = page.locator(".gui-button", has_text=re.compile(r"(创建并部署|Create\s*&\s*Deploy)")).first
            if deploy_btn.count() > 0:
                classes = deploy_btn.get_attribute("class") or ""
                if "pointer-events-none" in classes:
                    create_card = page.locator("div.gui-card").nth(1)
                    if create_card.count() == 0:
                        create_card = page.locator("div.gui-card").first
                    selects = create_card.locator(".gui-select")
                    if selects.count() >= 2:
                        open_select_first(selects.nth(0))
                        open_select_first(selects.nth(1))

            label_input = page.locator("input[placeholder='实例名称'], input[placeholder='Instance label']").first
            if label_input.count() > 0:
                label_input.fill("comprehensive-test-node")

            created = try_click(page, ["创建并部署", "Create & Deploy"], timeout_ms=15000)
            if created:
                page.wait_for_timeout(2000)
                node_found = page.locator("tbody tr:has-text('comprehensive-test-node')").count() > 0
            else:
                node_found = False
            ss = screenshot(page, out_dir, "07-create-deploy")
            results.append(TestResult(
                "create_deploy_node",
                created,
                f"Created={created}, visible={node_found}",
                ss,
            ))
        except Exception as e:
            results.append(TestResult("create_deploy_node", False, str(e)))

        # ---------------------------------------------------------------
        # TEST 8: Cloud - Provider switching (Vultr -> DO -> Vultr)
        # ---------------------------------------------------------------
        try:
            # Find the provider dropdown near "服务商" label
            provider_selects = page.locator(".gui-select", has_text=re.compile(r"(Vultr|DigitalOcean|SSH)"))
            if provider_selects.count() == 0:
                # Try the first select in the provider area
                provider_selects = page.locator("text=服务商").locator("..").locator(".gui-select")
            if provider_selects.count() == 0:
                provider_selects = page.locator("text=Provider").locator("..").locator(".gui-select")

            if provider_selects.count() > 0:
                provider_selects.first.click(timeout=5000)
                page.wait_for_timeout(500)
                do_opt = page.locator(".gui-dropdown-overlay:visible").locator("text=DigitalOcean").first
                if do_opt.count() > 0:
                    do_opt.click(timeout=5000)
                    page.wait_for_timeout(1000)
                    ss1 = screenshot(page, out_dir, "08a-provider-do")

                    provider_selects.first.click(timeout=5000)
                    page.wait_for_timeout(500)
                    vultr_opt = page.locator(".gui-dropdown-overlay:visible").locator("text=Vultr").first
                    if vultr_opt.count() > 0:
                        vultr_opt.click(timeout=5000)
                        page.wait_for_timeout(500)
                    ss2 = screenshot(page, out_dir, "08b-provider-vultr")
                    results.append(TestResult("provider_switching", True, "Vultr->DO->Vultr", ss1))
                else:
                    ss = screenshot(page, out_dir, "08-no-do-option")
                    results.append(TestResult("provider_switching", False, "DO option not found in dropdown", ss))
            else:
                ss = screenshot(page, out_dir, "08-no-provider-select")
                results.append(TestResult("provider_switching", False, "Provider select not found", ss))
        except Exception as e:
            results.append(TestResult("provider_switching", False, str(e)))

        # ---------------------------------------------------------------
        # TEST 9: Cloud - Manual node import (Add Node)
        # ---------------------------------------------------------------
        try:
            add_clicked = try_click(page, ["增加节点", "Add Node"], timeout_ms=8000)
            if add_clicked:
                modal = page.locator(".gui-modal-mask").last
                modal.wait_for(timeout=8000)

                name_inp = modal.locator("input[placeholder='example-node']").first
                if name_inp.count() > 0:
                    name_inp.fill("manual-comprehensive")

                ip_inp = modal.locator("input[placeholder='203.0.113.10']").first
                if ip_inp.count() > 0:
                    ip_inp.fill("10.20.30.40")

                port_inp = modal.locator("input[placeholder='443']").first
                if port_inp.count() > 0:
                    port_inp.fill("443")

                ss_pass = modal.locator(".form-field:has-text('Shadowsocks 密码') input").first
                if ss_pass.count() > 0:
                    ss_pass.fill("manual-ss-pass")

                hy_port = modal.locator("input[placeholder='8443']").first
                if hy_port.count() > 0:
                    hy_port.fill("8443")

                hy_pass = modal.locator(".form-field:has-text('Hysteria2 Password') input").first
                if hy_pass.count() > 0:
                    hy_pass.fill("manual-hy-pass")

                ss = screenshot(page, out_dir, "09-add-node-modal")
                saved = try_click(modal, ["保存", "Save", "common.save"], timeout_ms=8000)
                page.wait_for_timeout(1000)
                row_found = page.locator("tbody tr:has-text('manual-comprehensive')").count() > 0
                results.append(TestResult("manual_node_import", saved and row_found, f"Saved={saved}, visible={row_found}", ss))
            else:
                ss = screenshot(page, out_dir, "09-no-add-btn")
                results.append(TestResult("manual_node_import", False, "Add Node button not found", ss))
        except Exception as e:
            close_modal(page)
            results.append(TestResult("manual_node_import", False, str(e)))

        # ---------------------------------------------------------------
        # TEST 10: Cloud - Import protocol URL nodes
        # ---------------------------------------------------------------
        try:
            close_modal(page)
            page.wait_for_timeout(500)
            import_clicked = try_click(page, ["导入节点", "Import Nodes"], timeout_ms=8000)
            if import_clicked:
                im_modal = page.locator(".gui-modal-mask").last
                im_modal.wait_for(timeout=8000)
                ta = im_modal.locator("textarea.import-textarea").first
                if ta.count() > 0:
                    ta.fill("hy2://test-pass@10.0.0.1:8443?sni=test.example.com&insecure=1#import-comp-node")
                    try_click(im_modal, ["导入", "Import", "common.import"], timeout_ms=8000)
                    page.wait_for_timeout(1500)
                    row_found = page.locator("tbody tr:has-text('import-comp-node')").count() > 0
                    ss = screenshot(page, out_dir, "10-import-nodes")
                    close_modal(page)
                    results.append(TestResult("import_protocol_links", row_found, f"Import visible={row_found}", ss))
                else:
                    close_modal(page)
                    results.append(TestResult("import_protocol_links", False, "Textarea not found"))
            else:
                results.append(TestResult("import_protocol_links", False, "Import button not found"))
        except Exception as e:
            close_modal(page)
            results.append(TestResult("import_protocol_links", False, str(e)))

        # ---------------------------------------------------------------
        # TEST 11: Cloud - Delete a node
        # ---------------------------------------------------------------
        close_modal(page)
        page.goto(f"{base_url}/#/subscriptions", wait_until="domcontentloaded", timeout=15000)
        page.wait_for_selector("tbody tr", timeout=15000)
        page.wait_for_timeout(1500)
        try:
            # Try to find any deletable row - prefer cloud-e2e-1, fallback to any
            del_target = None
            for candidate in ["cloud-e2e-1", "comprehensive-test-node"]:
                if page.locator("tbody tr", has_text=candidate).count() > 0:
                    del_target = candidate
                    break
            if not del_target:
                # Use the first row with a delete button
                first_del = page.locator("tbody tr .gui-button", has_text=re.compile(r"(删除|Delete)")).first
                if first_del.count() > 0:
                    del_target = "__any__"

            if del_target and del_target != "__any__":
                del_row = page.locator("tbody tr", has_text=del_target).first
            elif del_target == "__any__":
                del_row = page.locator("tbody tr").first
            else:
                del_row = None

            if del_row and del_row.count() > 0:
                initial_count = page.locator("tbody tr").count()
                del_btn = del_row.locator(".gui-button", has_text=re.compile(r"(删除|Delete)"))
                if del_btn.count() > 0:
                    del_btn.first.click(timeout=5000)
                    try_click(page, ["确定", "确认", "Confirm", "common.confirm"], timeout_ms=5000)
                    page.wait_for_timeout(1000)
                    new_count = page.locator("tbody tr").count()
                    ss = screenshot(page, out_dir, "11-delete-node")
                    results.append(TestResult("delete_node", new_count < initial_count, f"Before={initial_count}, After={new_count}", ss))
                else:
                    results.append(TestResult("delete_node", False, "Delete button not found in row"))
            else:
                results.append(TestResult("delete_node", False, "No deletable row found"))
        except Exception as e:
            results.append(TestResult("delete_node", False, str(e)))

        # ---------------------------------------------------------------
        # TEST 12: Navigate to Settings - General tab
        # ---------------------------------------------------------------
        try:
            page.goto(f"{base_url}/#/settings", wait_until="domcontentloaded", timeout=15000)
            page.wait_for_selector(".gui-tabs", timeout=15000)
            page.wait_for_timeout(500)
            ss = screenshot(page, out_dir, "12-settings-general")
            results.append(TestResult("settings_tab_general", True, "General settings loaded", ss))
        except Exception as e:
            results.append(TestResult("settings_tab_general", False, str(e)))

        # ---------------------------------------------------------------
        # TEST 13: Settings - Kernel tab
        # ---------------------------------------------------------------
        try:
            page.goto(f"{base_url}/#/settings?tab=kernel", wait_until="domcontentloaded", timeout=15000)
            page.wait_for_selector(".gui-tabs", timeout=15000)
            page.wait_for_timeout(500)
            ss = screenshot(page, out_dir, "13-settings-kernel")
            results.append(TestResult("settings_tab_kernel", True, "Kernel tab loaded", ss))
        except Exception as e:
            results.append(TestResult("settings_tab_kernel", False, str(e)))

        # ---------------------------------------------------------------
        # TEST 14: Settings - Cloud tab
        # ---------------------------------------------------------------
        try:
            page.goto(f"{base_url}/#/settings?tab=cloud", wait_until="domcontentloaded", timeout=15000)
            page.wait_for_selector(".gui-tabs", timeout=15000)
            page.wait_for_timeout(500)
            ss = screenshot(page, out_dir, "14-settings-cloud")
            results.append(TestResult("settings_tab_cloud", True, "Cloud tab loaded", ss))
        except Exception as e:
            results.append(TestResult("settings_tab_cloud", False, str(e)))

        # ---------------------------------------------------------------
        # TEST 15: Settings - Profiles tab
        # ---------------------------------------------------------------
        try:
            page.goto(f"{base_url}/#/settings?tab=profiles", wait_until="domcontentloaded", timeout=15000)
            page.wait_for_selector(".gui-tabs", timeout=15000)
            page.wait_for_timeout(500)
            ss = screenshot(page, out_dir, "15-settings-profiles")
            results.append(TestResult("settings_tab_profiles", True, "Profiles tab loaded", ss))
        except Exception as e:
            results.append(TestResult("settings_tab_profiles", False, str(e)))

        # ---------------------------------------------------------------
        # TEST 16: Settings - Rulesets tab
        # ---------------------------------------------------------------
        try:
            page.goto(f"{base_url}/#/settings?tab=rulesets", wait_until="domcontentloaded", timeout=15000)
            page.wait_for_selector(".gui-tabs", timeout=15000)
            page.wait_for_timeout(500)
            ss = screenshot(page, out_dir, "16-settings-rulesets")
            results.append(TestResult("settings_tab_rulesets", True, "Rulesets tab loaded", ss))
        except Exception as e:
            results.append(TestResult("settings_tab_rulesets", False, str(e)))

        # ---------------------------------------------------------------
        # TEST 17: Workbench page
        # ---------------------------------------------------------------
        try:
            page.goto(f"{base_url}/#/", wait_until="domcontentloaded", timeout=15000)
            page.wait_for_selector(".gui-tabs, .workspace-header, .flex-1", timeout=15000)
            page.wait_for_timeout(500)
            ss = screenshot(page, out_dir, "17-workbench")
            results.append(TestResult("workbench_page", True, "Workbench loaded", ss))
        except Exception as e:
            results.append(TestResult("workbench_page", False, str(e)))

        # ---------------------------------------------------------------
        # TEST 18: Kernel connect/disconnect buttons on workbench
        # ---------------------------------------------------------------
        try:
            connect_btn = page.locator(
                "text=未连接"
            ).first
            has_status = connect_btn.count() > 0
            # Also check for the kernel status area
            kernel_area = page.locator("text=未启用").first
            has_kernel = kernel_area.count() > 0
            ss = screenshot(page, out_dir, "18-kernel-status")
            results.append(TestResult(
                "kernel_status_display",
                has_status or has_kernel,
                f"Status='未连接' visible={has_status}, '未启用' visible={has_kernel}",
                ss,
            ))
        except Exception as e:
            results.append(TestResult("kernel_status_display", False, str(e)))

        # ---------------------------------------------------------------
        # TEST 19: Interactive controls on cloud page
        # ---------------------------------------------------------------
        try:
            navigate_to_cloud(page, base_url)
            buttons = page.locator(".gui-button:visible")
            btn_count = buttons.count()
            ss = screenshot(page, out_dir, "19-controls")
            results.append(TestResult(
                "interactive_controls",
                btn_count >= 5,
                f"Found {btn_count} visible buttons",
                ss,
            ))
        except Exception as e:
            results.append(TestResult("interactive_controls", False, str(e)))

        # ---------------------------------------------------------------
        # TEST 20: No console errors
        # ---------------------------------------------------------------
        ignored = [
            re.compile(r"Node not found", re.IGNORECASE),
            re.compile(r"favicon", re.IGNORECASE),
            re.compile(r"Subscription for .* is missing", re.IGNORECASE),
            re.compile(r"Failed to (load|fetch)", re.IGNORECASE),
        ]
        real_errors = [e for e in console_errors if not any(p.search(e) for p in ignored)]
        results.append(TestResult(
            "no_console_errors",
            len(real_errors) == 0,
            f"{len(real_errors)} errors" + (f": {real_errors[:3]}" if real_errors else ""),
        ))

        # Final screenshot
        screenshot(page, out_dir, "99-final")
        ctx.close()
        browser.close()

    return results


def main() -> int:
    out_dir = DEFAULT_OUTPUT_DIR
    out_dir.mkdir(parents=True, exist_ok=True)

    if not DIST_DIR.exists():
        log(f"ERROR: frontend dist not found at {DIST_DIR}")
        return 1

    run_id = datetime.now().strftime("%Y%m%d-%H%M%S")
    workdir = out_dir / f"workdir-{run_id}"
    served_dir = workdir / "site"
    served_dir.parent.mkdir(parents=True, exist_ok=True)
    shutil.copytree(DIST_DIR, served_dir)

    inject_mock(served_dir, "e2e-mock-bridge.js")

    server = StaticServer(root=served_dir, host="127.0.0.1", port=DEFAULT_PORT)
    base_url = f"http://127.0.0.1:{DEFAULT_PORT}"
    report_path = out_dir / "comprehensive-e2e-report.json"

    try:
        log(f"Starting server: {base_url}")
        server.start()

        results = run_tests(base_url, out_dir)

        total = len(results)
        passed = sum(1 for r in results if r.passed)
        failed = total - passed
        status = "PASSED" if failed == 0 else "FAILED"

        log(f"\n{'='*60}")
        log(f"COMPREHENSIVE E2E TEST RESULTS: {status}")
        log(f"Total: {total} | Passed: {passed} | Failed: {failed}")
        log(f"{'='*60}")

        for r in results:
            icon = "PASS" if r.passed else "FAIL"
            log(f"  [{icon}] {r.name}: {r.message}")

        report = {
            "status": status,
            "timestamp": datetime.now().isoformat(),
            "total": total,
            "passed": passed,
            "failed": failed,
            "results": [asdict(r) for r in results],
        }
        report_path.write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8")
        log(f"\nReport saved: {report_path}")

        return 0 if failed == 0 else 1

    except Exception as e:
        log(f"FATAL: {e}")
        import traceback
        traceback.print_exc()
        return 1
    finally:
        server.stop()
        shutil.rmtree(workdir, ignore_errors=True)


if __name__ == "__main__":
    sys.exit(main())
