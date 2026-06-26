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
  const localizedPrefixes = new Set(Object.values(languagePaths).filter(Boolean));
  const sections = new Set(["download", "docs", "security"]);
  const parts = window.location.pathname.split("/").filter(Boolean);
  const activePrefix = localizedPrefixes.has(parts[0]) ? parts[0] : "";
  const activeSection = activePrefix ? parts[1] : parts[0];
  const sectionPath = sections.has(activeSection) ? activeSection : "";

  menu.querySelectorAll(".language-options a[lang]").forEach((link) => {
    const prefix = languagePaths[link.getAttribute("lang")] ?? "";
    const href = `/${[prefix, sectionPath].filter(Boolean).join("/")}${prefix || sectionPath ? "/" : ""}`;
    link.setAttribute("href", href);
    link.toggleAttribute("aria-current", prefix === activePrefix);
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
