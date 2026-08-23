// One-off generator for architecture-diagram.svg (larger fonts, auto-sized boxes)
function escapeXml(s) {
  return String(s).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
}
function charW(ch, bold) {
  const code = ch.codePointAt(0);
  if (code > 0x2e80) return bold ? 1.05 : 1.0; // CJK-ish wide chars
  return bold ? 0.62 : 0.55; // latin avg
}
function measureText(text, size, bold) {
  let w = 0;
  for (const ch of text) w += charW(ch, bold) * size;
  return w;
}

let uid = 0;
function box(x, y, lines, opts = {}) {
  const padX = opts.padX ?? 22;
  const padY = opts.padY ?? 18;
  const lineGap = opts.lineGap ?? 7;
  const stroke = opts.stroke ?? '#2563eb';
  const fill = opts.fill ?? '#ffffff';
  const rx = opts.rx ?? 10;
  let minWidth = opts.minWidth ?? 0;
  let maxTextW = 0;
  lines.forEach((l) => {
    maxTextW = Math.max(maxTextW, measureText(l.text, l.size, !!l.bold));
  });
  const totalTextH = lines.reduce((a, l) => a + l.size * 1.25, 0) + lineGap * (lines.length - 1);
  const w = Math.max(minWidth, maxTextW + padX * 2);
  const h = totalTextH + padY * 2;
  const cx = x + w / 2;
  let curY = y + padY;
  let textEls = '';
  lines.forEach((l) => {
    curY += l.size;
    textEls += `<text x="${cx.toFixed(1)}" y="${curY.toFixed(1)}" text-anchor="middle" font-size="${l.size}"${l.bold ? ' font-weight="600"' : ''} fill="${l.color || '#0f172a'}">${escapeXml(l.text)}</text>\n`;
    curY += l.size * 0.25 + lineGap;
  });
  const rectEl = `<rect x="${x.toFixed(1)}" y="${y.toFixed(1)}" width="${w.toFixed(1)}" height="${h.toFixed(1)}" rx="${rx}" fill="${fill}" stroke="${stroke}" stroke-width="2.5"/>\n`;
  return { x, y, w, h, cx, cy: y + h / 2, right: x + w, bottom: y + h, svg: rectEl + textEls };
}
function arrow(x1, y1, x2, y2) {
  return `<line x1="${x1.toFixed(1)}" y1="${y1.toFixed(1)}" x2="${x2.toFixed(1)}" y2="${y2.toFixed(1)}" stroke="#475569" stroke-width="2.5" marker-end="url(#arrow)"/>\n`;
}
function arrowPath(points) {
  const d = points.map((p, i) => (i === 0 ? 'M' : 'L') + p[0].toFixed(1) + ' ' + p[1].toFixed(1)).join(' ');
  return `<path d="${d}" fill="none" stroke="#475569" stroke-width="2.5" marker-end="url(#arrow)"/>\n`;
}
function wrap(local, x, y) {
  return `<g transform="translate(${x.toFixed(1)},${y.toFixed(1)})">\n${local.svg}</g>\n`;
}

const T = 20; // detail font
const TT = 22; // box title font
const HDR = 26; // section header font

// ---------- CI/CD ----------
function buildCICD() {
  let x = 0;
  const y0 = 0;
  const gap = 55;
  const defs = [
    { title: 'GitHub repo', lines: ['kanjtomi1967-blog', '(public)'] },
    { title: 'Jenkins', lines: ['job: BlogDeploy', 'Poll SCM  H/5 * * * *', 'local Windows agent'] },
    { title: 'Build', lines: ['hugo --minify', '→ .\\public'] },
    { title: 'Rebuild RAG Index', lines: ['rag-index (Java/Maven CLI)', 'chunks posts, embeds via', 'Voyage AI → index.json'] },
    { title: 'Deploy', lines: ['s3 sync public → site bucket', 's3 cp index.json → RAG bucket', '(aws-blog-deploy-creds)'] },
    { title: 'CloudFront Invalidation', lines: ['aws cloudfront', 'create-invalidation --paths "/*"'] },
  ];
  let svg = '';
  const boxes = [];
  for (const d of defs) {
    const lines = [{ text: d.title, size: TT, bold: true }, ...d.lines.map((t) => ({ text: t, size: T, color: '#475569' }))];
    const b = box(x, y0, lines, { stroke: '#2563eb' });
    boxes.push(b);
    svg += b.svg;
    x = b.right + gap;
  }
  for (let i = 0; i < boxes.length - 1; i++) {
    const a = boxes[i], c = boxes[i + 1];
    svg += arrow(a.right + 8, a.cy, c.x - 8, c.cy);
  }
  const w = boxes[boxes.length - 1].right;
  const h = Math.max(...boxes.map((b) => b.bottom));
  return { svg, w, h, boxes };
}

// ---------- DNS / CDN ----------
function buildDNS() {
  let svg = '';
  const route53 = box(0, 0, [
    { text: 'Route 53', size: TT, bold: true },
    { text: 'hosted zone kanjtomi1967.net', size: T, color: '#475569' },
    { text: '(pre-existing, data source)', size: T, color: '#475569' },
  ], { stroke: '#16a34a' });

  const cfSite = box(route53.right + 55, 0, [
    { text: 'CloudFront (site)', size: TT, bold: true },
    { text: 'E1E2XGWP46PS1T', size: T, color: '#475569' },
    { text: 'ACM cert (us-east-1)', size: T, color: '#475569' },
  ], { stroke: '#16a34a' });

  const s3 = box(cfSite.right + 55, 0, [
    { text: 'S3 (via OAC)', size: TT, bold: true },
    { text: 'www.kanjtomi1967.net', size: T, color: '#475569' },
    { text: 'static site bucket', size: T, color: '#475569' },
  ], { stroke: '#16a34a' });

  svg += route53.svg + cfSite.svg + s3.svg;
  svg += arrow(route53.right + 8, route53.cy, cfSite.x - 8, cfSite.cy);
  svg += arrow(cfSite.right + 8, cfSite.cy, s3.x - 8, s3.cy);

  const row2y = Math.max(route53.bottom, cfSite.bottom, s3.bottom) + 45;
  const cfFunc = box(cfSite.x, row2y, [
    { text: 'CF Function "hugo-directory-index-rewrite" (viewer-request)', size: T, bold: true },
    { text: '/posts/x/ → /posts/x/index.html  (fixes OAC 403 on subdirectories)', size: T, color: '#475569' },
  ], { stroke: '#d97706', fill: '#fffbeb', minWidth: s3.right - cfSite.x });
  svg += cfFunc.svg;
  svg += arrow(cfSite.cx, cfSite.bottom + 8, cfFunc.cx, cfFunc.y - 8);

  const row3y = cfFunc.bottom + 45;
  const cfRedirect = box(route53.x, row3y, [
    { text: 'CloudFront (redirect)', size: TT, bold: true },
    { text: 'E2C6IE1U5L07Z1', size: T, color: '#475569' },
    { text: 'apex: kanjtomi1967.net', size: T, color: '#475569' },
  ], { stroke: '#16a34a' });
  const cfRedirFunc = box(cfFunc.x, row3y, [
    { text: 'CF Function (viewer-request)', size: T, bold: true },
    { text: '301 → https://www.kanjtomi1967.net<uri>', size: T, color: '#475569' },
    { text: '(no origin fetch — no S3 bucket needed)', size: T, color: '#475569' },
  ], { stroke: '#d97706', fill: '#fffbeb', minWidth: cfFunc.w });
  svg += cfRedirect.svg + cfRedirFunc.svg;
  svg += arrow(route53.cx, route53.bottom + 8, route53.cx, cfRedirect.y - 8);
  svg += arrow(cfRedirect.right + 8, cfRedirect.cy, cfRedirFunc.x - 8, cfRedirFunc.cy);

  const w = Math.max(s3.right, cfFunc.right, cfRedirFunc.right);
  const h = cfRedirFunc.bottom;
  return { svg, w, h, s3, route53, cfSite };
}

// ---------- Browser hub ----------
function buildHub() {
  const b = box(0, 0, [
    { text: 'Visitor Browser', size: TT, bold: true },
    { text: 'page JS: comments.html,', size: T, color: '#475569' },
    { text: 'search.html', size: T, color: '#475569' },
  ], { stroke: '#0f172a' });
  return { svg: b.svg, w: b.w, h: b.h, box: b };
}

// ---------- Comment system ----------
function buildComments() {
  let svg = '';
  const turnstile = box(0, 0, [
    { text: 'Cloudflare Turnstile', size: TT, bold: true },
    { text: 'verifies human on', size: T, color: '#475569' },
    { text: 'POST /comments', size: T, color: '#475569' },
  ], { stroke: '#db2777' });

  const apiGw = box(turnstile.right + 55, 0, [
    { text: 'API Gateway (HTTP API)', size: TT, bold: true },
    { text: 'POST /comments · GET /comments?slug=', size: T, color: '#475569' },
    { text: 'GET/POST /admin/*  (x-api-key)', size: T, color: '#475569' },
  ], { stroke: '#db2777' });

  const lambda = box(apiGw.right + 55, 0, [
    { text: 'Lambda', size: TT, bold: true },
    { text: 'blog-comments', size: T, color: '#475569' },
    { text: 'Java 17, routed by routeKey', size: T, color: '#475569' },
  ], { stroke: '#db2777' });

  svg += turnstile.svg + apiGw.svg + lambda.svg;
  svg += arrow(turnstile.right + 8, turnstile.cy, apiGw.x - 8, apiGw.cy);
  svg += arrow(apiGw.right + 8, apiGw.cy, lambda.x - 8, lambda.cy);

  const row2y = Math.max(turnstile.bottom, apiGw.bottom, lambda.bottom) + 45;
  const s3 = box(apiGw.x, row2y, [
    { text: 'S3 comments bucket', size: TT, bold: true },
    { text: '...-comments  (private)', size: T, color: '#475569' },
    { text: 'comments/{slug}/{id}.json', size: T, color: '#475569' },
    { text: '(status: pending / approved)', size: T, color: '#475569' },
  ], { stroke: '#db2777' });

  const admin = box(lambda.x, row2y, [
    { text: 'Admin (curl / PowerShell)', size: TT, bold: true },
    { text: 'x-api-key header', size: T, color: '#475569' },
    { text: 'approves pending comments', size: T, color: '#475569' },
  ], { stroke: '#db2777', minWidth: lambda.w });

  svg += s3.svg + admin.svg;
  svg += arrow(lambda.cx, lambda.bottom + 8, s3.cx, s3.y - 8);
  svg += arrowPath([[admin.x - 8, admin.cy], [apiGw.cx, admin.cy], [apiGw.cx, apiGw.bottom + 6]]);

  const w = Math.max(lambda.right, s3.right, admin.right);
  const h = Math.max(s3.bottom, admin.bottom);
  return { svg, w, h, apiGw };
}

// ---------- RAG search ----------
function buildRAG() {
  let svg = '';
  const turnstile = box(0, 0, [
    { text: 'Cloudflare Turnstile', size: TT, bold: true },
    { text: 'verifies human on', size: T, color: '#475569' },
    { text: 'POST /ask', size: T, color: '#475569' },
  ], { stroke: '#7c3aed' });

  const apiGw = box(turnstile.right + 55, 0, [
    { text: 'API Gateway (HTTP API)', size: TT, bold: true },
    { text: 'POST /ask · POST /mcp', size: T, color: '#475569' },
    { text: 'throttle: burst 5 / rate 2 (shared)', size: T, color: '#475569' },
  ], { stroke: '#7c3aed' });

  const lambda = box(apiGw.right + 55, 0, [
    { text: 'Lambda blog-rag', size: TT, bold: true },
    { text: 'ask(): calls Claude via MCP connector', size: T, color: '#475569' },
    { text: 'mcp(): serves the search_blog_posts tool', size: T, color: '#475569' },
  ], { stroke: '#7c3aed' });

  svg += turnstile.svg + apiGw.svg + lambda.svg;
  svg += arrow(turnstile.right + 8, turnstile.cy, apiGw.x - 8, apiGw.cy);
  svg += arrow(apiGw.right + 8, apiGw.cy, lambda.x - 8, lambda.cy);

  const row2y = Math.max(turnstile.bottom, apiGw.bottom, lambda.bottom) + 45;
  const s3 = box(0, row2y, [
    { text: 'S3 RAG index bucket', size: TT, bold: true },
    { text: '...-rag-index  (private)', size: T, color: '#475569' },
    { text: 'index.json — cached per', size: T, color: '#475569' },
    { text: 'warm execution environment', size: T, color: '#475569' },
  ], { stroke: '#7c3aed' });

  const voyage = box(s3.right + 55, row2y, [
    { text: 'Voyage AI API', size: TT, bold: true },
    { text: 'voyage-3-lite', size: T, color: '#475569' },
    { text: 'embeds the tool-call query', size: T, color: '#475569' },
  ], { stroke: '#7c3aed' });

  const claude = box(voyage.right + 55, row2y, [
    { text: 'Claude API (beta)', size: TT, bold: true },
    { text: 'claude-haiku-4-5, MCP connector', size: T, color: '#475569' },
    { text: 'decides whether to call search_blog_posts', size: T, color: '#475569' },
    { text: '↩ tool call via API Gateway POST /mcp', size: T, color: '#475569' },
    { text: '  (bearer-auth: MCP_SHARED_SECRET)', size: T, color: '#475569' },
  ], { stroke: '#7c3aed' });

  svg += s3.svg + voyage.svg + claude.svg;
  svg += arrow(lambda.cx, lambda.bottom + 8, s3.cx, s3.y - 8);
  svg += arrow(lambda.cx, lambda.bottom + 8, voyage.cx, voyage.y - 8);
  svg += arrow(lambda.cx, lambda.bottom + 8, claude.cx, claude.y - 8);

  const row3y = Math.max(s3.bottom, voyage.bottom, claude.bottom) + 45;
  const resp = box(voyage.x, row3y, [
    { text: '{ answer, sources: [{title, url}] }', size: T, bold: true },
  ], { stroke: '#7c3aed' });
  svg += resp.svg;
  // Route around the right/bottom of the (now taller) Claude API box rather than
  // straight down through it.
  const detourX = claude.right + 30;
  svg += arrowPath([
    [lambda.cx, lambda.bottom + 8],
    [lambda.cx, row2y - 20],
    [detourX, row2y - 20],
    [detourX, row3y - 20],
    [resp.cx, row3y - 20],
    [resp.cx, resp.y - 8],
  ]);

  const w = Math.max(claude.right, resp.right);
  const h = resp.bottom;
  return { svg, w, h, apiGw };
}

// ---------- Legend ----------
function buildLegend(width) {
  const pad = 26;
  const header = { text: 'Notes', size: HDR - 4, y: pad + (HDR - 4) };
  const lines = [
    'Estimated cost: ~$1-3/month (Route 53 zone + small redirect distribution); Lambda/API Gateway usage stays within/near free tier for personal traffic.',
    'Secrets (Turnstile secret, admin_api_key, Voyage/Anthropic API keys, mcp_shared_secret) live only in terraform.tfvars (gitignored) and Lambda env vars — never committed.',
    'Out of scope: no user login/accounts, no likes/reactions. Comments are anonymous + name field, moderated via x-api-key admin routes.',
    'Region: ap-northeast-1 for all resources except ACM certificates, which must be requested in us-east-1 for CloudFront.',
  ];
  let svg = `<text x="${pad}" y="${header.y}" font-size="${header.size}" font-weight="700" fill="#0f172a">${header.text}</text>\n`;
  let y = header.y + 34;
  for (const l of lines) {
    svg += `<text x="${pad}" y="${y}" font-size="${T}" fill="#334155">${escapeXml(l)}</text>\n`;
    y += 30;
  }
  const h = y - T * 0.4;
  svg = `<rect x="0" y="0" width="${width}" height="${h.toFixed(1)}" rx="12" fill="#f1f5f9" stroke="#cbd5e1" stroke-width="1.5"/>\n` + svg;
  return { svg, w: width, h };
}

// ============ Compose ============
const margin = 45;
const sectionGap = 55;
const colGap = 55;

const cicd = buildCICD();
const dns = buildDNS();
const hub = buildHub();
const comments = buildComments();
const rag = buildRAG();

const row2Width = dns.w + colGap + hub.w;
const row3Width = comments.w + colGap + rag.w;
const canvasW = Math.max(cicd.w, row2Width, row3Width) + margin * 2;

let body = '';
let y = 0;

// CI/CD section
{
  const headerY = y + 22;
  body += `<text x="${margin}" y="${headerY}" font-size="${HDR}" font-weight="700" fill="#1d4ed8">CI/CD Pipeline (local Jenkins on Windows)</text>\n`;
  const boxTop = headerY + 24;
  const bgH = cicd.h + 36;
  body += `<rect x="${margin - 15}" y="${boxTop - 18}" width="${cicd.w + 30}" height="${bgH}" rx="12" fill="#eff6ff" stroke="#93c5fd" stroke-width="1.5"/>\n`;
  body += wrap(cicd, margin, boxTop);
  y = boxTop - 18 + bgH + sectionGap;
}

// DNS + Hub row
let dnsSectionTop, dnsSectionHeaderY, hubY;
{
  const headerY = y + 22;
  dnsSectionHeaderY = headerY;
  body += `<text x="${margin}" y="${headerY}" font-size="${HDR}" font-weight="700" fill="#1d4ed8">DNS, CDN &amp; Static Hosting</text>\n`;
  const boxTop = headerY + 24;
  const bgH = dns.h + 36;
  body += `<rect x="${margin - 15}" y="${boxTop - 18}" width="${dns.w + 30}" height="${bgH}" rx="12" fill="#f0fdf4" stroke="#86efac" stroke-width="1.5"/>\n`;
  body += wrap(dns, margin, boxTop);
  dnsSectionTop = boxTop;

  // hub aligned with dns row1 (top of dns content)
  hubY = boxTop;
  const hubX = margin + dns.w + colGap;
  body += wrap(hub, hubX, hubY);
  // arrow from dns.s3 right edge to hub left edge (absolute coords)
  const s3AbsRight = margin + dns.s3.right;
  const s3AbsCy = boxTop + dns.s3.cy;
  const hubAbsY = hubY + hub.box.cy;
  body += arrow(s3AbsRight + 8, s3AbsCy, hubX - 8, hubAbsY);
  body += `<text x="${(s3AbsRight + hubX) / 2}" y="${s3AbsCy - 10}" font-size="${T - 4}" fill="#64748b" text-anchor="middle">serves</text>\n`;

  y = boxTop - 18 + bgH + sectionGap;
}

// Comments + RAG row
let hubBottomAbsX, hubBottomAbsY;
{
  const headerYc = y + 22;
  body += `<text x="${margin}" y="${headerYc}" font-size="${HDR}" font-weight="700" fill="#be185d">Comment System (Lambda + S3, moderated)</text>\n`;
  const boxTopC = headerYc + 24;
  const bgHc = comments.h + 36;
  body += `<rect x="${margin - 15}" y="${boxTopC - 18}" width="${comments.w + 30}" height="${bgHc}" rx="12" fill="#fdf2f8" stroke="#f9a8d4" stroke-width="1.5"/>\n`;
  body += wrap(comments, margin, boxTopC);

  const ragX = margin + comments.w + colGap;
  const headerYr = y + 22;
  body += `<text x="${ragX}" y="${headerYr}" font-size="${HDR}" font-weight="700" fill="#7c3aed">RAG Search — "AI に聞く" (Lambda + Voyage + Claude)</text>\n`;
  const boxTopR = headerYr + 24;
  const bgHr = rag.h + 36;
  body += `<rect x="${ragX - 15}" y="${boxTopR - 18}" width="${rag.w + 30}" height="${bgHr}" rx="12" fill="#f5f3ff" stroke="#c4b5fd" stroke-width="1.5"/>\n`;
  body += wrap(rag, ragX, boxTopR);

  // hub -> comments.apiGw and hub -> rag.apiGw (elbow paths)
  const hubAbsX = margin + dns.w + colGap;
  const hubBoxBottomY = hubY + hub.box.bottom;
  const hubBoxCx = hubAbsX + hub.box.cx;
  const commentsApiAbsX = margin + comments.apiGw.cx;
  const commentsApiAbsTop = boxTopC + comments.apiGw.y;
  const ragApiAbsX = ragX + rag.apiGw.cx;
  const ragApiAbsTop = boxTopR + rag.apiGw.y;
  const midY = (hubBoxBottomY + Math.min(commentsApiAbsTop, ragApiAbsTop)) / 2;
  body += arrowPath([[hubBoxCx, hubBoxBottomY], [hubBoxCx, midY], [commentsApiAbsX, midY], [commentsApiAbsX, commentsApiAbsTop - 8]]);
  body += arrowPath([[hubBoxCx, hubBoxBottomY], [hubBoxCx, midY], [ragApiAbsX, midY], [ragApiAbsX, ragApiAbsTop - 8]]);

  y = Math.max(boxTopC - 18 + bgHc, boxTopR - 18 + bgHr) + sectionGap;
}

// Legend
{
  const legend = buildLegend(canvasW - margin * 2);
  body += wrap(legend, margin, y);
  y += legend.h + margin;
}

const canvasH = y + 110; // account for the <g transform="translate(0, 110)"> wrapper below

const svg = `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 ${canvasW.toFixed(1)} ${canvasH.toFixed(1)}" font-family="Segoe UI, Helvetica, Arial, sans-serif">
  <defs>
    <marker id="arrow" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="8" markerHeight="8" orient="auto-start-reverse">
      <path d="M0,0 L10,5 L0,10 z" fill="#475569"/>
    </marker>
  </defs>
  <rect width="${canvasW.toFixed(1)}" height="${canvasH.toFixed(1)}" fill="#f8fafc"/>
  <text x="${canvasW / 2}" y="50" text-anchor="middle" font-size="38" font-weight="700" fill="#0f172a">www.kanjtomi1967.net — Blog Architecture</text>
  <text x="${canvasW / 2}" y="82" text-anchor="middle" font-size="22" fill="#64748b">Static Hugo site on AWS (S3 + CloudFront), self-hosted comments and RAG search via Lambda</text>
  <g transform="translate(0, 110)">
${body}
  </g>
</svg>
`;

process.stdout.write(svg);
