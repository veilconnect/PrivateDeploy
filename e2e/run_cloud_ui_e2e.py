#!/usr/bin/env python3
"""Cloud page full interactive regression with a mocked Wails bridge.

This script is designed for local functional regression without touching live cloud APIs
or system proxy settings. It serves a temporary frontend build on 127.0.0.1 and runs a
full click-through flow on the Deploy/Cloud page.
"""

from __future__ import annotations

import argparse
import json
import random
import re
import shutil
import subprocess
import sys
import threading
import time
from dataclasses import asdict, dataclass
from datetime import datetime
from http.server import ThreadingHTTPServer, SimpleHTTPRequestHandler
from pathlib import Path
from typing import Any

from playwright.sync_api import Error as PlaywrightError
from playwright.sync_api import TimeoutError as PlaywrightTimeoutError
from playwright.sync_api import sync_playwright


REPO_ROOT = Path(__file__).resolve().parents[1]
FRONTEND_DIR = REPO_ROOT / "frontend"
DIST_DIR = FRONTEND_DIR / "dist"
DEFAULT_OUTPUT_DIR = REPO_ROOT / "output" / "playwright"
DEFAULT_PORT = 4174
IGNORED_CONSOLE_ERROR_PATTERNS = [
    re.compile(r"Node not found for connectivity test", re.IGNORECASE),
]


MOCK_BRIDGE_JS = r"""
(() => {
  const clone = (value) => JSON.parse(JSON.stringify(value));
  const ok = (data = '') => ({
    flag: true,
    data: typeof data === 'string' ? data : JSON.stringify(data),
  });
  const fail = (message = 'mock error') => ({ flag: false, data: String(message) });
  const nowISO = () => new Date().toISOString();
  const randomSuffix = () => Math.random().toString(36).slice(2, 8);
  const normPath = (input) =>
    String(input || '')
      .replace(/\\/g, '/')
      .replace(/^\/+/, '')
      .replace(/^\.\//, '')
      .replace(/\/+/g, '/');

  const state = {
    provider: 'vultr',
    providerMeta: {
      vultr: { name: 'vultr', displayName: 'Vultr' },
      digitalocean: { name: 'digitalocean', displayName: 'DigitalOcean' },
      ssh: { name: 'ssh', displayName: 'SSH' },
    },
    configs: {
      vultr: {
        provider: 'vultr',
        apiKey: 'mock-vultr-key',
        defaultRegion: 'nrt',
        defaultPlan: 'vc2-1c-1gb',
        extra: {},
      },
      digitalocean: {
        provider: 'digitalocean',
        apiKey: 'mock-do-key',
        defaultRegion: 'sgp1',
        defaultPlan: 's-1vcpu-1gb',
        extra: {},
      },
      ssh: {
        provider: 'ssh',
        apiKey: '',
        defaultRegion: '',
        defaultPlan: '',
        extra: {},
      },
    },
    regions: {
      vultr: [
        { id: 'nrt', city: 'Tokyo', country: 'JP' },
        { id: 'lax', city: 'Los Angeles', country: 'US' },
      ],
      digitalocean: [
        { id: 'sgp1', city: 'Singapore 1', country: 'SG' },
        { id: 'nyc1', city: 'New York 1', country: 'US' },
      ],
      ssh: [],
    },
    plans: {
      vultr: [
        { id: 'vc2-1c-1gb', description: 'Vultr 1C1G', ram: 1024, vcpus: 1, disk: 25, bandwidth: 1000, monthlyCost: 6.0 },
        { id: 'vc2-2c-2gb', description: 'Vultr 2C2G', ram: 2048, vcpus: 2, disk: 55, bandwidth: 2000, monthlyCost: 12.0 },
      ],
      digitalocean: [
        { id: 's-1vcpu-1gb', description: 'DO Basic 1G', ram: 1024, vcpus: 1, disk: 25, bandwidth: 1000, monthlyCost: 6.0 },
        { id: 's-2vcpu-2gb', description: 'DO Basic 2G', ram: 2048, vcpus: 2, disk: 50, bandwidth: 2000, monthlyCost: 12.0 },
      ],
      ssh: [],
    },
    availability: {
      vultr: {
        nrt: ['vc2-1c-1gb', 'vc2-2c-2gb'],
        lax: ['vc2-1c-1gb'],
      },
      digitalocean: {
        sgp1: ['s-1vcpu-1gb', 's-2vcpu-2gb'],
        nyc1: ['s-1vcpu-1gb'],
      },
      ssh: {},
    },
    nodes: {
      vultr: [
        {
          instanceId: 'cloud-e2e-1',
          provider: 'vultr',
          label: 'cloud-e2e-1',
          status: 'running',
          region: 'nrt',
          plan: 'vc2-1c-1gb',
          ipv4: '198.51.100.10',
          ipv6: '',
          ssPort: 443,
          ssPassword: 'seed-ss-pass',
          hysteriaPort: 8443,
          hysteriaPassword: 'seed-hy-pass',
          hysteriaInsecure: true,
          vlessPort: 443,
          vlessUUID: '11111111-1111-1111-1111-111111111111',
          vlessPublicKey: 'h7gA4mXwIKp2Pz8iQfH6Vav8X4nYV+FJ3G8f4vPQ6zQ=',
          vlessShortId: 'ab12cd34',
          trojanPort: 443,
          trojanPassword: 'seed-trojan-pass',
          trojanInsecure: true,
          createdAt: nowISO(),
        },
      ],
      digitalocean: [
        {
          instanceId: 'cloud-do-e2e-1',
          provider: 'digitalocean',
          label: 'do-e2e-1',
          status: 'running',
          region: 'sgp1',
          plan: 's-1vcpu-1gb',
          ipv4: '198.51.100.11',
          ipv6: '',
          ssPort: 443,
          ssPassword: 'do-ss-pass',
          hysteriaPort: 8443,
          hysteriaPassword: 'do-hy-pass',
          hysteriaInsecure: true,
          trojanPort: 443,
          trojanPassword: 'do-trojan-pass',
          trojanInsecure: true,
          createdAt: nowISO(),
        },
      ],
      ssh: [],
    },
    cloudCounter: 2,
    files: {},
    runtimeEvents: {},
    clipboard: '',
    logs: [],
  };

  const log = (...args) => {
    const line = args
      .map((v) => {
        try {
          return typeof v === 'string' ? v : JSON.stringify(v);
        } catch {
          return String(v);
        }
      })
      .join(' ');
    state.logs.push(line);
  };

  const seedFiles = () => {
    state.files['data/user.yaml'] = [
      'lang: zh',
      'autoStartKernel: false',
      'autoSetSystemProxy: false',
      'systemProxyPolicyInitialized: true',
      'builtinPresetsVersion: 1',
      'pages:',
      '  - Overview',
      '  - Profiles',
      '  - Deploy',
      '',
    ].join('\n');
    state.files['data/profiles.yaml'] = '[]\n';
    state.files['data/subscribes.yaml'] = '[]\n';
    state.files['data/rulesets.yaml'] = '[]\n';
    state.files['data/plugins.yaml'] = '[]\n';
    state.files['data/scheduledtasks.yaml'] = '[]\n';
    state.files['data/cloud/manual-nodes.json'] = '[]\n';
    state.files['data/.cache/plugin-list.json'] = '[]';
    state.files['data/.cache/ruleset-list.json'] = JSON.stringify({ geosite: '', geoip: '', list: [] });
    state.files['data/sing-box/pid.txt'] = '-1';
    state.files['data/sing-box/config.json'] = JSON.stringify(
      {
        inbounds: [
          {
            id: 'mixed-in',
            tag: 'mixed-in',
            type: 'mixed',
            enable: true,
            mixed: {
              listen: {
                listen: '127.0.0.1',
                listen_port: 7891,
              },
            },
          },
        ],
        outbounds: [],
        route: {
          final: 'direct',
          auto_detect_interface: true,
          default_interface: '',
          rules: [],
        },
        dns: {
          servers: [],
          rules: [],
        },
        experimental: {
          clash_api: {
            external_controller: '127.0.0.1:20123',
            secret: '',
          },
        },
      },
      null,
      2,
    );
  };
  seedFiles();

  const listDirEntries = (path) => {
    const p = normPath(path).replace(/\/$/, '');
    const prefix = p ? `${p}/` : '';
    const entries = new Map();

    Object.entries(state.files).forEach(([filePath, content]) => {
      const normalized = normPath(filePath);
      if (!normalized.startsWith(prefix)) return;
      const rest = normalized.slice(prefix.length);
      if (!rest) return;
      const first = rest.split('/')[0];
      if (!first) return;
      const isDir = rest.includes('/');
      if (!entries.has(first)) {
        entries.set(first, { name: first, size: isDir ? 0 : String(content || '').length, isDir });
      } else if (isDir) {
        const existing = entries.get(first);
        existing.isDir = true;
        existing.size = 0;
      }
    });

    return Array.from(entries.values());
  };

  const getCurrentProvider = () => state.provider;
  const getCurrentProviderNodes = () => state.nodes[getCurrentProvider()] || [];
  const getCurrentProviderMeta = () => state.providerMeta[getCurrentProvider()] || state.providerMeta.vultr;

  const makeNode = (options, provider) => {
    const suffix = state.cloudCounter++;
    const idPrefix = provider === 'digitalocean' ? 'cloud-do-' : `cloud-${provider}-`;
    const instanceId = `${idPrefix}${suffix}`;
    const region = options.region || (state.regions[provider]?.[0]?.id || 'nrt');
    const plan = options.plan || (state.plans[provider]?.[0]?.id || 'vc2-1c-1gb');
    const label = options.label || `${provider}-node-${suffix}`;

    return {
      instanceId,
      provider,
      label,
      status: 'running',
      region,
      plan,
      ipv4: `198.51.100.${20 + suffix}`,
      ipv6: '',
      ssPort: 443,
      ssPassword: `ss-pass-${suffix}`,
      hysteriaPort: 8443,
      hysteriaPassword: `hy-pass-${suffix}`,
      hysteriaInsecure: true,
      vlessPort: 443,
      vlessUUID: `11111111-1111-1111-1111-${String(suffix).padStart(12, '0')}`.slice(0, 36),
      vlessPublicKey: 'h7gA4mXwIKp2Pz8iQfH6Vav8X4nYV+FJ3G8f4vPQ6zQ=',
      vlessShortId: `${suffix}`,
      trojanPort: 443,
      trojanPassword: `trojan-pass-${suffix}`,
      trojanInsecure: true,
      createdAt: nowISO(),
    };
  };

  const appBridge = {
    // App basics
    GetEnv: async () => ({
      appName: 'PrivateDeploy',
      appVersion: 'e2e-mock',
      basePath: '/tmp/privatedeploy-e2e',
      os: 'linux',
      arch: 'amd64',
    }),
    IsStartup: async () => false,
    RestartApp: async () => ok(''),
    ExitApp: async () => ok(''),
    ShowMainWindow: async () => ok(''),
    UpdateTray: async () => ok(''),
    UpdateTrayMenus: async () => ok(''),

    // Generic I/O
    ReadFile: async (path) => {
      const p = normPath(path);
      if (Object.prototype.hasOwnProperty.call(state.files, p)) {
        return ok(state.files[p]);
      }
      if (p.endsWith('.yaml') || p.endsWith('.yml') || p.endsWith('.json') || p.endsWith('.txt')) {
        return ok('');
      }
      return ok('');
    },
    WriteFile: async (path, content) => {
      const p = normPath(path);
      state.files[p] = typeof content === 'string' ? content : String(content ?? '');
      return ok('');
    },
    RemoveFile: async (path) => {
      const p = normPath(path);
      delete state.files[p];
      return ok('');
    },
    MoveFile: async (source, target) => {
      const s = normPath(source);
      const t = normPath(target);
      const content = state.files[s] ?? '';
      delete state.files[s];
      state.files[t] = content;
      return ok('');
    },
    CopyFile: async (source, target) => {
      const s = normPath(source);
      const t = normPath(target);
      state.files[t] = state.files[s] ?? '';
      return ok('');
    },
    FileExists: async (path) => {
      const p = normPath(path);
      return ok(Object.prototype.hasOwnProperty.call(state.files, p) ? 'true' : 'false');
    },
    AbsolutePath: async (path) => ok(`/tmp/privatedeploy-e2e/${normPath(path)}`),
    MakeDir: async () => ok(''),
    ReadDir: async (path) => {
      const entries = listDirEntries(path)
        .map((entry) => `${entry.name},${entry.size},${entry.isDir ? 'true' : 'false'}`)
        .join('|');
      return ok(entries);
    },
    UnzipZIPFile: async () => ok(''),
    UnzipGZFile: async () => ok(''),
    UnzipTarGZFile: async () => ok(''),

    // Networking helpers
    Requests: async () => ({
      flag: true,
      status: 200,
      headers: { 'Content-Type': ['application/json'] },
      body: '{}',
    }),
    Download: async () => ({
      flag: true,
      status: 200,
      headers: { 'Content-Type': ['application/octet-stream'] },
      body: '',
    }),
    Upload: async () => ({
      flag: true,
      status: 200,
      headers: { 'Content-Type': ['application/json'] },
      body: '{}',
    }),

    // Cloud config/provider
    GetCloudConfig: async () => ok(state.configs[getCurrentProvider()] || state.configs.vultr),
    GetCloudConfigTyped: async () => clone(state.configs[getCurrentProvider()] || state.configs.vultr),
    SaveCloudConfig: async (payload) => {
      try {
        const parsed = JSON.parse(payload || '{}');
        const provider = parsed.provider || getCurrentProvider();
        state.configs[provider] = {
          provider,
          apiKey: String(parsed.apiKey || ''),
          defaultRegion: String(parsed.defaultRegion || ''),
          defaultPlan: String(parsed.defaultPlan || ''),
          extra: typeof parsed.extra === 'object' && parsed.extra ? parsed.extra : {},
        };
      } catch (error) {
        return fail(String(error));
      }
      return ok('saved');
    },
    SaveCloudConfigTyped: async (payload) => {
      const parsed = payload && typeof payload === 'object' ? payload : {};
      const provider = parsed.provider || getCurrentProvider();
      const existing = state.configs[provider] || {};
      state.configs[provider] = {
        provider,
        apiKey: String(parsed.apiKey ?? existing.apiKey ?? ''),
        defaultRegion: String(parsed.defaultRegion ?? existing.defaultRegion ?? ''),
        defaultPlan: String(parsed.defaultPlan ?? existing.defaultPlan ?? ''),
        extra: typeof parsed.extra === 'object' && parsed.extra ? parsed.extra : (existing.extra || {}),
      };
    },
    ListCloudProviders: async () => ok(Object.values(state.providerMeta)),
    ListCloudProvidersTyped: async () => clone(Object.values(state.providerMeta)),
    GetCloudProvider: async () => ok(getCurrentProviderMeta()),
    GetCloudProviderTyped: async () => clone(getCurrentProviderMeta()),
    SetCloudProvider: async (provider) => {
      const target = String(provider || '').toLowerCase();
      if (!state.providerMeta[target]) {
        return fail(`unknown provider: ${provider}`);
      }
      state.provider = target;
      return ok('switched');
    },
    SetCloudProviderTyped: async (provider) => {
      const target = String(provider || '').toLowerCase();
      if (!state.providerMeta[target]) {
        throw new Error(`unknown provider: ${provider}`);
      }
      state.provider = target;
      return clone(state.providerMeta[target]);
    },

    // Cloud metadata
    ListCloudRegions: async () => ok(state.regions[getCurrentProvider()] || []),
    ListCloudRegionsTyped: async () => clone(state.regions[getCurrentProvider()] || []),
    ListCloudPlans: async () => ok(state.plans[getCurrentProvider()] || []),
    ListCloudPlansTyped: async () => clone(state.plans[getCurrentProvider()] || []),
    ListCloudAvailability: async (region) => {
      const current = state.availability[getCurrentProvider()] || {};
      return ok(current[String(region || '')] || []);
    },
    ListCloudAvailabilityTyped: async (region) => {
      const current = state.availability[getCurrentProvider()] || {};
      return clone(current[String(region || '')] || []);
    },

    // Cloud instances
    ListCloudInstances: async () => ok(clone(getCurrentProviderNodes())),
    ListCloudInstancesTyped: async () => clone(getCurrentProviderNodes()),
    CreateCloudInstance: async (payload) => {
      let options = {};
      try {
        options = JSON.parse(payload || '{}');
      } catch (error) {
        return fail(String(error));
      }
      const provider = getCurrentProvider();
      const node = makeNode(options, provider);
      state.nodes[provider] = [node, ...(state.nodes[provider] || [])];
      return ok(node);
    },
    CreateCloudInstanceTyped: async (options) => {
      const provider = getCurrentProvider();
      const node = makeNode(options || {}, provider);
      state.nodes[provider] = [node, ...(state.nodes[provider] || [])];
      return clone(node);
    },
    CreateMultipleCloudInstances: async (payload) => {
      let items = [];
      try {
        const parsed = JSON.parse(payload || '[]');
        items = Array.isArray(parsed) ? parsed : [];
      } catch (error) {
        return fail(String(error));
      }
      const provider = getCurrentProvider();
      const results = items.map((item, index) => {
        const node = makeNode(item || {}, provider);
        state.nodes[provider] = [node, ...(state.nodes[provider] || [])];
        return {
          id: node.instanceId || `idx-${index}`,
          success: true,
        };
      });
      return ok(results);
    },
    CreateMultipleCloudInstancesTyped: async (payload) => {
      const items = Array.isArray(payload) ? payload : [];
      const provider = getCurrentProvider();
      const results = items.map((item, index) => {
        const node = makeNode(item || {}, provider);
        state.nodes[provider] = [node, ...(state.nodes[provider] || [])];
        return {
          id: node.instanceId || `idx-${index}`,
          success: true,
        };
      });
      return clone(results);
    },
    DestroyCloudInstance: async (instanceId) => {
      const id = String(instanceId || '');
      const provider = getCurrentProvider();
      const before = state.nodes[provider] || [];
      state.nodes[provider] = before.filter((node) => node.instanceId !== id);
      return ok('destroyed');
    },
    DestroyCloudInstanceTyped: async (instanceId) => {
      const id = String(instanceId || '');
      const provider = getCurrentProvider();
      const before = state.nodes[provider] || [];
      state.nodes[provider] = before.filter((node) => node.instanceId !== id);
    },

    // Cloud testing
    TestAllCloudRegions: async () => {
      const regions = state.regions[getCurrentProvider()] || [];
      const result = regions.map((region, index) => ({
        code: region.id,
        name: region.city,
        ip: `203.0.113.${index + 10}`,
        latency: 40 + index * 15,
        loss: 0,
        status: 'ok',
      }));
      return ok(result);
    },
    TestCloudRegionLatency: async () => ok('45'),
    GetFastestCloudRegion: async () => ok(JSON.stringify({ code: 'nrt', latency: 42 })),
    ScoreCloudRegions: async () => ok([]),

    // Connectivity and health
    TestConnectivity: async (ip, portsJSON) => {
      let ports = [];
      try {
        const parsed = JSON.parse(String(portsJSON || '[]'));
        ports = Array.isArray(parsed) ? parsed : [];
      } catch {
        ports = [];
      }
      const portsOpen = Object.fromEntries(ports.map((p) => [String(p), true]));
      const result = {
        ip: String(ip || ''),
        icmpReachable: true,
        portsOpen,
        status: 'reachable',
      };
      return ok(result);
    },
    StartHealthMonitor: async () => ok(''),
    StopHealthMonitor: async () => ok(''),
    GetHealthStatus: async () => ok('[]'),
    CleanInvalidCloudNodes: async () => ok(''),
    TestSSHConnection: async () => ok('{}'),
    TestSSHConnectionTyped: async () => ({
      os: 'ubuntu',
      arch: 'amd64',
      memoryMB: 2048,
    }),

    // Kernel/system helpers
    GetAvailablePort: async () => ok('20123'),
    ProcessInfo: async () => ok(''),
    KillProcess: async () => ok(''),
    Exec: async () => ok(''),
    ExecBackground: async () => ok(String(10000 + Math.floor(Math.random() * 1000))),
    StartServer: async () => ok(''),
    StopServer: async () => ok(''),
    OpenMMDB: async () => ok(''),
    QueryMMDB: async () => ok('{}'),
    CloseMMDB: async () => ok(''),
    GetInterfaces: async () => ok('eth0|lo'),

    // Notifications
    Notify: async () => ok(''),
  };

  const appProxy = new Proxy(appBridge, {
    get(target, prop) {
      if (Object.prototype.hasOwnProperty.call(target, prop)) {
        return target[prop];
      }
      return async (...args) => {
        log('[mock App] fallback method:', String(prop), args);
        return ok('');
      };
    },
  });

  const registerEvent = (eventName, callback, maxCallbacks = -1) => {
    if (!state.runtimeEvents[eventName]) {
      state.runtimeEvents[eventName] = [];
    }
    const bucket = state.runtimeEvents[eventName];
    const wrapped = { callback, maxCallbacks };
    bucket.push(wrapped);
    return () => {
      const idx = bucket.indexOf(wrapped);
      if (idx >= 0) bucket.splice(idx, 1);
    };
  };

  const runtimeBridge = {
    LogPrint: (...args) => log('[runtime][print]', ...args),
    LogTrace: (...args) => log('[runtime][trace]', ...args),
    LogDebug: (...args) => log('[runtime][debug]', ...args),
    LogInfo: (...args) => log('[runtime][info]', ...args),
    LogWarning: (...args) => log('[runtime][warn]', ...args),
    LogError: (...args) => log('[runtime][error]', ...args),
    LogFatal: (...args) => log('[runtime][fatal]', ...args),

    EventsOnMultiple: (eventName, callback, maxCallbacks) =>
      registerEvent(String(eventName), callback, Number(maxCallbacks ?? -1)),
    EventsEmit: (eventName, ...payload) => {
      const bucket = state.runtimeEvents[String(eventName)] || [];
      bucket.slice().forEach((item) => {
        try {
          item.callback(...payload);
        } catch (error) {
          log('[runtime][event][error]', String(error));
        }
        if (item.maxCallbacks > 0) {
          item.maxCallbacks -= 1;
          if (item.maxCallbacks <= 0) {
            const idx = bucket.indexOf(item);
            if (idx >= 0) bucket.splice(idx, 1);
          }
        }
      });
      return true;
    },
    EventsOff: (eventName) => {
      if (eventName) {
        delete state.runtimeEvents[String(eventName)];
      }
      return true;
    },

    WindowReload: () => {},
    WindowReloadApp: () => {},
    WindowSetAlwaysOnTop: () => {},
    WindowSetSystemDefaultTheme: () => {},
    WindowSetLightTheme: () => {},
    WindowSetDarkTheme: () => {},
    WindowCenter: () => {},
    WindowSetTitle: () => {},
    WindowFullscreen: () => {},
    WindowUnfullscreen: () => {},
    WindowIsFullscreen: () => false,
    WindowGetSize: () => [1280, 800],
    WindowSetSize: () => {},
    WindowSetMaxSize: () => {},
    WindowSetMinSize: () => {},
    WindowSetPosition: () => {},
    WindowGetPosition: () => [100, 100],
    WindowHide: () => {},
    WindowShow: () => {},
    WindowMaximise: () => {},
    WindowToggleMaximise: () => {},
    WindowUnmaximise: () => {},
    WindowIsMaximised: () => false,
    WindowMinimise: () => {},
    WindowUnminimise: () => {},
    WindowSetBackgroundColour: () => {},
    WindowIsMinimised: () => false,
    WindowIsNormal: () => true,
    BrowserOpenURL: () => {},
    Environment: () => ({
      buildType: 'production',
      platform: 'linux',
      arch: 'amd64',
      version: 'e2e-mock',
      debug: false,
    }),
    Quit: () => {},
    Hide: () => {},
    Show: () => {},
    ClipboardGetText: async () => state.clipboard,
    ClipboardSetText: async (text) => {
      state.clipboard = String(text || '');
      return true;
    },
    OnFileDrop: () => {},
    OnFileDropOff: () => {},
    CanResolveFilePaths: () => false,
    ResolveFilePaths: (paths) => paths,
  };

  const runtimeProxy = new Proxy(runtimeBridge, {
    get(target, prop) {
      if (Object.prototype.hasOwnProperty.call(target, prop)) {
        return target[prop];
      }
      return (...args) => {
        log('[mock runtime] fallback method:', String(prop), args);
        return undefined;
      };
    },
  });

  window.go = window.go || {};
  window.go.bridge = window.go.bridge || {};
  window.go.bridge.App = appProxy;

  window.runtime = runtimeProxy;
  window.AsyncFunction = Object.getPrototypeOf(async function () {}).constructor;
  window.Plugins = {
    BrowserOpenURL: () => {},
  };

  window.__cloudE2E = {
    get provider() {
      return state.provider;
    },
    set provider(value) {
      state.provider = value;
    },
    get files() {
      return state.files;
    },
    get nodes() {
      return state.nodes;
    },
    get configs() {
      return state.configs;
    },
    get logs() {
      return state.logs;
    },
    emit: (eventName, ...payload) => runtimeBridge.EventsEmit(eventName, ...payload),
    resetLogs: () => {
      state.logs.length = 0;
    },
  };
})();
"""


@dataclass
class AssertionResult:
    name: str
    passed: bool
    actual: Any
    expected: Any


@dataclass
class RegressionReport:
    status: str
    base_url: str
    port: int
    timestamp: str
    steps: list[str]
    assertions: list[AssertionResult]
    console_errors: list[str]
    ignored_console_errors: list[str]
    created_labels: dict[str, str]
    artifacts: dict[str, str]


def log(msg: str) -> None:
    print(f"[cloud-e2e] {msg}", flush=True)


def run_cmd(cmd: list[str], cwd: Path) -> None:
    log(f"Running: {' '.join(cmd)}")
    subprocess.run(cmd, cwd=str(cwd), check=True)


def build_frontend() -> None:
    if not FRONTEND_DIR.exists():
        raise FileNotFoundError(f"frontend directory not found: {FRONTEND_DIR}")
    run_cmd(["npm", "run", "build-only"], cwd=FRONTEND_DIR)


def inject_mock_bridge(index_html_path: Path, mock_js_name: str) -> None:
    html = index_html_path.read_text(encoding="utf-8")
    if mock_js_name in html:
        return

    inject_tag = f'<script src="./{mock_js_name}"></script>'

    pattern = re.compile(r"<script\s+type=\"module\"", flags=re.IGNORECASE)
    match = pattern.search(html)
    if match:
        html = html[: match.start()] + inject_tag + "\n" + html[match.start() :]
    else:
        html = html.replace("</head>", f"{inject_tag}\n</head>")

    index_html_path.write_text(html, encoding="utf-8")


class QuietRequestHandler(SimpleHTTPRequestHandler):
    def log_message(self, format: str, *args: Any) -> None:
        return


class LocalStaticServer:
    def __init__(self, root: Path, host: str, port: int):
        self.root = root
        self.host = host
        self.port = port
        self._httpd: ThreadingHTTPServer | None = None
        self._thread: threading.Thread | None = None

    def start(self) -> None:
        handler = lambda *args, **kwargs: QuietRequestHandler(*args, directory=str(self.root), **kwargs)
        self._httpd = ThreadingHTTPServer((self.host, self.port), handler)
        self._thread = threading.Thread(target=self._httpd.serve_forever, daemon=True)
        self._thread.start()
        time.sleep(0.25)

    def stop(self) -> None:
        if self._httpd:
            self._httpd.shutdown()
            self._httpd.server_close()
            self._httpd = None
        if self._thread:
            self._thread.join(timeout=2)
            self._thread = None


def click_first_button_by_names(scope, names: list[str], timeout_ms: int = 8000) -> None:
    last_error: Exception | None = None
    for name in names:
        locators = [
            scope.locator(".gui-button", has_text=name),
            scope.locator(f"text={name}"),
        ]
        for locator in locators:
            if locator.count() == 0:
                continue
            btn = locator.first
            try:
                btn.wait_for(state="visible", timeout=timeout_ms)
                btn.click(timeout=timeout_ms)
                return
            except Exception as exc:  # noqa: BLE001
                last_error = exc
                continue
    if last_error:
        raise last_error
    raise RuntimeError(f"button not found for names: {names}")


def try_click_button_by_names(scope, names: list[str], timeout_ms: int = 8000) -> bool:
    try:
        click_first_button_by_names(scope, names, timeout_ms=timeout_ms)
        return True
    except Exception:  # noqa: BLE001
        return False


def open_select_and_choose_first_option(select_scope) -> None:
    toggle_btn = select_scope.locator(".gui-button").first
    toggle_btn.click(timeout=4000)
    options = select_scope.locator(".gui-dropdown-overlay:visible .gui-button")
    if options.count() == 0:
        options = select_scope.locator(".gui-dropdown-overlay:visible >> xpath=.//*")
    if options.count() == 0:
        raise RuntimeError("dropdown opened but no options available")
    options.first.click(timeout=4000)


def open_select_and_choose_by_name(select_scope, option_names: list[str]) -> None:
    toggle_btn = select_scope.locator(".gui-button").first
    toggle_btn.click(timeout=4000)
    overlay = select_scope.locator(".gui-dropdown-overlay:visible")
    for name in option_names:
        candidate = overlay.locator(".gui-button", has_text=name)
        if candidate.count() == 0:
            candidate = overlay.locator(f"text={name}")
        if candidate.count() > 0:
            candidate.first.click(timeout=4000)
            return
    raise RuntimeError(f"failed to find dropdown option in {option_names}")


def ensure_deploy_form_ready(page) -> None:
    deploy_btn = page.locator(".gui-button", has_text=re.compile(r"(创建并部署|Create\\s*&\\s*Deploy)")).first
    if deploy_btn.count() == 0:
        return

    classes = deploy_btn.get_attribute("class") or ""
    if "pointer-events-none" not in classes:
        return

    create_card = page.locator("div.gui-card", has_text="创建节点")
    if create_card.count() == 0:
        create_card = page.locator("div.gui-card", has_text="Create Node")
    if create_card.count() == 0:
        create_card = page.locator("div.gui-card").nth(1)
    create_card = create_card.first
    selects = create_card.locator(".gui-select")
    if selects.count() < 2:
        return

    open_select_and_choose_first_option(selects.nth(0))
    open_select_and_choose_first_option(selects.nth(1))


def switch_provider_via_ui(page, target_name: str) -> None:
    trigger = page.locator("#cloud-provider-label + .gui-dropdown .gui-select").first
    trigger.click(timeout=5000)
    option = page.locator(".gui-dropdown-overlay:visible").locator(f"text={target_name}").first
    option.wait_for(state="visible", timeout=5000)
    option.click(timeout=5000)


def close_active_modal_if_any(page) -> None:
    masks = page.locator(".gui-modal-mask")
    if masks.count() == 0:
        return

    active = masks.last
    if not try_click_button_by_names(active, ["取消", "Cancel", "common.cancel"], timeout_ms=3000):
        page.keyboard.press("Escape")
    try:
        active.wait_for(state="detached", timeout=5000)
    except Exception:  # noqa: BLE001
        pass


def ensure_cloud_page_loaded(page, base_url: str) -> None:
    cloud_url = f"{base_url}/#/settings?tab=cloud"
    page.goto(cloud_url, wait_until="domcontentloaded", timeout=60000)

    # First navigation may be redirected to the onboarding wizard by router guard.
    wizard_skip = page.locator("button", has_text=re.compile(r"(跳过向导，直接进入|Skip\\s+wizard)", re.IGNORECASE)).first
    if wizard_skip.count() > 0:
        try:
            wizard_skip.click(timeout=8000)
            page.wait_for_timeout(600)
        except Exception:  # noqa: BLE001
            pass

    if "/#/wizard" in page.url or "tab=cloud" not in page.url:
        page.goto(cloud_url, wait_until="domcontentloaded", timeout=60000)

    page.wait_for_selector(
        "div.cloud-view, button:has-text('创建并部署'), button:has-text('Create & Deploy')",
        timeout=60000,
    )


def collect_subscription_assertions(file_map: dict[str, str], labels: dict[str, str]) -> list[AssertionResult]:
    parsed_files: dict[str, Any] = {}
    for path, content in file_map.items():
        try:
            parsed_files[path] = json.loads(content)
        except Exception:
            continue

    def find_outbound(predicate):
        for payload in parsed_files.values():
            outbounds = payload.get("outbounds") if isinstance(payload, dict) else None
            if not isinstance(outbounds, list):
                continue
            for outbound in outbounds:
                if not isinstance(outbound, dict):
                    continue
                if predicate(outbound):
                    return outbound
        return None

    deploy_label = labels["deploy"]
    manual_label = labels["manual"]
    import_hy2_label = labels["import_hy2"]
    import_trojan_label = labels["import_trojan"]

    managed_hy2 = find_outbound(
        lambda ob: str(ob.get("tag", "")).startswith(f"{deploy_label}-hysteria2")
    )
    manual_hy2 = find_outbound(
        lambda ob: str(ob.get("tag", "")).startswith(f"{manual_label}-hysteria2")
    )
    imported_hy2 = find_outbound(
        lambda ob: str(ob.get("tag", "")).startswith(f"{import_hy2_label}-hysteria2")
    )
    imported_trojan = find_outbound(
        lambda ob: str(ob.get("tag", "")).startswith(f"{import_trojan_label}-trojan")
    )

    managed_insecure = (
        managed_hy2.get("tls", {}).get("insecure") if isinstance(managed_hy2, dict) else None
    )
    manual_insecure = (
        manual_hy2.get("tls", {}).get("insecure") if isinstance(manual_hy2, dict) else None
    )
    imported_hy2_insecure = (
        imported_hy2.get("tls", {}).get("insecure") if isinstance(imported_hy2, dict) else None
    )
    imported_hy2_sni = (
        imported_hy2.get("tls", {}).get("server_name") if isinstance(imported_hy2, dict) else None
    )
    imported_trojan_insecure = (
        imported_trojan.get("tls", {}).get("insecure") if isinstance(imported_trojan, dict) else None
    )
    imported_trojan_sni = (
        imported_trojan.get("tls", {}).get("server_name") if isinstance(imported_trojan, dict) else None
    )

    return [
        AssertionResult(
            name="managed_hysteria_default_insecure_true",
            passed=managed_insecure is True,
            actual=managed_insecure,
            expected=True,
        ),
        AssertionResult(
            name="manual_hysteria_default_insecure_false",
            passed=manual_insecure is False,
            actual=manual_insecure,
            expected=False,
        ),
        AssertionResult(
            name="import_hysteria_sni_and_insecure_parsed",
            passed=imported_hy2_insecure is True and imported_hy2_sni == "import.example.com",
            actual={"insecure": imported_hy2_insecure, "sni": imported_hy2_sni},
            expected={"insecure": True, "sni": "import.example.com"},
        ),
        AssertionResult(
            name="import_trojan_sni_and_insecure_parsed",
            passed=imported_trojan_insecure is True and imported_trojan_sni == "trojan.example.com",
            actual={"insecure": imported_trojan_insecure, "sni": imported_trojan_sni},
            expected={"insecure": True, "sni": "trojan.example.com"},
        ),
    ]


def run_regression(base_url: str, artifacts_dir: Path, headed: bool) -> RegressionReport:
    steps: list[str] = []
    console_errors: list[str] = []
    ignored_console_errors: list[str] = []

    labels = {
        "deploy": f"auto-e2e-{random.randint(1000, 9999)}",
        "manual": f"manual-e2e-{random.randint(1000, 9999)}",
        "import_hy2": f"import-e2e-hy2-{random.randint(1000, 9999)}",
        "import_trojan": f"import-e2e-trojan-{random.randint(1000, 9999)}",
    }

    screenshot_path = artifacts_dir / "cloud-e2e-final.png"

    with sync_playwright() as p:
        browser = p.chromium.launch(headless=not headed)
        context = browser.new_context(viewport={"width": 1400, "height": 900})
        page = context.new_page()

        def on_console(msg):
            if msg.type == "error":
                text = msg.text
                if any(pattern.search(text) for pattern in IGNORED_CONSOLE_ERROR_PATTERNS):
                    ignored_console_errors.append(text)
                else:
                    console_errors.append(text)

        page.on("console", on_console)

        ensure_cloud_page_loaded(page, base_url)
        steps.append("open_cloud_page")

        # Search/filter interaction
        search_input = page.locator(
            "input[placeholder='按名称、IP 或区域搜索...'], input[placeholder='Search by name, IP, or region...']"
        ).first
        search_input.fill("cloud-e2e-1")
        page.wait_for_selector("tbody tr:has-text('cloud-e2e-1')", timeout=15000)
        steps.append("search_nodes")

        if try_click_button_by_names(page, ["清除筛选", "Clear Filters"], timeout_ms=8000):
            steps.append("clear_filters")
        else:
            steps.append("clear_filters_skipped")

        # Create and deploy node
        ensure_deploy_form_ready(page)
        label_input = page.locator("input[placeholder='实例名称'], input[placeholder='Instance label']").first
        label_input.fill(labels["deploy"])
        click_first_button_by_names(page, ["创建并部署", "Create & Deploy"], timeout_ms=15000)
        page.wait_for_selector(f"tbody tr:has-text('{labels['deploy']}')", timeout=20000)
        steps.append("create_and_deploy_node")

        # Provider switch flow
        switch_provider_via_ui(page, "DigitalOcean")
        page.wait_for_timeout(500)
        switch_provider_via_ui(page, "Vultr")
        page.wait_for_timeout(500)
        steps.append("switch_provider_vultr_do_vultr")

        # Add manual node
        click_first_button_by_names(page, ["增加节点", "Add Node"], timeout_ms=10000)
        modal = page.locator(".gui-modal-mask").last
        modal.wait_for(timeout=10000)
        modal.locator("input[placeholder='example-node']").first.fill(labels["manual"])
        modal.locator("input[placeholder='203.0.113.10']").first.fill("203.0.113.50")
        modal.locator("input[placeholder='443']").first.fill("443")
        modal.locator(".form-field:has-text('Shadowsocks 密码') input").first.fill("manual-ss-pass")
        modal.locator("input[placeholder='8443']").first.fill("8443")
        modal.locator(".form-field:has-text('Hysteria2 Password') input").first.fill("manual-hy-pass")
        click_first_button_by_names(modal, ["保存", "Save", "common.save"], timeout_ms=10000)
        page.wait_for_selector(f"tbody tr:has-text('{labels['manual']}')", timeout=15000)
        steps.append("add_manual_node")

        # Import nodes via protocol URLs
        click_first_button_by_names(page, ["导入节点", "Import Nodes"], timeout_ms=10000)
        import_modal = page.locator(".gui-modal-mask").last
        import_modal.wait_for(timeout=10000)

        import_payload = "\n".join(
            [
                f"hy2://hy-pass@203.0.113.60:8443?sni=import.example.com&insecure=1#{labels['import_hy2']}",
                f"trojan://trojan-pass@203.0.113.61:443?allowInsecure=1&sni=trojan.example.com#{labels['import_trojan']}",
            ]
        )
        import_modal.locator("textarea.import-textarea").first.fill(import_payload)
        click_first_button_by_names(import_modal, ["导入", "Import", "common.import"], timeout_ms=10000)

        page.wait_for_selector(f"tbody tr:has-text('{labels['import_hy2']}')", timeout=15000)
        page.wait_for_selector(f"tbody tr:has-text('{labels['import_trojan']}')", timeout=15000)
        steps.append("import_protocol_links")
        close_active_modal_if_any(page)

        file_map_after_import = page.evaluate("""() => {
          const data = window.__cloudE2E?.files || {};
          return JSON.parse(JSON.stringify(data));
        }""")

        assertions = collect_subscription_assertions(file_map_after_import, labels)

        # Delete one imported node with confirmation
        import_row = page.locator("tbody tr", has_text=labels["import_trojan"]).first
        delete_btn = import_row.locator(".gui-button", has_text="删除")
        if delete_btn.count() == 0:
            delete_btn = import_row.locator(".gui-button", has_text="Delete")
        delete_btn.first.click(timeout=10000)
        click_first_button_by_names(page, ["确定", "确认", "Confirm", "common.confirm"], timeout_ms=10000)
        page.wait_for_selector(f"tbody tr:has-text('{labels['import_trojan']}')", state="detached", timeout=15000)
        trojan_rows_after_delete = page.locator("tbody tr", has_text=labels["import_trojan"]).count()
        steps.append("delete_imported_node")

        assertions.append(
            AssertionResult(
                name="import_trojan_row_deleted",
                passed=trojan_rows_after_delete == 0,
                actual=trojan_rows_after_delete,
                expected=0,
            )
        )

        page.screenshot(path=str(screenshot_path), full_page=True)

        # Include console-error-free assertion in report.
        assertions.append(
            AssertionResult(
                name="console_error_count_zero",
                passed=len(console_errors) == 0,
                actual=len(console_errors),
                expected=0,
            )
        )

        context.close()
        browser.close()

    overall_ok = all(item.passed for item in assertions)
    status = "passed" if overall_ok else "failed"

    return RegressionReport(
        status=status,
        base_url=base_url,
        port=int(base_url.rsplit(":", 1)[-1]),
        timestamp=datetime.now().isoformat(),
        steps=steps,
        assertions=assertions,
        console_errors=console_errors,
        ignored_console_errors=ignored_console_errors,
        created_labels=labels,
        artifacts={"screenshot": str(screenshot_path)},
    )


def write_report(report: RegressionReport, output_path: Path) -> None:
    payload = {
        "status": report.status,
        "base_url": report.base_url,
        "port": report.port,
        "timestamp": report.timestamp,
        "steps": report.steps,
        "assertions": [asdict(item) for item in report.assertions],
        "console_errors": report.console_errors,
        "ignored_console_errors": report.ignored_console_errors,
        "created_labels": report.created_labels,
        "artifacts": report.artifacts,
    }
    output_path.write_text(json.dumps(payload, ensure_ascii=False, indent=2), encoding="utf-8")


def main() -> int:
    parser = argparse.ArgumentParser(description="Run full cloud page interactive UI regression")
    parser.add_argument("--port", type=int, default=DEFAULT_PORT, help="Local server port (default: 4174)")
    parser.add_argument("--host", default="127.0.0.1", help="Local server host (default: 127.0.0.1)")
    parser.add_argument("--skip-build", action="store_true", help="Skip frontend build step")
    parser.add_argument("--headed", action="store_true", help="Run browser in headed mode")
    parser.add_argument(
        "--output-dir",
        default=str(DEFAULT_OUTPUT_DIR),
        help="Artifact output directory (default: output/playwright)",
    )
    parser.add_argument("--keep-workdir", action="store_true", help="Keep temporary served dist directory")

    args = parser.parse_args()

    if args.port == 7890:
        raise SystemExit("Refusing to use port 7890 to avoid impacting system proxy.")

    output_dir = Path(args.output_dir).resolve()
    output_dir.mkdir(parents=True, exist_ok=True)

    if not args.skip_build:
        build_frontend()

    if not DIST_DIR.exists():
        raise FileNotFoundError(f"frontend dist not found: {DIST_DIR}")

    run_id = datetime.now().strftime("%Y%m%d-%H%M%S")
    workdir = output_dir / f"cloud-e2e-workdir-{run_id}"
    served_dir = workdir / "site"
    served_dir.parent.mkdir(parents=True, exist_ok=True)

    shutil.copytree(DIST_DIR, served_dir)

    mock_js_name = "cloud-e2e-mock.js"
    (served_dir / mock_js_name).write_text(MOCK_BRIDGE_JS, encoding="utf-8")
    inject_mock_bridge(served_dir / "index.html", mock_js_name)

    server = LocalStaticServer(root=served_dir, host=args.host, port=args.port)
    base_url = f"http://{args.host}:{args.port}"
    report_path = output_dir / "cloud-e2e-report.json"

    try:
        log(f"Starting local server: {base_url}")
        server.start()

        report = run_regression(base_url=base_url, artifacts_dir=output_dir, headed=args.headed)
        write_report(report, report_path)

        log(f"Regression status: {report.status}")
        log(f"Report: {report_path}")
        for item in report.assertions:
            icon = "PASS" if item.passed else "FAIL"
            log(f"[{icon}] {item.name} | actual={item.actual!r} expected={item.expected!r}")

        return 0 if report.status == "passed" else 1
    except (PlaywrightTimeoutError, PlaywrightError, RuntimeError) as exc:
        log(f"Regression failed: {exc}")
        return 1
    finally:
        server.stop()
        if not args.keep_workdir:
            shutil.rmtree(workdir, ignore_errors=True)


if __name__ == "__main__":
    sys.exit(main())
