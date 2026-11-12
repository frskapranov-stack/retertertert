import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import { test } from "node:test";
import { fileURLToPath } from "node:url";
import { main } from "../lib/cli.js";
import { RULE_RELATIVE, readSkinId, renderRule } from "../lib/rule.js";
import { getSkin, skins } from "../lib/skins.js";

const bin = fileURLToPath(new URL("../bin/cursor-skin.js", import.meta.url));

function capture() {
  const stdout = [];
  const stderr = [];
  return {
    stdout: { write: (chunk) => stdout.push(chunk) },
    stderr: { write: (chunk) => stderr.push(chunk) },
    out: () => stdout.join(""),
    err: () => stderr.join(""),
  };
}

async function tempProject() {
  return mkdtemp(path.join(tmpdir(), "cursor-skin-"));
}

test("catalog has unique latin ids and non-empty bodies", () => {
  const ids = skins.map((skin) => skin.id);
  assert.deepEqual(ids, [...new Set(ids)]);
  for (const skin of skins) {
    assert.match(skin.id, /^[a-z0-9-]+$/);
    assert.ok(skin.name.length > 0);
    assert.ok(skin.summary.length > 0);
    assert.ok(skin.body.includes("Отвечай на языке пользователя."));
    assert.equal(skin.body.includes("<!-- cursor-skin:"), false);
  }
});

test("renderRule is an always-apply Cursor rule", () => {
  const skin = getSkin("laconic");
  assert.ok(skin);
  const rule = renderRule(skin);
  assert.equal(rule.startsWith("---\n"), true);
  assert.match(rule, /^description: ".*"$/m);
  assert.match(rule, /^alwaysApply: true$/m);
  assert.equal(readSkinId(rule), "laconic");
  assert.match(rule, /Сначала ответ или правка/);
});

test("list marks the installed skin", async () => {
  const target = await tempProject();
  try {
    const io = capture();
    assert.equal(await main(["add", "reviewer", "--target", target], io), 0);
    const listed = capture();
    assert.equal(await main(["list", "--target", target], listed), 0);
    assert.match(listed.out(), /^\* reviewer/m);
    assert.match(listed.out(), /^ {2}laconic/m);
  } finally {
    await rm(target, { recursive: true, force: true });
  }
});

test("add writes the rule, current reads it, second add replaces it", async () => {
  const target = await tempProject();
  try {
    const io = capture();
    assert.equal(await main(["add", "mentor", "-t", target], io), 0);
    const file = path.join(target, RULE_RELATIVE);
    const written = await readFile(file, "utf8");
    assert.equal(written, renderRule(getSkin("mentor")));
    assert.match(io.out(), /Поставлен скин «Наставник»/);

    const again = capture();
    assert.equal(await main(["add", "mentor", "--target", target], again), 0);
    assert.match(again.out(), /уже установлен/);

    const current = capture();
    assert.equal(await main(["current", "--target", target], current), 0);
    assert.match(current.out(), /^mentor {2}Наставник\n/);

    const swapped = capture();
    assert.equal(await main(["use", "minimal", "--target", target], swapped), 0);
    assert.match(swapped.out(), /«Наставник» заменён на «Минималист»/);
    assert.equal(readSkinId(await readFile(file, "utf8")), "minimal");
  } finally {
    await rm(target, { recursive: true, force: true });
  }
});

test("add refuses to clobber a hand-edited rule without --force", async () => {
  const target = await tempProject();
  try {
    assert.equal(await main(["add", "pair", "--target", target], capture()), 0);
    const file = path.join(target, RULE_RELATIVE);
    await writeFile(file, `${await readFile(file, "utf8")}\nРучная правка.\n`);

    const blocked = capture();
    assert.equal(await main(["add", "pair", "--target", target], blocked), 1);
    assert.match(blocked.err(), /--force/);
    assert.match(await readFile(file, "utf8"), /Ручная правка/);

    const forced = capture();
    assert.equal(await main(["add", "pair", "--target", target, "--force"], forced), 0);
    assert.equal(await readFile(file, "utf8"), renderRule(getSkin("pair")));
  } finally {
    await rm(target, { recursive: true, force: true });
  }
});

test("remove deletes only a skin file", async () => {
  const target = await tempProject();
  try {
    const missing = capture();
    assert.equal(await main(["remove", "--target", target], missing), 1);
    assert.match(missing.err(), /не установлен/);

    const file = path.join(target, RULE_RELATIVE);
    await main(["add", "architect", "--target", target], capture());
    const removed = capture();
    assert.equal(await main(["rm", "--target", target], removed), 0);
    await assert.rejects(readFile(file, "utf8"));

    await writeFile(file, "---\nalwaysApply: true\n---\n\nчужой файл\n");
    const blocked = capture();
    assert.equal(await main(["remove", "--target", target], blocked), 1);
    assert.match(await readFile(file, "utf8"), /чужой файл/);
    assert.equal(await main(["remove", "--target", target, "-f"], capture()), 0);
  } finally {
    await rm(target, { recursive: true, force: true });
  }
});

test("unknown skin and missing target fail", async () => {
  const io = capture();
  assert.equal(await main(["add", "yoda"], io), 1);
  assert.match(io.err(), /Нет скина «yoda»/);

  const missing = capture();
  assert.equal(
    await main(["add", "laconic", "--target", path.join(tmpdir(), "cursor-skin-missing-dir")], missing),
    1,
  );
  assert.match(missing.err(), /Каталог не найден/);

  const help = capture();
  assert.equal(await main(["--help"], help), 0);
  assert.match(help.out(), /npx github:frskapranov-stack\/retertertert add laconic/);
});

test("show prints the rule and the bin speaks the same protocol", async () => {
  const shown = capture();
  assert.equal(await main(["show", "reviewer"], shown), 0);
  assert.equal(shown.out(), renderRule(getSkin("reviewer")));

  const child = spawnSync(process.execPath, [bin, "show", "laconic"], { encoding: "utf8" });
  assert.equal(child.status, 0);
  assert.equal(child.stdout, renderRule(getSkin("laconic")));
  assert.equal(child.stderr, "");
});
