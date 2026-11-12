import { mkdir, readFile, rm, stat, writeFile } from "node:fs/promises";
import path from "node:path";
import { parseArgs } from "node:util";
import { createRequire } from "node:module";
import { getSkin, skins } from "./skins.js";
import { RULE_RELATIVE, readSkinId, renderRule } from "./rule.js";

const require = createRequire(import.meta.url);
const pkg = require("../package.json");

const NPX = "npx github:frskapranov-stack/retertertert";

/**
 * @param {string[]} argv
 * @param {{ cwd?: string, stdout?: { write(chunk: string): unknown }, stderr?: { write(chunk: string): unknown } }} [io]
 * @returns {Promise<number>}
 */
export async function main(argv, io = {}) {
  const stdout = io.stdout ?? process.stdout;
  const stderr = io.stderr ?? process.stderr;
  const cwd = io.cwd ?? process.cwd();

  let values;
  let positionals;
  try {
    ({ values, positionals } = parseArgs({
      args: argv,
      options: {
        target: { type: "string", short: "t" },
        force: { type: "boolean", short: "f", default: false },
        help: { type: "boolean", short: "h", default: false },
        version: { type: "boolean", short: "v", default: false },
      },
      allowPositionals: true,
      strict: true,
    }));
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    stderr.write(`${message}\n${helpText()}`);
    return 1;
  }

  if (values.version) {
    stdout.write(`${pkg.version}\n`);
    return 0;
  }

  const command = positionals[0];
  if (values.help || !command) {
    stdout.write(helpText());
    return 0;
  }

  const target = path.resolve(values.target ?? cwd);

  try {
    switch (command) {
      case "list":
      case "ls":
        return await listSkins(target, stdout);
      case "add":
      case "use":
        return await addSkin(positionals[1], target, values.force, stdout, stderr);
      case "remove":
      case "rm":
        return await removeSkin(target, values.force, stdout, stderr);
      case "show":
        return showSkin(positionals[1], stdout, stderr);
      case "current":
        return await currentSkin(target, stdout, stderr);
      default:
        stderr.write(`Неизвестная команда «${command}».\n${helpText()}`);
        return 1;
    }
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    stderr.write(`${message}\n`);
    return 1;
  }
}

function helpText() {
  const ids = skins.map((skin) => skin.id).join(", ");
  return `cursor-skin — npx-скин для агента Cursor

Использование:
  cursor-skin list [--target <каталог>]
  cursor-skin add <id> [--target <каталог>] [--force]
  cursor-skin remove [--target <каталог>] [--force]
  cursor-skin show <id>
  cursor-skin current [--target <каталог>]

Скины: ${ids}

Скин записывается в .cursor/rules/cursor-skin.mdc с alwaysApply: true
и действует в каждом чате Agent этого проекта. Новый скин заменяет предыдущий.
Закоммитьте файл, если он нужен всей команде.

Без установки:
  ${NPX} add laconic
  ${NPX} list
`;
}

/**
 * @param {string} target
 * @param {{ write(chunk: string): unknown }} stdout
 */
async function listSkins(target, stdout) {
  const active = await installedId(target);
  const idWidth = Math.max(...skins.map((skin) => skin.id.length));
  const nameWidth = Math.max(...skins.map((skin) => skin.name.length));
  const lines = skins.map((skin) => {
    const mark = skin.id === active ? "*" : " ";
    return `${mark} ${skin.id.padEnd(idWidth)}  ${skin.name.padEnd(nameWidth)}  ${skin.summary}`;
  });
  stdout.write(`${lines.join("\n")}\n`);
  return 0;
}

/**
 * @param {string | undefined} id
 * @param {string} target
 * @param {boolean} force
 * @param {{ write(chunk: string): unknown }} stdout
 * @param {{ write(chunk: string): unknown }} stderr
 */
async function addSkin(id, target, force, stdout, stderr) {
  if (!id) {
    stderr.write(`Укажите id скина.\n${skinHint()}`);
    return 1;
  }
  const skin = getSkin(id);
  if (!skin) {
    stderr.write(`Нет скина «${id}».\n${skinHint()}`);
    return 1;
  }

  await assertDirectory(target);
  const file = rulePath(target);
  const next = renderRule(skin);
  const existing = await readOptional(file);

  if (existing !== null) {
    const installed = readSkinId(existing);
    if (existing === next) {
      stdout.write(`Скин «${skin.name}» уже установлен.\n${file}\n`);
      return 0;
    }
    if (!force && (installed === null || installed === skin.id)) {
      stderr.write(
        `Файл ${RULE_RELATIVE} уже есть и отличается от скина.\nПовторите с --force, чтобы перезаписать.\n`,
      );
      return 1;
    }
  }

  await mkdir(path.dirname(file), { recursive: true });
  await writeFile(file, next, "utf8");

  const previous = existing === null ? null : readSkinId(existing);
  const previousSkin = previous ? getSkin(previous) : undefined;
  if (previousSkin && previousSkin.id !== skin.id) {
    stdout.write(`Скин «${previousSkin.name}» заменён на «${skin.name}».\n`);
  } else {
    stdout.write(`Поставлен скин «${skin.name}» (${skin.id}).\n`);
  }
  stdout.write(`${file}\n`);
  stdout.write("Он применяется в каждом чате Agent этого проекта. Начните новый чат, чтобы подхватить правило.\n");
  return 0;
}

/**
 * @param {string} target
 * @param {boolean} force
 * @param {{ write(chunk: string): unknown }} stdout
 * @param {{ write(chunk: string): unknown }} stderr
 */
async function removeSkin(target, force, stdout, stderr) {
  await assertDirectory(target);
  const file = rulePath(target);
  const existing = await readOptional(file);
  if (existing === null) {
    stderr.write("Скин не установлен.\n");
    return 1;
  }
  if (!force && readSkinId(existing) === null) {
    stderr.write(
      `В ${RULE_RELATIVE} нет метки скина. Повторите с --force, чтобы удалить файл.\n`,
    );
    return 1;
  }
  await rm(file);
  stdout.write(`Скин снят.\n${file}\n`);
  return 0;
}

/**
 * @param {string | undefined} id
 * @param {{ write(chunk: string): unknown }} stdout
 * @param {{ write(chunk: string): unknown }} stderr
 */
function showSkin(id, stdout, stderr) {
  if (!id) {
    stderr.write(`Укажите id скина.\n${skinHint()}`);
    return 1;
  }
  const skin = getSkin(id);
  if (!skin) {
    stderr.write(`Нет скина «${id}».\n${skinHint()}`);
    return 1;
  }
  stdout.write(renderRule(skin));
  return 0;
}

/**
 * @param {string} target
 * @param {{ write(chunk: string): unknown }} stdout
 * @param {{ write(chunk: string): unknown }} stderr
 */
async function currentSkin(target, stdout, stderr) {
  await assertDirectory(target);
  const file = rulePath(target);
  const existing = await readOptional(file);
  if (existing === null) {
    stderr.write("Скин не установлен.\n");
    return 1;
  }
  const id = readSkinId(existing);
  const skin = id ? getSkin(id) : undefined;
  if (!skin) {
    stderr.write(`В ${file} нет известного скина.\n`);
    return 1;
  }
  stdout.write(`${skin.id}  ${skin.name}\n${file}\n`);
  return 0;
}

/**
 * @param {string} target
 */
async function installedId(target) {
  const existing = await readOptional(rulePath(target));
  if (existing === null) return null;
  return readSkinId(existing);
}

/**
 * @param {string} target
 */
function rulePath(target) {
  return path.join(target, RULE_RELATIVE);
}

/**
 * @param {string} file
 * @returns {Promise<string | null>}
 */
async function readOptional(file) {
  try {
    return await readFile(file, "utf8");
  } catch (error) {
    if (error && typeof error === "object" && "code" in error && error.code === "ENOENT") {
      return null;
    }
    throw error;
  }
}

/**
 * @param {string} target
 */
async function assertDirectory(target) {
  let info;
  try {
    info = await stat(target);
  } catch (error) {
    if (error && typeof error === "object" && "code" in error && error.code === "ENOENT") {
      throw new Error(`Каталог не найден: ${target}`);
    }
    throw error;
  }
  if (!info.isDirectory()) {
    throw new Error(`Это не каталог: ${target}`);
  }
}

function skinHint() {
  return `Доступные скины: ${skins.map((skin) => skin.id).join(", ")}\n`;
}
