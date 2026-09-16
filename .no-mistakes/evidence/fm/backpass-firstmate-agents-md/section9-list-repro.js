// Parses the AGENTS.md section 9 span from "Reach the captain immediately for:"
// to "## 10. Backlog contract" with marked (CommonMark/GFM list rules) and
// prints every rendered list with its item count and first item.
// Usage: node section9-list-repro.js <marked-dir> <AGENTS.md>
const fs = require('fs');
const { marked } = require(process.argv[2]);
const md = fs.readFileSync(process.argv[3], 'utf8');
const start = md.indexOf('Reach the captain immediately for:');
const end = md.indexOf('## 10. Backlog contract');
if (start < 0 || end < 0) throw new Error('span markers not found');
const span = md.slice(start, end);

let n = 0;
for (const t of marked.lexer(span)) {
  if (t.type === 'list') {
    n += 1;
    const first = t.items[0].text.split('\n')[0].slice(0, 60);
    console.log(`list ${n}: ${t.items.length} items, ${t.loose ? 'loose' : 'tight'} | first: "${first}..."`);
    for (const [i, it] of t.items.entries()) {
      console.log(`    ${i + 1}. ${it.text.split('\n')[0].slice(0, 72)}`);
    }
  } else if (t.type === 'paragraph') {
    console.log(`paragraph: "${t.text.split('\n')[0].slice(0, 60)}"`);
  }
}
