const languagePaths = {
  en: "",
  "zh-CN": "zh",
  es: "es",
  fr: "fr",
  de: "de",
  ja: "ja",
  ko: "ko",
  pt: "pt",
  ru: "ru",
  ar: "ar",
  hi: "hi",
  id: "id",
};
const supportedLanguagePrefixes = new Set(Object.values(languagePaths).filter(Boolean));
const supportedSections = new Set(["download", "docs", "security"]);
const languageStorageKey = "privatedeploy.language";

function getPathContext() {
  const parts = window.location.pathname.split("/").filter(Boolean);
  const activePrefix = supportedLanguagePrefixes.has(parts[0]) ? parts[0] : "";
  const activeSection = activePrefix ? parts[1] : parts[0];
  return {
    activePrefix,
    sectionPath: supportedSections.has(activeSection) ? activeSection : "",
  };
}

function buildLocalizedPath(prefix, sectionPath) {
  const parts = [prefix, sectionPath].filter(Boolean);
  return `/${parts.join("/")}${parts.length ? "/" : ""}`;
}

function normalizeLanguage(language) {
  const tag = language.toLowerCase();
  const primary = tag.split("-")[0];
  if (tag === "zh-cn" || tag === "zh-sg" || tag === "zh-hans" || primary === "zh") {
    return "zh";
  }
  if (primary === "pt") return "pt";
  if (primary === "en") return "";
  return supportedLanguagePrefixes.has(primary) ? primary : "";
}

function readStoredLanguage() {
  const normalizeStoredValue = (value) => {
    if (value === "en") return "";
    if (value && supportedLanguagePrefixes.has(value)) return value;
    return null;
  };

  try {
    const stored = window.localStorage?.getItem(languageStorageKey);
    const normalized = normalizeStoredValue(stored);
    if (normalized !== null) return normalized;
  } catch {
    // Fall back to cookie below.
  }

  const cookieMatch = document.cookie.match(/(?:^|;\s*)pd_lang=([^;]+)/);
  if (cookieMatch) {
    return normalizeStoredValue(decodeURIComponent(cookieMatch[1]));
  }
  return null;
}

function writeStoredLanguage(prefix) {
  const value = prefix || "en";
  try {
    window.localStorage?.setItem(languageStorageKey, value);
  } catch {
    // Ignore storage failures in restricted browsers.
  }
  document.cookie = `pd_lang=${value}; Path=/; Max-Age=31536000; SameSite=Lax`;
}

function detectBrowserLanguage() {
  const languages = navigator.languages?.length ? navigator.languages : [navigator.language || ""];
  for (const language of languages) {
    const prefix = normalizeLanguage(language);
    if (prefix || language.toLowerCase().startsWith("en")) {
      return prefix;
    }
  }
  return "";
}

function maybeRedirectToPreferredLanguage() {
  const { activePrefix, sectionPath } = getPathContext();
  if (activePrefix || !document.documentElement.hasAttribute("data-auto-language")) {
    return;
  }

  const stored = readStoredLanguage();
  const preferredPrefix = stored === null ? detectBrowserLanguage() : stored;
  if (!preferredPrefix) {
    return;
  }

  const targetPath = buildLocalizedPath(preferredPrefix, sectionPath);
  if (targetPath !== window.location.pathname) {
    window.location.replace(targetPath);
  }
}

maybeRedirectToPreferredLanguage();

const navToggle = document.querySelector("[data-nav-toggle]");
const navMenu = document.querySelector("[data-nav-menu]");

if (navToggle && navMenu) {
  navToggle.addEventListener("click", () => {
    const isOpen = navToggle.getAttribute("aria-expanded") === "true";
    navToggle.setAttribute("aria-expanded", String(!isOpen));
    navMenu.toggleAttribute("data-open", !isOpen);
  });
}

document.querySelectorAll("[data-language-menu]").forEach((menu) => {
  const toggle = menu.querySelector("[data-language-toggle]");
  if (!toggle) {
    return;
  }

  const { activePrefix, sectionPath } = getPathContext();

  menu.querySelectorAll(".language-options a[lang]").forEach((link) => {
    const prefix = languagePaths[link.getAttribute("lang")] ?? "";
    const href = buildLocalizedPath(prefix, sectionPath);
    link.setAttribute("href", href);
    link.toggleAttribute("aria-current", prefix === activePrefix);
    link.addEventListener("click", () => {
      writeStoredLanguage(prefix);
    });
  });

  toggle.addEventListener("click", (event) => {
    event.stopPropagation();
    const isOpen = menu.hasAttribute("data-open");
    document.querySelectorAll("[data-language-menu]").forEach((other) => {
      if (other !== menu) {
        other.removeAttribute("data-open");
        other.querySelector("[data-language-toggle]")?.setAttribute("aria-expanded", "false");
      }
    });
    menu.toggleAttribute("data-open", !isOpen);
    toggle.setAttribute("aria-expanded", String(!isOpen));
  });
});

document.addEventListener("click", () => {
  document.querySelectorAll("[data-language-menu]").forEach((menu) => {
    menu.removeAttribute("data-open");
    menu.querySelector("[data-language-toggle]")?.setAttribute("aria-expanded", "false");
  });
});

document.addEventListener("keydown", (event) => {
  if (event.key !== "Escape") {
    return;
  }
  document.querySelectorAll("[data-language-menu]").forEach((menu) => {
    menu.removeAttribute("data-open");
    menu.querySelector("[data-language-toggle]")?.setAttribute("aria-expanded", "false");
  });
});

document.querySelectorAll("[data-copy]").forEach((button) => {
  button.addEventListener("click", async () => {
    const value = button.getAttribute("data-copy");
    if (!value || !navigator.clipboard) {
      return;
    }

    const original = button.textContent;
    const copied = button.getAttribute("data-copied") || "Copied";
    const failed = button.getAttribute("data-copy-failed") || "Copy failed";
    try {
      await navigator.clipboard.writeText(value);
      button.textContent = copied;
      window.setTimeout(() => {
        button.textContent = original;
      }, 1600);
    } catch {
      button.textContent = failed;
      window.setTimeout(() => {
        button.textContent = original;
      }, 1600);
    }
  });
});
