(() => {
  const KEY = "receipt-divider-prototype-v1";
  const today = new Date().toISOString().slice(0, 10);
  const seed = { expenses: [], payments: [], draft: null };
  let state = load();
  let draft = null;
  const $ = (id) => document.getElementById(id);
  const money = (cents) => new Intl.NumberFormat("en-US", { style: "currency", currency: "USD" }).format((cents || 0) / 100);
  const cents = (value) => Math.round((Number.parseFloat(String(value).replace(/[^0-9.-]/g, "")) || 0) * 100);
  const formatInput = (value) => (Math.max(0, value || 0) / 100).toFixed(2);
  const save = () => localStorage.setItem(KEY, JSON.stringify(state));
  const load = () => { try { return { ...seed, ...JSON.parse(localStorage.getItem(KEY) || "null") }; } catch { return { ...seed }; } };
  const show = (name) => {
    document.querySelectorAll(".screen").forEach(x => x.classList.remove("active"));
    $(name + "-screen").classList.add("active");
    document.querySelectorAll("[data-nav]").forEach(button => button.classList.toggle("active", button.dataset.nav === name));
    window.scrollTo(0, 0);
  };
  const toast = (text) => { const el = $("toast"); el.textContent = text; el.classList.add("show"); setTimeout(() => el.classList.remove("show"), 2800); };
  const escape = (value) => String(value || "").replace(/[&<>'"]/g, c => ({ "&":"&amp;", "<":"&lt;", ">":"&gt;", "'":"&#39;", '"':"&quot;" }[c]));
  const dateLabel = (date) => new Intl.DateTimeFormat("en-US", { month: "long", day: "numeric", year: "numeric" }).format(new Date(date + "T12:00:00"));

  function netBalance() {
    let net = 0;
    state.expenses.forEach(e => { if (e.payer === "alex") net += e.total; net -= e.shares.alex || 0; });
    state.payments.forEach(p => { if (p.from === "alex") net -= p.amount; if (p.to === "alex") net += p.amount; });
    return net;
  }
  function renderHome() {
    const net = netBalance();
    $("balance-value").textContent = net === 0 ? "$0.00" : `${net > 0 ? "+" : "−"}${money(Math.abs(net))}`;
    $("balance-detail").textContent = net === 0 ? "You are all settled up." : net > 0 ? "Jamie owes you this amount." : "You owe Jamie this amount.";
    const records = [
      ...state.expenses.map(e => ({ ...e, type: "expense" })),
      ...state.payments.map(p => ({ ...p, type: "payment" }))
    ].sort((a, b) => b.transactionDate.localeCompare(a.transactionDate) || b.createdAt.localeCompare(a.createdAt));
    const history = $("history"); history.innerHTML = "";
    $("empty-history").hidden = records.length > 0;
    let priorDate = "";
    records.forEach(r => {
      if (r.transactionDate !== priorDate) { priorDate = r.transactionDate; history.insertAdjacentHTML("beforeend", `<p class="history-date">${dateLabel(r.transactionDate)}</p>`); }
      if (r.type === "expense") {
        const yours = r.shares.alex || 0;
        history.insertAdjacentHTML("beforeend", `<article class="transaction"><div class="transaction-icon">▤</div><div><strong>${escape(r.description)}</strong><small>Paid by ${r.payer === "alex" ? "Alex" : "Jamie"} · Your share ${money(yours)}</small></div><div class="amount">${money(r.total)}<small>${r.items.length} item${r.items.length === 1 ? "" : "s"}</small></div></article>`);
      } else {
        history.insertAdjacentHTML("beforeend", `<article class="transaction payment"><div class="transaction-icon">↗</div><div><strong>Payment recorded</strong><small>${r.from === "alex" ? "Alex" : "Jamie"} paid ${r.to === "alex" ? "Alex" : "Jamie"}</small></div><div class="amount">${money(r.amount)}</div></article>`);
      }
    });
  }
  function blankDraft() { return { items: [{ id: crypto.randomUUID(), selected: true, name: "", amount: 0 }], tax: 0, discount: 0, date: today, merchant: "", image: null, splitMode: "equal" }; }
  function openNewExpense() { draft = blankDraft(); $("receipt-file").value = ""; $("receipt-preview").hidden = true; show("receipt"); }
  function renderItems() {
    $("purchase-date").value = draft.date; $("merchant").value = draft.merchant; $("tax").value = formatInput(draft.tax); $("discount").value = formatInput(draft.discount);
    $("item-list").innerHTML = draft.items.map((item, index) => `<div class="item"><input data-item-check="${item.id}" type="checkbox" ${item.selected ? "checked" : ""} aria-label="Include item ${index + 1}"/><input data-item-name="${item.id}" type="text" placeholder="Item name" value="${escape(item.name)}"/><input data-item-price="${item.id}" class="input-price" inputmode="decimal" aria-label="Item price" value="${formatInput(item.amount)}"/><button data-delete="${item.id}" class="delete-line" type="button" aria-label="Delete item">×</button></div>`).join("");
    $("select-all").checked = draft.items.length > 0 && draft.items.every(i => i.selected); updateTotal();
  }
  function selectedSubtotal() { return draft.items.filter(i => i.selected).reduce((sum, i) => sum + i.amount, 0); }
  function draftTotal() { return Math.max(0, selectedSubtotal() + draft.tax - draft.discount); }
  function updateTotal() { $("selected-total").textContent = money(draftTotal()); }
  function renderShares() {
    const total = draftTotal(); const equalA = Math.ceil(total / 2); const equalJ = total - equalA;
    if (draft.splitMode === "equal") draft.shares = { alex: equalA, jamie: equalJ };
    if (!draft.shares) draft.shares = { alex: equalA, jamie: equalJ };
    $("split-total").textContent = money(total);
    document.querySelectorAll(".split-mode button").forEach(b => b.classList.toggle("selected", b.dataset.mode === draft.splitMode));
    $("shares").innerHTML = ["alex", "jamie"].map(person => `<div class="share"><div class="person"><span class="avatar">${person === "alex" ? "A" : "J"}</span>${person === "alex" ? "Alex" : "Jamie"}</div><input data-share="${person}" inputmode="decimal" ${draft.splitMode === "equal" ? "readonly" : ""} value="${formatInput(draft.shares[person])}" aria-label="${person} share" /></div>`).join("");
    const allocated = (draft.shares.alex || 0) + (draft.shares.jamie || 0); const message = $("allocation-message");
    if (allocated === total) { message.textContent = "Split matches the expense total."; message.className = "allocation-message"; }
    else { const d = total - allocated; message.textContent = `${d > 0 ? money(d) + " remains unallocated" : money(-d) + " is overallocated"}.`; message.className = "allocation-message error"; }
  }
  $("new-expense").addEventListener("click", openNewExpense); document.querySelectorAll(".start-expense").forEach(x => x.addEventListener("click", openNewExpense));
  document.querySelectorAll("[data-nav]").forEach(button => button.addEventListener("click", () => {
    if (button.dataset.nav === "new") openNewExpense();
    else if (button.dataset.nav === "payment") { $("payment-date").value = today; $("payment-amount").value = ""; show("payment"); }
    else show("home");
  }));
  document.querySelectorAll("[data-back]").forEach(b => b.addEventListener("click", () => show(b.dataset.back)));
  $("manual-entry").addEventListener("click", () => { renderItems(); show("review"); });
  $("receipt-file").addEventListener("change", event => { const file = event.target.files[0]; if (!file) return; const reader = new FileReader(); reader.onload = () => { draft.image = reader.result; $("receipt-preview").querySelector("img").src = reader.result; $("file-name").textContent = file.name; $("receipt-preview").hidden = false; }; reader.readAsDataURL(file); });
  $("remove-photo").addEventListener("click", () => { draft.image = null; $("receipt-file").value = ""; $("receipt-preview").hidden = true; });
  $("purchase-date").addEventListener("change", e => draft.date = e.target.value); $("merchant").addEventListener("input", e => draft.merchant = e.target.value);
  $("item-list").addEventListener("input", e => { const id = e.target.dataset.itemName || e.target.dataset.itemPrice; if (!id) return; const item = draft.items.find(i => i.id === id); if (e.target.dataset.itemName) item.name = e.target.value; else item.amount = cents(e.target.value); updateTotal(); });
  $("item-list").addEventListener("change", e => { if (e.target.dataset.itemCheck) { draft.items.find(i => i.id === e.target.dataset.itemCheck).selected = e.target.checked; $("select-all").checked = draft.items.every(i => i.selected); updateTotal(); } });
  $("item-list").addEventListener("click", e => { const id = e.target.dataset.delete; if (!id) return; draft.items = draft.items.filter(i => i.id !== id); renderItems(); });
  $("select-all").addEventListener("change", e => { draft.items.forEach(i => i.selected = e.target.checked); renderItems(); });
  $("add-line").addEventListener("click", () => { draft.items.push({ id: crypto.randomUUID(), selected: true, name: "", amount: 0 }); renderItems(); });
  ["tax", "discount"].forEach(id => $(id).addEventListener("input", e => { draft[id] = cents(e.target.value); updateTotal(); }));
  $("continue-split").addEventListener("click", () => { const selected = draft.items.filter(i => i.selected && i.amount > 0); if (!selected.length) return toast("Select at least one item with a price."); draft.items = selected; draft.shares = null; renderShares(); show("split"); });
  $("shares").addEventListener("input", e => { const person = e.target.dataset.share; if (!person || draft.splitMode !== "custom") return; draft.shares[person] = cents(e.target.value); renderShares(); });
  document.querySelectorAll(".split-mode button").forEach(b => b.addEventListener("click", () => { draft.splitMode = b.dataset.mode; if (draft.splitMode === "custom") { const half = Math.floor(draftTotal() / 2); draft.shares = { alex: half, jamie: draftTotal() - half }; } renderShares(); }));
  $("save-expense").addEventListener("click", () => { const total = draftTotal(), allocated = draft.shares.alex + draft.shares.jamie, description = $("expense-description").value.trim(); if (!description) return toast("Add a short description."); if (!draft.date) return toast("Choose the purchase date."); if (allocated !== total) return toast("Make the contributions match the total."); state.expenses.push({ id: crypto.randomUUID(), description, payer: $("payer").value, transactionDate: draft.date, merchant: draft.merchant, total, shares: { ...draft.shares }, items: draft.items.map(i => ({ name: i.name || "Untitled item", amount: i.amount })), tax: draft.tax, discount: draft.discount, receiptImage: draft.image, createdAt: new Date().toISOString() }); save(); renderHome(); show("home"); toast("Shared expense saved."); });
  $("record-payment").addEventListener("click", () => { $("payment-date").value = today; $("payment-amount").value = ""; show("payment"); });
  $("save-payment").addEventListener("click", () => { const amount = cents($("payment-amount").value), from = $("payment-from").value, to = $("payment-to").value, date = $("payment-date").value; if (!amount || from === to || !date) return toast("Enter a valid payment."); state.payments.push({ id: crypto.randomUUID(), amount, from, to, transactionDate: date, createdAt: new Date().toISOString() }); save(); renderHome(); show("home"); toast("Payment recorded."); });
  $("reset-demo").addEventListener("click", () => { if (!confirm("Remove all locally saved prototype data?")) return; state = { ...seed }; save(); renderHome(); toast("Prototype data cleared."); });
  renderHome();
})();
