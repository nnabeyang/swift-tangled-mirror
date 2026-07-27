(() => {
  const navigation = document.querySelector("#manual-navigation");
  const toggle = document.querySelector(".nav-toggle");
  const filter = document.querySelector("#command-filter");

  if (toggle && navigation) {
    toggle.addEventListener("click", () => {
      const expanded = toggle.getAttribute("aria-expanded") === "true";
      toggle.setAttribute("aria-expanded", String(!expanded));
      navigation.classList.toggle("is-open", !expanded);
      if (!expanded) {
        filter?.focus();
      }
    });
  }

  if (!filter || !navigation) {
    return;
  }

  const items = [...navigation.querySelectorAll("[data-command-item]")];
  const groups = [...navigation.querySelectorAll("[data-command-group]")];
  const noResults = navigation.querySelector(".no-results");

  filter.addEventListener("input", () => {
    const query = filter.value.trim().toLowerCase();
    let visibleCount = 0;

    for (const item of items) {
      const matches = !query || item.dataset.search.includes(query);
      item.hidden = !matches;
      if (matches) {
        visibleCount += 1;
      }
    }

    for (const group of groups) {
      const hasVisibleItem = [...group.querySelectorAll("[data-command-item]")]
        .some((item) => !item.hidden);
      group.hidden = !hasVisibleItem;
    }

    if (noResults) {
      noResults.hidden = visibleCount !== 0;
    }
  });
})();
