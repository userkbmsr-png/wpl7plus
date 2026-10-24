"use strict";
(() => {
  const $ = (sel) => document.querySelector(sel);
  const form = $("#add");
  const msg = $("#msg");

  // Totul se construieste cu DOM + textContent (niciodata innerHTML): valorile vin din fisiere si din retea.
  function el(tag, props = {}, ...kids) {
    const n = document.createElement(tag);
    for (const [k, v] of Object.entries(props)) {
      if (k === "class") n.className = v;
      else if (k === "text") n.textContent = v;
      else if (k.startsWith("on")) n.addEventListener(k.slice(2), v);
      else n.setAttribute(k, v);
    }
    n.append(...kids);
    return n;
  }

  function say(text, kind = "info") {
    msg.className = "msg " + kind;
    msg.textContent = text;
    msg.hidden = !text;
  }

  async function api(method, url, body) {
    const headers = { "X-Requested-With": "proxyui" };
    if (body !== undefined) headers["Content-Type"] = "application/json";
    const res = await fetch(url, {
      method, headers, credentials: "same-origin", cache: "no-store",
      body: body === undefined ? undefined : JSON.stringify(body),
    });
    let data = {};
    try { data = await res.json(); } catch (_) { /* raspuns fara JSON */ }
    if (!res.ok) {
      const e = new Error(data.error || "Eroare " + res.status);
      e.status = res.status;
      e.code = data.code;
      throw e;
    }
    return data;
  }

  const line = (text, level) => el("li", { class: level, text });

  function dnsLine(d) {
    let t = "DNS: " + (d.a.length ? d.a.join(", ") : "niciun record A");
    if (d.aaaa.length) t += " · AAAA: " + d.aaaa.join(", ");
    if (d.public_ip) t += d.points_here ? " ✓ indică spre acest server" : " ⚠ nu include IP-ul public (" + d.public_ip + ")";
    const level = !d.a.length ? "bad" : (d.public_ip && !d.points_here ? "warn" : "ok");
    return line(t, level);
  }

  function certLine(c) {
    return c.ok
      ? line("Certificat: " + c.issuer + ", expiră în " + c.days + " zile", c.days < 14 ? "warn" : "ok")
      : line("Certificat: " + c.error + " - verifică DNS-ul și că portul 80 e deschis", "warn");
  }

  async function check(route, ui) {
    ui.dot.className = "dot wait";
    ui.status.textContent = "Se verifică…";
    ui.detail.replaceChildren();
    ui.btn.disabled = true;
    try {
      const d = await api("POST", "/api/check", { domain: route.domain });
      const b = d.backend;
      if (b.ok) {
        ui.dot.className = "dot " + (b.status >= 500 ? "bad" : b.status >= 400 ? "warn" : "ok");
        ui.status.textContent = "Ținta răspunde: HTTP " + b.status + " (" + b.ms + " ms)";
      } else {
        ui.dot.className = "dot bad";
        ui.status.textContent = "Ținta nu răspunde: " + b.error;
      }
      ui.detail.append(dnsLine(d.dns), certLine(d.cert));
    } catch (e) {
      ui.dot.className = "dot bad";
      ui.status.textContent = e.message;
    } finally {
      ui.btn.disabled = false;
    }
  }

  async function remove(route) {
    if (!confirm("Ștergi ruta pentru " + route.domain + "? Domeniul nu va mai deschide ținta.")) return;
    try {
      await api("DELETE", "/api/routes/" + encodeURIComponent(route.domain));
      say("Șters: " + route.domain, "ok");
      await load();
    } catch (e) { say(e.message, "bad"); }
  }

  function card(route) {
    const ui = {
      dot: el("span", { class: "dot" }),
      status: el("span", { text: "—" }),
      detail: el("ul", { class: "detail" }),
      btn: el("button", { type: "button", text: "Verifică", onclick: () => check(route, ui) }),
    };
    const head = el("div", { class: "head" },
      el("a", { href: "https://" + route.domain, target: "_blank", rel: "noopener noreferrer", text: route.domain }),
      el("span", { "aria-hidden": "true", text: "→" }),
      el("code", { text: route.target }));
    if (route.insecure) head.append(el("span", { class: "badge", text: "TLS neverificat" }));
    const li = el("li", { class: "route" }, head,
      el("div", { class: "status-line" }, ui.dot, ui.status), ui.detail,
      el("div", { class: "actions" }, ui.btn,
        el("button", { type: "button", class: "danger", text: "Șterge", onclick: () => remove(route) })));
    return { li, route, ui };
  }

  let items = [];

  async function load() {
    const data = await api("GET", "/api/routes");
    items = data.routes.map(card);
    $("#routes").replaceChildren(...items.map((i) => i.li));
    $("#empty").hidden = items.length > 0;
    const ig = $("#ignored");
    ig.hidden = data.ignored.length === 0;
    ig.textContent = data.ignored.length
      ? "Fișiere proxy-*.yml nerecunoscute (editate manual, nu sunt afișate): " + data.ignored.join(", ")
      : "";
    return items;
  }

  const checkAll = () => Promise.all(items.map((i) => check(i.route, i.ui)));

  async function submit(ev) {
    ev.preventDefault();
    const body = { domain: form.elements.domain.value, target: form.elements.target.value, insecure: form.elements.insecure.checked };
    $("#save").disabled = true;
    try {
      let res;
      try {
        res = await api("POST", "/api/routes", body);
      } catch (e) {
        if (e.code === "exists" && confirm("Ruta pentru " + body.domain + " există deja. O înlocuiesc?")) {
          res = await api("POST", "/api/routes", { ...body, overwrite: true });
        } else {
          throw e;
        }
      }
      say("Salvat: https://" + res.route.domain + " → " + res.route.target +
        ". Certificatul se emite în câteva secunde; apasă Verifică pentru stare.", "ok");
      form.reset();
      await load();
      const mine = items.find((i) => i.route.domain === res.route.domain);
      if (mine) check(mine.route, mine.ui);
    } catch (e) {
      say(e.message, "bad");
    } finally {
      $("#save").disabled = false;
    }
  }

  async function testTarget() {
    say("Se testează ținta…", "info");
    try {
      const d = await api("POST", "/api/check", { target: form.elements.target.value, insecure: form.elements.insecure.checked });
      const b = d.backend;
      say(b.ok ? "Ținta " + d.target + " răspunde: HTTP " + b.status + " (" + b.ms + " ms)."
               : "Ținta " + d.target + " nu răspunde: " + b.error, b.ok ? "ok" : "bad");
    } catch (e) { say(e.message, "bad"); }
  }

  form.addEventListener("submit", submit);
  $("#test").addEventListener("click", testTarget);
  $("#refresh").addEventListener("click", async () => {
    try { await load(); await checkAll(); } catch (e) { say(e.message, "bad"); }
  });
  load().then(checkAll).catch((e) => say(e.message, "bad"));
})();
