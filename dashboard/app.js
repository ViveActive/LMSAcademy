/* Voortgangsdashboard naast The Huddle.
 * Leest de rapportageviews uit Supabase (of demo-data.json als er geen config.js is)
 * en toont totaal-, groeps- en individueel niveau. Geen build-stap nodig.
 */
(function () {
  "use strict";

  const STATUSES = ["Actief", "Afnemend", "Inactief", "Uitgevallen", "Nooit actief"];
  const statusClass = (s) => (s === "Nooit actief" ? "Nooit" : s);
  const app = document.getElementById("app");
  let DATA = null;
  let sb = null;
  let DEMO = false;

  // ---------------------------------------------------------------- helpers
  const esc = (v) => String(v ?? "").replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));
  const pct = (a, b) => (b ? Math.round((100 * a) / b) : 0);
  const num = (v) => (v === null || v === undefined ? "–" : v);
  const fmtDate = (d) => (d ? new Date(d).toLocaleDateString("nl-NL", { day: "numeric", month: "short", year: "numeric" }) : "–");
  const ago = (days) => {
    if (days === null || days === undefined) return "nooit";
    if (days <= 0) return "vandaag";
    if (days === 1) return "gisteren";
    return `${days} dagen geleden`;
  };
  const by = (key, dir = 1) => (a, b) => {
    const x = a[key], y = b[key];
    if (x === y) return 0;
    if (x === null || x === undefined) return 1;
    if (y === null || y === undefined) return -1;
    return (x > y ? 1 : -1) * dir;
  };
  const badge = (s) => `<span class="badge st-${statusClass(s)}">${esc(s)}</span>`;
  const progressBar = (v, color = "var(--brand)") =>
    `<div class="bar"><div class="track"><div style="width:${v || 0}%;background:${color}"></div></div><span>${num(v)}${v === null || v === undefined ? "" : "%"}</span></div>`;

  function weekStarts(n = 12) {
    const now = new Date();
    const day = (now.getUTCDay() + 6) % 7; // maandag = 0
    const monday = new Date(Date.UTC(now.getUTCFullYear(), now.getUTCMonth(), now.getUTCDate() - day));
    const out = [];
    for (let i = n - 1; i >= 0; i--) out.push(new Date(monday.getTime() - i * 7 * 864e5).toISOString().slice(0, 10));
    return out;
  }

  // ---------------------------------------------------------------- data
  async function fetchAll(table, opts = {}) {
    const rows = [];
    const page = 1000;
    for (let from = 0; ; from += page) {
      let q = sb.from(table).select("*").range(from, from + page - 1);
      if (opts.filter) q = opts.filter(q);
      const { data, error } = await q;
      if (error) throw new Error(`${table}: ${error.message}`);
      rows.push(...data);
      if (data.length < page) break;
    }
    return rows;
  }

  async function loadData() {
    if (DEMO) {
      const res = await fetch("demo-data.json");
      const d = await res.json();
      for (const k of Object.keys(d)) if (d[k] === null) d[k] = [];
      return d;
    }
    const names = ["v_totals", "v_group_summary", "v_member_status", "v_module_progress", "v_module_funnel",
                   "v_weekly_activity", "groups", "modules", "settings"];
    const results = await Promise.all(names.map((n) => fetchAll(n)));
    const d = Object.fromEntries(names.map((n, i) => [n, results[i]]));
    d.memberships = await fetchAll("memberships", { filter: (q) => q.is("until", null) });
    d.v_member_timeline = []; // per lid op te halen
    return d;
  }

  async function timelineFor(memberId) {
    if (DEMO) return DATA.v_member_timeline.filter((t) => t.member_id === memberId).sort(by("at", -1)).slice(0, 30);
    const { data, error } = await sb.from("v_member_timeline").select("*").eq("member_id", memberId).order("at", { ascending: false }).limit(30);
    if (error) throw error;
    return data;
  }

  // Afgeleide gegevens
  const groupName = (id) => (DATA.groups.find((g) => g.id === id) || {}).name || id;
  const membersOf = (groupId) => {
    const ids = new Set(DATA.memberships.filter((m) => m.group_id === groupId).map((m) => m.member_id));
    return DATA.v_member_status.filter((m) => ids.has(m.huddle_id));
  };
  const orderedModules = () => [...DATA.modules].sort((a, b) => (a.position ?? 999) - (b.position ?? 999) || a.name.localeCompare(b.name));

  function summarize(members) {
    const n = members.length;
    const count = (s) => members.filter((m) => m.status === s).length;
    const withProg = members.filter((m) => m.voortgang_pct !== null && m.voortgang_pct !== undefined);
    const quizTotal = members.reduce((a, m) => a + (m.quizpogingen || 0), 0);
    const quizOk = members.reduce((a, m) => a + (m.quiz_gehaald || 0), 0);
    return {
      n,
      byStatus: Object.fromEntries(STATUSES.map((s) => [s, count(s)])),
      voortgang: withProg.length ? Math.round(withProg.reduce((a, m) => a + Number(m.voortgang_pct), 0) / withProg.length) : null,
      cert: members.filter((m) => m.certificaat_status === "Geldig" || m.certificaat_status === "Verloopt binnenkort").length,
      certSoon: members.filter((m) => m.certificaat_status === "Verloopt binnenkort").length,
      quiz: quizTotal ? pct(quizOk, quizTotal) : null,
    };
  }

  function funnelFor(memberIds) {
    const rows = memberIds ? DATA.v_module_progress.filter((r) => memberIds.has(r.member_id)) : DATA.v_module_progress;
    return orderedModules().map((m, i) => {
      const r = rows.filter((x) => x.module_id === m.id);
      const uniq = (f) => new Set(r.filter(f).map((x) => x.member_id)).size;
      return { ...m, nr: i + 1, gestart: uniq((x) => x.started_at), voltooid: uniq((x) => x.completed_at), vast: uniq((x) => x.vastgelopen) };
    });
  }

  function weeklyActive(memberIds) {
    const weeks = weekStarts();
    const rows = memberIds ? DATA.v_weekly_activity.filter((r) => memberIds.has(r.member_id)) : DATA.v_weekly_activity;
    return weeks.map((w) => ({ week: w, n: new Set(rows.filter((r) => String(r.week).slice(0, 10) === w).map((r) => r.member_id)).size }));
  }

  // ---------------------------------------------------------------- bouwstenen
  function kpiCards(s, label) {
    return `<div class="grid kpis">
      <div class="card"><div class="lbl">Actief, laatste ${esc(setting("actief_dagen"))} dagen</div>
        <div class="big">${s.byStatus.Actief} <small>van ${s.n}</small></div>
        <div class="note">${pct(s.byStatus.Actief, s.n)}% van ${esc(label)}</div></div>
      <div class="card"><div class="lbl">Langer dan ${esc(setting("afnemend_dagen"))} dagen niets</div>
        <div class="big">${s.byStatus.Inactief + s.byStatus.Uitgevallen + s.byStatus["Nooit actief"]} <small>van ${s.n}</small></div>
        <div class="note">waarvan ${s.byStatus["Nooit actief"]} nog nooit actief</div></div>
      <div class="card"><div class="lbl">Gem. voortgang</div>
        <div class="big">${num(s.voortgang)}${s.voortgang === null ? "" : "%"}</div>
        <div class="note">over de verplichte modules</div></div>
      <div class="card"><div class="lbl">Toetsen gehaald</div>
        <div class="big">${num(s.quiz)}${s.quiz === null ? "" : "%"}</div>
        <div class="note">van alle quizpogingen</div></div>
      <div class="card"><div class="lbl">Gecertificeerd</div>
        <div class="big">${s.cert} <small>van ${s.n}</small></div>
        <div class="note">${s.certSoon} verloopt binnenkort</div></div>
    </div>`;
  }

  function statusDistribution(s) {
    const segs = STATUSES.map((st) => `<div class="c-${statusClass(st)}" style="width:${pct(s.byStatus[st], s.n)}%" title="${esc(st)}: ${s.byStatus[st]}"></div>`).join("");
    const legend = STATUSES.map((st) => `<span><span class="dot c-${statusClass(st)}"></span>${esc(st)} <strong>${s.byStatus[st]}</strong></span>`).join("");
    return `<div class="card"><div class="cardhead"><h2>Activiteit</h2><span class="note">status op basis van laatste leergebeurtenis</span></div>
      <div class="stack" role="img" aria-label="Verdeling over statussen">${segs}</div><div class="legend">${legend}</div></div>`;
  }

  function weeklyChart(memberIds) {
    const w = weeklyActive(memberIds);
    const max = Math.max(1, ...w.map((x) => x.n));
    const cols = w.map((x) => `<div class="col" title="Week van ${esc(fmtDate(x.week))}: ${x.n} leden"><span>${x.n}</span><div style="height:${(100 * x.n) / max}%"></div></div>`).join("");
    const labels = w.map((x, i) => `<span>${i % 2 === 0 ? esc(new Date(x.week).toLocaleDateString("nl-NL", { day: "numeric", month: "short" })) : ""}</span>`).join("");
    return `<div class="card"><div class="cardhead"><h2>Actieve leden per week</h2><span class="note">laatste 12 weken</span></div>
      <div class="weeks" role="img" aria-label="Aantal actieve leden per week">${cols}</div><div class="weeklabels">${labels}</div></div>`;
  }

  function funnelCard(memberIds, title = "Waar haken mensen af?") {
    const f = funnelFor(memberIds);
    const max = Math.max(1, ...f.map((m) => m.gestart));
    const rows = f.map((m) => `<div class="row"><div><strong>${m.nr}. ${esc(m.name)}</strong>${m.required ? "" : ' <small class="note">(keuze)</small>'}</div><div>
        <div class="bar"><div class="track" style="height:10px"><div style="width:${(100 * m.gestart) / max}%;background:var(--started)"></div></div><span>${m.gestart} gestart</span></div>
        <div class="bar"><div class="track" style="height:10px"><div style="width:${(100 * m.voltooid) / max}%;background:var(--done)"></div></div><span>${m.voltooid} voltooid${m.vast ? ` · ${m.vast} vast` : ""}</span></div>
      </div></div>`).join("");
    return `<div class="card"><div class="cardhead"><h2>${esc(title)}</h2></div>
      <p class="note" style="margin:0 0 12px">Per module: hoeveel leden zijn gestart en hoeveel hebben afgerond. "Vast" = gestart, niet afgerond en ${esc(setting("vastgelopen_dagen"))} dagen geen activiteit.</p>
      <div class="funnel">${rows || '<p class="empty">Nog geen modulegegevens ontvangen.</p>'}</div></div>`;
  }

  function attentionCard(members) {
    const list = members.filter((m) => m.status === "Inactief" || m.status === "Uitgevallen" || m.modules_open > 0 && m.dagen_inactief > Number(setting("vastgelopen_dagen")))
      .sort(by("dagen_inactief", -1)).slice(0, 8);
    const items = list.map((m) => `<div class="item"><div><a href="#/lid/${encodeURIComponent(m.huddle_id)}"><strong>${esc(m.naam || m.email)}</strong></a>
        <div class="note" style="margin:0">${esc(m.groepen || "geen groep")} · laatst actief ${esc(ago(m.dagen_inactief))}</div></div>
        <div style="display:flex;gap:8px;align-items:center">${badge(m.status)}${m.email ? `<a class="btn" style="min-height:32px;font-size:12px" href="mailto:${esc(m.email)}">Mail</a>` : ""}</div></div>`).join("");
    return `<div class="card attn"><div class="cardhead"><h2>Aandacht nodig</h2><a href="#/leden?status=Inactief">Alle inactieve leden</a></div>
      <div class="list">${items || '<p class="empty">Niemand op dit moment.</p>'}</div></div>`;
  }

  function memberTable(members, { showGroup = true } = {}) {
    const st = state.sort;
    const cols = [
      ["naam", "Naam"], ...(showGroup ? [["groepen", "Groep"]] : []), ["status", "Status"], ["dagen_inactief", "Laatst actief"],
      ["voortgang_pct", "Voortgang"], ["quiz_slagingspct", "Toetsen"], ["certificaat_status", "Certificaat"],
    ];
    const sorted = [...members].sort(by(st.key, st.dir));
    const head = cols.map(([k, l]) => `<th scope="col"><button data-sort="${k}">${esc(l)}${st.key === k ? (st.dir > 0 ? " ↑" : " ↓") : ""}</button></th>`).join("");
    const rows = sorted.map((m) => `<tr class="click" data-href="#/lid/${encodeURIComponent(m.huddle_id)}">
        <td><a href="#/lid/${encodeURIComponent(m.huddle_id)}">${esc(m.naam || "(geen naam)")}</a><small>${esc(m.email || "")}</small></td>
        ${showGroup ? `<td>${esc(m.groepen || "–")}</td>` : ""}
        <td>${badge(m.status)}</td>
        <td>${esc(ago(m.dagen_inactief))}</td>
        <td style="min-width:140px">${progressBar(m.voortgang_pct)}</td>
        <td>${m.quizpogingen ? `${m.quiz_gehaald}/${m.quizpogingen}` : "–"}</td>
        <td>${esc(m.certificaat_status)}${m.certificaat_geldig_tot && m.certificaat_status !== "Geen" ? `<small>tot ${esc(fmtDate(m.certificaat_geldig_tot))}</small>` : ""}</td>
      </tr>`).join("");
    return `<div class="tablewrap"><table><thead><tr>${head}</tr></thead><tbody>${rows || `<tr><td colspan="${cols.length}" class="empty">Geen leden gevonden.</td></tr>`}</tbody></table></div>`;
  }

  // ---------------------------------------------------------------- pagina's
  const state = { sort: { key: "dagen_inactief", dir: -1 }, filter: "Alle", group: "", q: "" };
  const setting = (k) => (DATA.settings.find((s) => s.key === k) || {}).value;

  function pageOverview() {
    const all = DATA.v_member_status;
    const s = summarize(all);
    const groups = [...DATA.v_group_summary].sort(by("name"));
    const grows = groups.map((g) => {
      const segs = STATUSES.slice(0, 4).map((st) => {
        const n = st === "Uitgevallen" ? g.uitgevallen : g[st.toLowerCase()];
        return `<div class="c-${st}" style="width:${pct(n, g.leden)}%"></div>`;
      }).join("");
      return `<tr class="click" data-href="#/groep/${encodeURIComponent(g.group_id)}">
        <td><a href="#/groep/${encodeURIComponent(g.group_id)}">${esc(g.name)}</a><small>${esc(g.kind || "")}${g.coach ? " · " + esc(g.coach) : ""}</small></td>
        <td>${g.leden}</td>
        <td style="min-width:180px"><div class="stack" style="height:10px">${segs}</div><small>${g.actief} actief · ${g.uitgevallen} uitgevallen</small></td>
        <td style="min-width:140px">${progressBar(g.gem_voortgang)}</td>
        <td>${num(g.quiz_slagingspct)}${g.quiz_slagingspct === null ? "" : "%"}</td>
        <td>${g.gecertificeerd} van ${g.leden}</td></tr>`;
    }).join("");
    return `<div class="pagehead"><div><h1>Overzicht</h1><p class="sub">Alle groepen · ${s.n} leden</p></div></div>
      ${kpiCards(s, "alle leden")}
      <div class="grid two">${statusDistribution(s)}${weeklyChart(null)}</div>
      ${attentionCard(all)}
      <div class="card"><div class="cardhead"><h2>Per groep</h2><a href="#/groepen">Alle groepen</a></div>
        <div class="tablewrap"><table><thead><tr><th>Groep</th><th>Leden</th><th>Activiteit</th><th>Gem. voortgang</th><th>Toetsen</th><th>Gecertificeerd</th></tr></thead>
        <tbody>${grows || '<tr><td colspan="6" class="empty">Nog geen groepen. Lees een CSV-export in of wacht op toegangsniveau-webhooks.</td></tr>'}</tbody></table></div></div>
      ${funnelCard(null)}`;
  }

  function pageGroups() {
    const cards = [...DATA.v_group_summary].sort(by("name")).map((g) => `<div class="card">
        <h2><a href="#/groep/${encodeURIComponent(g.group_id)}">${esc(g.name)}</a></h2>
        <p class="sub">${esc(g.kind || "Groep")} · ${g.leden} leden${g.coach ? " · begeleid door " + esc(g.coach) : ""}</p>
        <div class="grid" style="grid-template-columns:repeat(3,1fr);margin-top:12px">
          <div><div class="lbl">Actief</div><div class="h" style="font-size:22px;font-weight:700">${g.actief}</div></div>
          <div><div class="lbl">Voortgang</div><div class="h" style="font-size:22px;font-weight:700">${num(g.gem_voortgang)}%</div></div>
          <div><div class="lbl">Uitgevallen</div><div class="h" style="font-size:22px;font-weight:700">${g.uitgevallen}</div></div>
        </div>
        <p style="margin:12px 0 0"><a class="btn" href="#/groep/${encodeURIComponent(g.group_id)}">Groep openen</a></p></div>`).join("");
    return `<div class="pagehead"><div><h1>Groepen</h1><p class="sub">Een groep is een toegangsniveau in The Huddle</p></div></div>
      <div class="grid two">${cards || '<p class="empty">Nog geen groepen.</p>'}</div>`;
  }

  function pageGroup(id) {
    const g = DATA.groups.find((x) => x.id === id);
    if (!g) return `<a class="back" href="#/groepen">← Alle groepen</a><p>Groep niet gevonden.</p>`;
    const members = membersOf(id);
    const ids = new Set(members.map((m) => m.huddle_id));
    const s = summarize(members);
    return `<div><a class="back" href="#/groepen">← Alle groepen</a>
        <div class="pagehead"><div><h1>${esc(g.name)}</h1><p class="sub">${esc(g.kind || "Groep")} · ${s.n} leden${g.coach ? " · begeleid door " + esc(g.coach) : ""}</p></div></div></div>
      ${kpiCards(s, "deze groep")}
      <div class="grid two">${statusDistribution(s)}${weeklyChart(ids)}</div>
      <div class="card"><div class="cardhead"><h2>Leden</h2></div>${memberTable(members, { showGroup: false })}</div>
      ${funnelCard(ids, "Modules in deze groep")}`;
  }

  function pageMembers(params) {
    const status = params.get("status") || state.filter;
    const group = params.get("groep") ?? state.group;
    state.filter = status; state.group = group;
    let list = DATA.v_member_status;
    if (group) list = membersOf(group);
    const counts = Object.fromEntries(STATUSES.map((s) => [s, list.filter((m) => m.status === s).length]));
    if (status !== "Alle") list = list.filter((m) => m.status === status);
    const q = state.q.trim().toLowerCase();
    if (q) list = list.filter((m) => `${m.naam} ${m.email}`.toLowerCase().includes(q));
    const chips = ["Alle", ...STATUSES].map((s) => `<button class="chip" aria-pressed="${s === status}" data-status="${esc(s)}">${esc(s)}${s === "Alle" ? "" : " · " + counts[s]}</button>`).join("");
    const opts = [`<option value="">Alle groepen</option>`, ...[...DATA.groups].filter((g) => !g.hidden).sort(by("name"))
      .map((g) => `<option value="${esc(g.id)}" ${g.id === group ? "selected" : ""}>${esc(g.name)}</option>`)].join("");
    return `<div class="pagehead"><div><h1>Leden</h1><p class="sub">${list.length} getoond · klik op een naam voor details</p></div>
        <a class="btn" href="#" data-export>Exporteer CSV</a></div>
      <div class="card"><div class="filters" style="margin-bottom:12px">${chips}</div>
        <div class="filters" style="margin-bottom:12px">
          <label class="sr" for="q">Zoeken</label><input type="search" id="q" placeholder="Zoek op naam of e-mail" value="${esc(state.q)}">
          <label class="sr" for="grp">Groep</label><select id="grp">${opts}</select></div>
        ${memberTable(list)}</div>`;
  }

  async function pageMember(id) {
    const m = DATA.v_member_status.find((x) => x.huddle_id === id);
    if (!m) return `<a class="back" href="#/leden">← Leden</a><p>Lid niet gevonden.</p>`;
    const prog = DATA.v_module_progress.filter((r) => r.member_id === id);
    const mods = orderedModules().map((mod, i) => {
      const p = prog.find((r) => r.module_id === mod.id);
      let label = "Niet gestart", color = "var(--muted)", w = 0;
      if (p && p.completed_at) { label = `Voltooid ${fmtDate(p.completed_at)}`; color = "var(--s-actief)"; w = 100; }
      else if (p && p.vastgelopen) { label = `Vastgelopen, gestart ${fmtDate(p.started_at)}`; color = "var(--s-inactief)"; w = 50; }
      else if (p && p.started_at) { label = `Bezig sinds ${fmtDate(p.started_at)}`; color = "var(--s-afnemend)"; w = 50; }
      return `<div class="item"><div><strong>${i + 1}. ${esc(mod.name)}</strong>${mod.required ? "" : ' <small class="note">(keuze)</small>'}</div>
        <div style="display:flex;align-items:center;gap:10px;flex-wrap:wrap;justify-content:flex-end"><span class="mod-state" style="color:${color}">${esc(label)}</span>
        <div class="track" style="max-width:80px"><div style="width:${w}%;background:${color}"></div></div></div></div>`;
    }).join("");
    const weeks = weekStarts();
    const wa = DATA.v_weekly_activity.filter((r) => r.member_id === id);
    const maxW = Math.max(1, ...wa.map((r) => r.gebeurtenissen));
    const heat = weeks.map((w) => {
      const r = wa.find((x) => String(x.week).slice(0, 10) === w);
      const n = r ? r.gebeurtenissen : 0;
      return `<div title="Week van ${esc(fmtDate(w))}: ${n}" style="${n ? `background:var(--brand-soft);opacity:${0.35 + (0.65 * n) / maxW}` : ""}"></div>`;
    }).join("");
    let timeline = [];
    try { timeline = await timelineFor(id); } catch (e) { console.error(e); }
    const tl = timeline.map((t) => `<div class="item"><div><strong>${esc(t.kind)}</strong>${t.onderwerp ? ` · ${esc(t.onderwerp)}` : ""}</div><span class="note" style="margin:0">${esc(fmtDate(t.at))}</span></div>`).join("");
    const initials = (m.naam || m.email || "?").split(/\s+/).filter(Boolean).map((x) => x[0]).slice(0, 2).join("").toUpperCase();
    return `<div><a class="back" href="javascript:history.back()">← Terug</a>
        <div class="pagehead"><div style="display:flex;align-items:center;gap:14px">
          <div aria-hidden="true" style="width:52px;height:52px;border-radius:50%;background:var(--brand);color:#fff;display:grid;place-items:center;font-weight:700;font-size:18px">${esc(initials)}</div>
          <div><h1>${esc(m.naam || m.email)}</h1><p class="sub">${esc(m.groepen || "geen groep")} · ${esc(m.email || "")}</p></div></div>
          <div style="display:flex;gap:8px;align-items:center">${badge(m.status)}${m.email ? `<a class="btn pri" href="mailto:${esc(m.email)}">Mail sturen</a>` : ""}</div></div></div>
      <div class="grid kpis">
        <div class="card"><div class="lbl">Laatst actief</div><div class="big" style="font-size:26px">${esc(ago(m.dagen_inactief))}</div><div class="note">${m.activiteit_4w} leergebeurtenissen in 4 weken</div></div>
        <div class="card"><div class="lbl">Voortgang</div><div class="big">${num(m.voortgang_pct)}%</div><div class="note">${m.modules_voltooid} modules voltooid, ${m.modules_open} open</div></div>
        <div class="card"><div class="lbl">Toetsen</div><div class="big">${m.quizpogingen ? `${m.quiz_gehaald}<small>/${m.quizpogingen}</small>` : "–"}</div><div class="note">${m.gem_quizscore ? `gem. score ${m.gem_quizscore}` : "gehaald / pogingen"}</div></div>
        <div class="card"><div class="lbl">Certificaat</div><div class="big" style="font-size:26px">${esc(m.certificaat_status)}</div><div class="note">${m.certificaat_datum ? `uitgereikt ${esc(fmtDate(m.certificaat_datum))}, geldig tot ${esc(fmtDate(m.certificaat_geldig_tot))}` : "nog niet uitgereikt"}</div></div>
      </div>
      <div class="grid two">
        <div class="card"><div class="cardhead"><h2>Modules</h2></div><div class="list">${mods || '<p class="empty">Geen modules bekend.</p>'}</div></div>
        <div style="display:flex;flex-direction:column;gap:16px">
          <div class="card"><div class="cardhead"><h2>Activiteit per week</h2><span class="note">12 weken, donkerder = meer</span></div><div class="heat" role="img" aria-label="Activiteit per week">${heat}</div>
            <div class="weeklabels" style="margin-top:6px"><span style="text-align:left">12 weken geleden</span><span style="text-align:right">deze week</span></div></div>
          <div class="card"><div class="cardhead"><h2>Laatste gebeurtenissen</h2></div><div class="list">${tl || '<p class="empty">Nog niets ontvangen.</p>'}</div></div>
        </div></div>
      <p class="note">Lid sinds ${esc(fmtDate(m.created_at))} · eerste login ${esc(fmtDate(m.first_login_at))} · gemeten vanaf ${esc(fmtDate(m.measured_since))}</p>`;
  }

  function pageModules() {
    const f = funnelFor(null);
    const rows = f.map((m) => `<tr><td><strong>${m.nr}. ${esc(m.name)}</strong></td>
        <td><label class="inline"><input type="checkbox" data-required="${esc(m.id)}" ${m.required ? "checked" : ""}> verplicht</label></td>
        <td>${m.gestart}</td><td>${m.voltooid}</td><td>${m.vast}</td><td style="min-width:140px">${progressBar(pct(m.voltooid, m.gestart))}</td></tr>`).join("");
    return `<div class="pagehead"><div><h1>Modules</h1><p class="sub">Modules verschijnen vanzelf zodra Huddle er een gebeurtenis over stuurt</p></div></div>
      <div class="card"><div class="tablewrap"><table><thead><tr><th>Module</th><th>Telt mee</th><th>Gestart</th><th>Voltooid</th><th>Vast</th><th>Afrondpercentage</th></tr></thead>
      <tbody>${rows || '<tr><td colspan="6" class="empty">Nog geen modules ontvangen.</td></tr>'}</tbody></table></div>
      <p class="note">Alleen verplichte modules tellen mee voor de voortgang. ${DEMO ? "In de demo worden wijzigingen niet opgeslagen." : ""}</p></div>
      <div class="card"><h2>Grenzen</h2><div class="list" style="margin-top:8px">
        ${DATA.settings.map((s) => `<div class="item"><span>${esc(s.note || s.key)}</span><strong>${esc(s.value)}</strong></div>`).join("")}
      </div><p class="note">Aan te passen in de tabel <code>settings</code> in Supabase.</p></div>`;
  }

  // ---------------------------------------------------------------- export
  function exportCsv() {
    const rows = DATA.v_member_status;
    const cols = ["naam", "email", "groepen", "status", "dagen_inactief", "voortgang_pct", "modules_voltooid", "quiz_gehaald", "quizpogingen", "certificaat_status", "certificaat_geldig_tot"];
    const q = (v) => `"${String(v ?? "").replace(/"/g, '""')}"`;
    const csv = [cols.join(";"), ...rows.map((r) => cols.map((c) => q(r[c])).join(";"))].join("\r\n");
    const a = document.createElement("a");
    a.href = URL.createObjectURL(new Blob(["﻿" + csv], { type: "text/csv" }));
    a.download = `voortgang-${new Date().toISOString().slice(0, 10)}.csv`;
    a.click();
  }

  // ---------------------------------------------------------------- router
  const NAV = [["#/", "Overzicht"], ["#/groepen", "Groepen"], ["#/leden", "Leden"], ["#/modules", "Modules"]];
  function renderNav(hash) {
    const cur = hash.startsWith("#/groep") ? "#/groepen" : hash.startsWith("#/lid") || hash.startsWith("#/leden") ? "#/leden" : hash.startsWith("#/modules") ? "#/modules" : "#/";
    document.getElementById("nav").innerHTML = NAV.map(([h, l]) => `<a href="${h}" ${h === cur ? 'aria-current="page"' : ""}>${l}</a>`).join("")
      + (sb ? '<a href="#" data-logout>Uitloggen</a>' : "");
  }

  async function route() {
    const hash = location.hash || "#/";
    renderNav(hash);
    const [path, qs] = hash.slice(1).split("?");
    const params = new URLSearchParams(qs || "");
    const parts = path.split("/").filter(Boolean).map(decodeURIComponent);
    let html;
    if (parts[0] === "groepen") html = pageGroups();
    else if (parts[0] === "groep") html = pageGroup(parts[1]);
    else if (parts[0] === "leden") html = pageMembers(params);
    else if (parts[0] === "lid") html = await pageMember(parts[1]);
    else if (parts[0] === "modules") html = pageModules();
    else html = pageOverview();
    app.innerHTML = html;
    if (!hash.startsWith("#/leden")) window.scrollTo(0, 0);
  }

  // Eventdelegatie
  document.addEventListener("click", async (e) => {
    const t = e.target;
    const sortBtn = t.closest("[data-sort]");
    if (sortBtn) {
      const k = sortBtn.dataset.sort;
      state.sort = { key: k, dir: state.sort.key === k ? -state.sort.dir : 1 };
      return route();
    }
    const chip = t.closest("[data-status]");
    if (chip) { location.hash = `#/leden?status=${encodeURIComponent(chip.dataset.status)}${state.group ? "&groep=" + encodeURIComponent(state.group) : ""}`; return; }
    if (t.closest("[data-export]")) { e.preventDefault(); return exportCsv(); }
    if (t.closest("[data-logout]")) { e.preventDefault(); await sb.auth.signOut(); location.hash = "#/"; return location.reload(); }
    const row = t.closest("tr[data-href]");
    if (row && !t.closest("a,button,input")) location.hash = row.dataset.href;
  });
  document.addEventListener("input", (e) => {
    if (e.target.id === "q") {
      state.q = e.target.value;
      const pos = e.target.selectionStart;
      route().then(() => { const el = document.getElementById("q"); if (el) { el.focus(); el.setSelectionRange(pos, pos); } });
    }
  });
  document.addEventListener("change", async (e) => {
    if (e.target.id === "grp") { location.hash = `#/leden?status=${encodeURIComponent(state.filter)}${e.target.value ? "&groep=" + encodeURIComponent(e.target.value) : ""}`; }
    const req = e.target.dataset && e.target.dataset.required;
    if (req) {
      const mod = DATA.modules.find((m) => m.id === req);
      mod.required = e.target.checked;
      if (sb) {
        const { error } = await sb.from("modules").update({ required: mod.required }).eq("id", req);
        if (error) { alertBanner("Opslaan mislukt: " + error.message); return; }
        DATA = await loadData();
      }
      route();
    }
  });
  window.addEventListener("hashchange", route);

  function alertBanner(text) {
    document.getElementById("bannerText").textContent = text;
    document.getElementById("banner").hidden = false;
  }

  // ---------------------------------------------------------------- login en start
  function loginPage(msg) {
    document.getElementById("nav").innerHTML = "";
    app.innerHTML = `<div class="card login"><h1>Inloggen</h1><p class="sub">Alleen voor beheerders. Je krijgt een inloglink per e-mail.</p>
      <form id="login"><label for="email">E-mailadres</label><input id="email" type="email" required autocomplete="email">
      <button class="btn pri" type="submit">Stuur inloglink</button></form><p class="note" id="loginmsg">${esc(msg || "")}</p></div>`;
    document.getElementById("login").addEventListener("submit", async (e) => {
      e.preventDefault();
      const email = document.getElementById("email").value;
      const { error } = await sb.auth.signInWithOtp({ email, options: { emailRedirectTo: location.origin + location.pathname, shouldCreateUser: false } });
      document.getElementById("loginmsg").textContent = error ? `Dat lukte niet: ${error.message}` : "Check je mail voor de inloglink.";
    });
  }

  async function start() {
    const cfg = window.APP_CONFIG;
    DEMO = !cfg || !cfg.supabaseUrl;
    if (!DEMO) {
      sb = window.supabase.createClient(cfg.supabaseUrl, cfg.supabaseAnonKey);
      const { data } = await sb.auth.getSession();
      if (!data.session) return loginPage();
    }
    try {
      DATA = await loadData();
    } catch (e) {
      app.innerHTML = `<div class="card"><h2>Gegevens laden mislukt</h2><p>${esc(e.message)}</p></div>`;
      return;
    }
    if (DEMO) alertBanner("Demo met verzonnen voorbeelddata, geen echte personen.");
    else if (!DATA.v_member_status.length && !DATA.groups.length) alertBanner("Nog geen gegevens. Lees een CSV-export in of controleer of de webhooks in Huddle aan staan. Zie je hier nooit iets, controleer dan of je e-mailadres in de tabel admins staat.");
    else {
      const since = DATA.v_totals[0] && DATA.v_totals[0].gemeten_sinds;
      alertBanner(`"Actief" telt leergebeurtenissen uit Huddle (module, cursus, quiz, certificaat). Gemeten sinds ${fmtDate(since)}.`);
    }
    route();
  }
  start();
})();
