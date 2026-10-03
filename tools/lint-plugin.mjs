// Lints the plugin's markdown components: strict-YAML frontmatter, required fields,
// description budget, name collisions, positional-argument misuse, and dangling
// `noobit:<name>` / `/noobit:<name>` references. Exits 1 on any error.
import { readFileSync, readdirSync, existsSync, statSync } from 'node:fs';
import { join, relative, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { parse } from 'yaml';

const root = join(dirname(fileURLToPath(import.meta.url)), '..');
const MAX_SKILL_DESCRIPTION = 500;
const errors = [];
const err = (file, msg) => errors.push(`${relative(root, file).replaceAll('\\', '/')}: ${msg}`);

function walk(dir, out = []) {
  for (const name of readdirSync(dir)) {
    if (name === 'node_modules' || name.startsWith('.')) continue;   // .git, .superpowers scratch
    const p = join(dir, name);
    if (statSync(p).isDirectory()) walk(p, out);
    else out.push(p);
  }
  return out;
}

function frontmatter(file) {
  const text = readFileSync(file, 'utf8');
  const m = text.match(/^---\r?\n([\s\S]*?)\r?\n---\r?\n/);
  if (!m) { err(file, 'missing frontmatter'); return { data: {}, body: text, valid: false }; }
  try {
    return { data: parse(m[1], { strict: true, uniqueKeys: true }) ?? {}, body: text.slice(m[0].length), valid: true };
  } catch (e) {
    err(file, `invalid YAML frontmatter: ${e.message.split('\n')[0]}`);
    return { data: {}, body: text.slice(m[0].length), valid: false };
  }
}

const listMd = (dir) => existsSync(join(root, dir))
  ? readdirSync(join(root, dir)).filter((f) => f.endsWith('.md')).map((f) => join(root, dir, f))
  : [];

// --- collect components ------------------------------------------------------
const skills = new Map();   // name -> file
for (const d of readdirSync(join(root, 'skills'))) {
  const file = join(root, 'skills', d, 'SKILL.md');
  if (!existsSync(file)) { err(join(root, 'skills', d), 'skill folder without SKILL.md'); continue; }
  const { data } = frontmatter(file);
  if (!data.name) err(file, 'missing name');
  else if (data.name !== d) err(file, `name "${data.name}" does not match folder "${d}"`);
  if (!data.description) err(file, 'missing description');
  else if (String(data.description).length > MAX_SKILL_DESCRIPTION)
    err(file, `description is ${String(data.description).length} chars (max ${MAX_SKILL_DESCRIPTION})`);
  skills.set(d, file);
}

const agents = new Map();
for (const file of listMd('agents')) {
  const { data } = frontmatter(file);
  const base = file.split(/[\\/]/).pop().replace(/\.md$/, '');
  if (!data.name) err(file, 'missing name');
  else if (data.name !== base) err(file, `name "${data.name}" does not match file name`);
  if (!data.description) err(file, 'missing description');
  agents.set(base, { file, data });
}

const commands = new Map();
for (const file of listMd('commands')) {
  const { data, body, valid } = frontmatter(file);
  const base = file.split(/[\\/]/).pop().replace(/\.md$/, '');
  if (valid && !data.description) err(file, 'missing description');
  // $0 is the FIRST positional argument, $1 the second (verified live) — single-argument
  // commands must use $ARGUMENTS so a misplaced index can't silently drop the input
  if (/\$\d\b/.test(body)) err(file, 'uses positional $N — use "$ARGUMENTS" (positional args are 0-based)');
  commands.set(base, file);
}

for (const [name, file] of commands)
  if (skills.has(name)) err(file, `command name collides with skill "${name}" — the command shadows the skill`);

// --- frontmatter value shapes ---------------------------------------------------
for (const file of [...commands.values(), ...skills.values()]) {
  const { data } = frontmatter(file);
  // an unquoted `argument-hint: [x] (y)` is invalid YAML, a bare `[x]` silently becomes an array
  if ('argument-hint' in data && typeof data['argument-hint'] !== 'string') err(file, 'argument-hint must be a quoted string');
}
// skill bodies that run bundled scripts must point at files that ship
for (const [name, file] of skills) {
  for (const m of readFileSync(file, 'utf8').matchAll(/\$\{CLAUDE_SKILL_DIR\}\/([^\s"'`)]+)/g))
    if (!existsSync(join(root, 'skills', name, m[1]))) err(file, `\${CLAUDE_SKILL_DIR}/${m[1]} does not exist`);
}

const GRADER_TYPES = new Set(['regex', 'tool_used', 'tool_order', 'file_exists', 'llm', 'baseline']);
const MODELS =/^(inherit|sonnet|opus|haiku|fable|claude-[a-z0-9-]+)$/;
const EFFORTS = new Set(['low', 'medium', 'high', 'xhigh', 'max']);
for (const [, { file, data }] of agents) {
  if ('model' in data && !MODELS.test(String(data.model))) err(file, `unknown model "${data.model}"`);
  if ('effort' in data && !EFFORTS.has(String(data.effort))) err(file, `unknown effort "${data.effort}"`);
  if ('tools' in data && typeof data.tools !== 'string' && !Array.isArray(data.tools)) err(file, 'tools must be a comma list or array');
}

// --- commands dispatching **agent-name** agents -----------------------------------
for (const [, file] of commands) {
  for (const m of readFileSync(file, 'utf8').matchAll(/\*\*([a-z][a-z0-9-]*)\*\* agent/g))
    if (!agents.has(m[1])) err(file, `dispatches unknown agent "${m[1]}"`);
}

// --- hooks reference scripts that exist ----------------------------------------------
const hooksFile = join(root, 'hooks', 'hooks.json');
if (existsSync(hooksFile)) {
  const text = readFileSync(hooksFile, 'utf8');
  try { JSON.parse(text); } catch (e) { err(hooksFile, `invalid JSON: ${e.message}`); }
  for (const m of text.matchAll(/\$\{CLAUDE_PLUGIN_ROOT\}\/([^"\s]+)/g))
    if (!existsSync(join(root, m[1]))) err(hooksFile, `references missing file ${m[1]}`);
}

// --- eval case shape -----------------------------------------------------------------
const evalsDir = join(root, 'evals');
if (existsSync(evalsDir)) {
  for (const c of readdirSync(evalsDir)) {
    const dir = join(evalsDir, c);
    if (c === 'results' || !statSync(dir).isDirectory()) continue;
    const prompt = join(dir, 'prompt.md');
    if (!existsSync(prompt) && !existsSync(join(dir, 'case.yaml'))) { err(dir, 'eval case without prompt.md or case.yaml'); continue; }
    const graders = join(dir, 'graders');
    if (!existsSync(graders) || !readdirSync(graders).some((g) => g.endsWith('.md'))) err(dir, 'eval case without graders/*.md');
    else for (const g of readdirSync(graders).filter((x) => x.endsWith('.md'))) {
      const gf = join(graders, g);
      const { data } = frontmatter(gf);
      if (!GRADER_TYPES.has(String(data.type))) err(gf, `grader type "${data.type}" is not one of ${[...GRADER_TYPES].join('|')}`);
      // a Skill-trigger grader must name skills that exist, or a rename silently turns it vacuous
      if (data.type === 'tool_used' && data.tool === 'Skill' && data.input_match) {
        // the name slot follows the optional plugin prefix: `(?:[\w-]+:)?name"` or `(?:[\w-]+:)?(?:a|b)"`
        const slot = String(data.input_match).match(/\(\?:\[\\w-\]\+:\)\?(?:\(\?:([^)]*)\)|([a-z0-9-]+))"/);
        if (!slot) err(gf, 'Skill grader input_match has no recognizable skill-name slot');
        else {
          const named = (slot[1] ?? slot[2]).split('|');
          for (const n of named) if (!skills.has(n)) err(gf, `Skill grader names unknown skill "${n}"`);
          // a "no noobit skill fires" case must cover every skill, or a new skill is silently exempt
          if (c.includes('no-noobit'))
            for (const s of skills.keys()) if (!named.includes(s)) err(gf, `no-noobit grader misses skill "${s}"`);
        }
      }
    }
    const caseYaml = join(dir, 'case.yaml');
    if (existsSync(caseYaml)) {
      try {
        const c = parse(readFileSync(caseYaml, 'utf8')) ?? {};
        const script = c.context?.scaffold_script ?? c.scaffold_script;
        if (script && !existsSync(join(dir, script))) err(caseYaml, `scaffold_script "${script}" does not exist`);
      } catch (e) { err(caseYaml, `invalid YAML: ${e.message.split('\n')[0]}`); }
    }
    if (existsSync(prompt)) {
      const { data } = frontmatter(prompt);
      if (data.name && data.name !== c) err(prompt, `name "${data.name}" does not match folder "${c}"`);
    }
  }
}

// --- agent skill preloads ----------------------------------------------------
for (const [, { file, data }] of agents) {
  for (const s of [].concat(data.skills ?? [])) {
    const bare = String(s).replace(/^noobit:/, '');
    if (!skills.has(bare)) err(file, `skills: preload "${s}" does not resolve to a plugin skill`);
  }
}

// --- dangling references in every markdown file ---------------------------------
const known = new Set([...skills.keys(), ...agents.keys(), ...commands.keys()]);
const scanned = walk(root).filter((f) => f.endsWith('.md') && !relative(root, f).startsWith('work'));
for (const file of scanned) {
  const text = readFileSync(file, 'utf8');
  for (const m of text.matchAll(/(\/?)noobit:([a-z0-9][a-z0-9-]*)/g)) {
    const [, slash, name] = m;
    if (slash && !commands.has(name) && !skills.has(name)) err(file, `"/noobit:${name}" is not a command or skill`);
    if (slash && commands.has(`new-${name}`)) err(file, `"/noobit:${name}" loads the format skill — the command is "/noobit:new-${name}"`);
    if (!slash && !known.has(name)) err(file, `"noobit:${name}" is not a skill, agent, or command`);
  }
}

if (errors.length) {
  console.error(errors.map((e) => `ERROR ${e}`).join('\n'));
  console.error(`\n${errors.length} error(s)`);
  process.exit(1);
}
console.log(`OK — ${skills.size} skills, ${agents.size} agents, ${commands.size} commands`);
