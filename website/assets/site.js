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

  const path = window.location.pathname;
  const activePath = path.match(/^\/(zh|es|fr|de|ja|ko|pt|ru|ar|hi|id)(?:\/|$)/)?.[1];
  const currentHref = activePath ? `/${activePath}/` : "/";
  menu.querySelector(`.language-options a[href="${currentHref}"]`)?.setAttribute("aria-current", "true");

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
    try {
      await navigator.clipboard.writeText(value);
      button.textContent = "Copied";
      window.setTimeout(() => {
        button.textContent = original;
      }, 1600);
    } catch {
      button.textContent = "Copy failed";
      window.setTimeout(() => {
        button.textContent = original;
      }, 1600);
    }
  });
});
