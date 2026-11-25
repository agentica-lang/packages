const form = document.querySelector(".catalog-filter");
const table = document.querySelector("table.catalog");
if (form && table) {
  const rows = [...table.tBodies[0].rows];
  const count = form.querySelector(".catalog-count");
  const apply = () => {
    const words = form.q.value.toLowerCase().split(/\s+/).filter(Boolean);
    const category = form.category.value;
    let shown = 0;
    for (const row of rows) {
      const match = (!category || row.dataset.category === category) && words.every((word) => row.dataset.search.includes(word));
      row.hidden = !match;
      if (match) shown++;
    }
    count.textContent = `${shown} of ${rows.length} packages`;
  };
  form.addEventListener("input", apply);
  form.addEventListener("submit", (event) => event.preventDefault());
  form.hidden = false;
  apply();
}
