// Parses AGENTS.md at three commits with marked (GFM, the list semantics GitHub
// uses) and reports the list structure per `##` section, so the section 9
// escalation/etiquette split is asserted as meaning rather than as text.
// Usage: node agents-md-list-model.mjs <firstmate-checkout> <base> <mid> <target>
import { execFileSync } from "node:child_process";
import { Marked } from "file:///Users/brooks/.npm/_npx/a3ecabc7dc353655/node_modules/marked/lib/marked.esm.js";

const [, , repo, ...commits] = process.argv;
const marked = new Marked({ gfm: true });
const model = (commit) => {
  const src = execFileSync("git", ["-C", repo, "show", `${commit}:AGENTS.md`], { encoding: "utf8" });
  let section = "(preamble)";
  const lists = [];
  for (const t of marked.lexer(src)) {
    if (t.type === "heading" && t.depth === 2) section = t.text;
    if (t.type === "list") {
      const line = (i) => (t.items[i].text ?? "").split("\n")[0].trim().slice(0, 64);
      lists.push({ section, items: t.items.length, loose: t.loose, first: line(0), last: line(t.items.length - 1) });
    }
  }
  return lists;
};

for (const c of commits) {
  const lists = model(c);
  console.log(`\n=== ${c} ===`);
  for (const l of lists.filter((l) => /^9\./.test(l.section))) {
    console.log(`  section 9 list: ${l.items} items (${l.loose ? "loose" : "tight"})`);
    console.log(`      first: ${l.first}`);
    console.log(`      last:  ${l.last}`);
  }
  const s9 = lists.filter((l) => /^9\./.test(l.section));
  const escalation = s9.find((l) => l.first.startsWith("Work ready for their review"));
  const merged = escalation && escalation.last.startsWith("Mention cost as a courtesy");
  console.log(`  -> "Reach the captain immediately for:" list ends with: ${escalation?.last}`);
  console.log(`  -> etiquette bullets absorbed into the escalation list: ${merged ? "YES (meaning inverted)" : "no"}`);
}
