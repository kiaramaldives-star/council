// Link previews for shared pages (Facebook, Viber, WhatsApp, X).
// /s/news/<id>, /s/iulaan/<id>, /s/press/<id> -> page with Open Graph tags, then opens the article.
const SB_URL = "https://tmjjrhdwuoencmtmolvs.supabase.co";
const SB_KEY = "sb_publishable_BG4KiDiwGlQUmMb9vDqG2g_KvrRmhdx";
const SITE = "ގއ. ކޮނޑޭ ކައުންސިލް";
const SECTION = { news: "news", iulaan: "announcements", press: "press" };
const KIND = { tender: "ބީލަން", job: "ވަޒީފާ", notice: "އިޢުލާން", other: "އިޢުލާން" };

const esc = s => String(s ?? "").replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;");
const clip = (s, n) => { s = String(s || "").replace(/\s+/g, " ").trim(); return s.length > n ? s.slice(0, n - 1).trim() + "…" : s; };
const okUrl = u => /^https:\/\/[^\s"'<>]+$/i.test(u || "");

module.exports = async (req, res) => {
  const type = String(req.query.type || "").toLowerCase();
  const id = String(req.query.id || "").replace(/[^\w.-]/g, "").slice(0, 80);
  const host = req.headers["x-forwarded-host"] || req.headers.host || "council-sigma-five.vercel.app";
  const origin = "https://" + host;
  const target = SECTION[type] && id ? `${origin}/#${type}-${id}` : `${origin}/`;

  let title = SITE, desc = "ގއ. ކޮނޑޭ ކައުންސިލްގެ ރަސްމީ ވެބްސައިޓް · Official website of Kondey Council, Ga. Kondey, Maldives";
  let image = `${origin}/share-card.jpg`, kind = "website";

  try {
    if (SECTION[type] && id) {
      const r = await fetch(`${SB_URL}/rest/v1/content?select=data&section=eq.${SECTION[type]}&published=eq.true&order=position.asc&limit=2000`, { headers: { apikey: SB_KEY } });
      const rows = r.ok ? await r.json() : [];
      const list = rows.map(x => x.data || {});
      let item = list.find(d => String(d.id) === id);
      if (!item && type === "news") item = list.find((d, i) => ((d.url || "").replace(/\/$/, "").split("/").pop() || "n" + i) === id);
      if (item) {
        kind = "article";
        if (type === "news") {
          title = clip(item.title, 110);
          const pts = Array.isArray(item.points) ? item.points.join(" · ") : (item.points || "");
          desc = clip(item.summary && item.summary.trim() ? item.summary : (item.body || pts || desc), 200);
          if (okUrl(item.img)) image = item.img;
        } else if (type === "iulaan") {
          title = clip(item.dv, 110);
          desc = clip([KIND[item.kind] || "އިޢުލާން", item.ref, item.date].filter(Boolean).join(" · ") + (item.body ? " — " + item.body : ""), 200);
        } else {
          title = clip(item.dv, 110);
          desc = clip(["ނޫސް ބަޔާން", item.date].filter(Boolean).join(" · ") + (item.body ? " — " + item.body : ""), 200);
          if (okUrl(item.img)) image = item.img;
        }
      }
    }
  } catch (e) { /* fall back to site card */ }

  const ua = String(req.headers["user-agent"] || "");
  const isBot = /facebookexternalhit|facebot|meta-externalagent|twitterbot|whatsapp|viber|telegrambot|slackbot|linkedinbot|discordbot|skypeuripreview|pinterest|embedly|googlebot|bingbot|applebot|redditbot|vkshare|line-poker|kakaotalk|snapchat|instagram/i.test(ua);
  const self = origin + "/s/" + type + "/" + id;
  const full = title === SITE ? `${SITE} | Kondey Council` : `${title} | ${SITE}`;
  res.setHeader("Content-Type", "text/html; charset=utf-8");
  res.setHeader("Cache-Control", "public, s-maxage=600, stale-while-revalidate=86400");
  res.setHeader("Vary", "User-Agent");
  res.status(200).send(`<!DOCTYPE html><html lang="dv" dir="rtl"><head><meta charset="utf-8">
<title>${esc(full)}</title>
<meta name="description" content="${esc(desc)}">
<link rel="canonical" href="${esc(SECTION[type] && id ? self : origin + "/")}">
<meta property="og:type" content="${kind}">
<meta property="og:site_name" content="${esc(SITE)} · Kondey Council">
<meta property="og:locale" content="dv_MV">
<meta property="og:title" content="${esc(title)}">
<meta property="og:description" content="${esc(desc)}">
<meta property="og:url" content="${esc(SECTION[type] && id ? self : origin + "/")}">
<meta property="og:image:width" content="1200"><meta property="og:image:height" content="630">
<meta property="og:image" content="${esc(image)}">
<meta property="og:image:alt" content="${esc(title)}">
<meta name="twitter:card" content="summary_large_image">
<meta name="twitter:title" content="${esc(title)}">
<meta name="twitter:description" content="${esc(desc)}">
<meta name="twitter:image" content="${esc(image)}">
<meta name="theme-color" content="#C8102E">
${isBot ? "" : `<meta http-equiv="refresh" content="0;url=${esc(target)}">`}
</head><body>${isBot ? "" : `<script>location.replace(${JSON.stringify(target)})</script>`}
<p><a href="${esc(target)}">${esc(title)}</a></p></body></html>`);
};
