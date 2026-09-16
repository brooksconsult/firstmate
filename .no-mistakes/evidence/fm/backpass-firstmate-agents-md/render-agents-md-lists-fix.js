// Renders the AGENTS.md span from "Reach the captain immediately for:" up to
// "Keep free-form notes" for the base and target commits with marked (CommonMark
// list rules), labels every rendered list with its item count and looseness,
// and writes a side-by-side HTML page.
// Usage: node render-agents-md-lists.js <marked-dir> <base.md> <target.md> <out.html>
const fs = require('fs');
const { marked } = require(process.argv[2]);
const [basePath, targetPath, outPath] = process.argv.slice(3);

function span(md) {
  const start = md.indexOf('Reach the captain immediately for:');
  const end = md.indexOf('Keep free-form notes');
  if (start < 0 || end < 0) throw new Error('span markers not found');
  return md.slice(start, end);
}

function render(md, tag) {
  const tokens = marked.lexer(md);
  let html = '';
  let n = 0;
  for (const t of tokens) {
    if (t.type === 'space') continue;
    if (t.type === 'list') {
      n += 1;
      const first = t.items[0].text.split('\n')[0].slice(0, 48);
      const label = `rendered list ${n}: ${t.items.length} items, ${t.loose ? 'loose' : 'tight'}`;
      console.log(`${tag}: ${label} (first item: "${first}...")`);
      html += `<div class="badge ${t.items.length > 8 ? 'warn' : ''}">${label}</div>`;
      html += `<div class="frame">${marked.parser([t])}</div>`;
    } else {
      html += marked.parser([t]);
    }
  }
  return html;
}

const base = render(span(fs.readFileSync(basePath, 'utf8')), 'reported 6ac5ea7');
const target = render(span(fs.readFileSync(targetPath, 'utf8')), 'fixed (this change)');

const page = `<!doctype html>
<html><head><meta charset="utf-8"><title>AGENTS.md sections 9-10 rendered lists</title>
<style>
  body { margin: 0; background: #f6f8fa; color: #1f2328; font: 15px/1.5 -apple-system, BlinkMacSystemFont, "Segoe UI", Helvetica, Arial, sans-serif; }
  header { padding: 16px 24px; border-bottom: 1px solid #d1d9e0; background: #fff; }
  header h1 { margin: 0; font-size: 18px; }
  header p { margin: 4px 0 0; color: #59636e; font-size: 13px; }
  .grid { display: grid; grid-template-columns: minmax(0, 1fr) minmax(0, 1fr); gap: 16px; padding: 16px 24px; }
  .col { min-width: 0; background: #fff; border: 1px solid #d1d9e0; border-radius: 6px; padding: 8px 24px 16px; }
  .col > h2.title { font-size: 14px; color: #59636e; border-bottom: 1px solid #d1d9e0; padding-bottom: 8px; margin: 8px 0 16px; }
  .md p { margin: 0 0 16px; }
  .md h2 { font-size: 1.5em; padding-bottom: .3em; border-bottom: 1px solid #d1d9e0; margin: 24px 0 16px; }
  .md ul { padding-left: 2em; margin: 0 0 16px; }
  .md li + li { margin-top: .25em; }
  .md li > p { margin-top: 16px; margin-bottom: 0; }
  .md code { font: 85% ui-monospace, SFMono-Regular, Menlo, monospace; background: #eff1f3; padding: .2em .4em; border-radius: 6px; overflow-wrap: anywhere; }
  .md a { color: #0969da; text-decoration: none; }
  .badge { display: inline-block; font: 600 12px/1 ui-monospace, Menlo, monospace; background: #ddf4ff; color: #0550ae; border-radius: 999px; padding: 4px 10px; margin: 4px 0 6px; }
  .badge.warn { background: #ffebe9; color: #a40e26; }
  .frame { border-left: 3px solid #afb8c1; padding-left: 4px; margin-bottom: 16px; }
  .badge.warn + .frame { border-left-color: #cf222e; }
</style></head>
<body>
<header><h1>AGENTS.md "Reach the captain immediately for:" through section 10, rendered as CommonMark (marked ${require(process.argv[2] + '/package.json').version})</h1>
<p>Each rendered list is labelled with its item count. A red label marks a list that absorbed bullets written after a blank line.</p></header>
<div class="grid">
  <div class="col"><h2 class="title">Reported failure 6ac5ea7 (before)</h2><div class="md">${base}</div></div>
  <div class="col"><h2 class="title">Fixed: lead-in paragraph added (after)</h2><div class="md">${target}</div></div>
</div>
</body></html>`;
fs.writeFileSync(outPath, page);
console.log(`wrote ${outPath}`);
