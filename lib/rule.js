import path from "node:path";

export const RULE_RELATIVE = path.join(".cursor", "rules", "cursor-skin.mdc");

const MARKER = /<!-- cursor-skin: ([a-z0-9-]+) -->/;

/**
 * @param {string} value
 */
function yamlQuote(value) {
  return `"${value.replaceAll("\\", "\\\\").replaceAll('"', '\\"')}"`;
}

/**
 * @param {{ id: string, name: string, summary: string, body: string }} skin
 */
export function renderRule(skin) {
  const summary = skin.summary.charAt(0).toLowerCase() + skin.summary.slice(1);
  const description = `Скин Cursor «${skin.name}»: ${summary}.`;
  return `---
description: ${yamlQuote(description)}
alwaysApply: true
---

<!-- cursor-skin: ${skin.id} -->

${skin.body.trim()}
`;
}

/**
 * @param {string} source
 * @returns {string | null}
 */
export function readSkinId(source) {
  const match = source.match(MARKER);
  return match ? match[1] : null;
}
