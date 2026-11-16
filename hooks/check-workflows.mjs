// pre-receive から呼ぶ: node check-workflows.mjs <ref> <commit> [<ref> <commit> ...]
// 保護ブランチ（リポジトリ設定 gate.protected）のどれとも内容が異なるものだけを検査する。
//   .github/actions   : 保護ブランチのどれかと同一でなければ拒否（既存の特権付きワークフローから呼ばれうるため）
//   .github/workflows : 異なるファイルを安全ポリシーで検査
// 方針: 判断に迷うもの・知らないものはすべて拒否（＝人間がホストから push）。git の失敗も拒否（例外で終了）。
import { execFileSync } from 'node:child_process';
import { parseDocument, visit, isAlias, isScalar } from 'yaml';

const DIR = '.github/workflows';
const ACTIONS = '.github/actions';
// ブランチ上のファイルが、そのブランチの権限設定のまま動くトリガーだけを許可する（pull_request_target などは不可）
const TRIGGERS = new Set(['push', 'pull_request', 'pull_request_review', 'pull_request_review_comment',
  'workflow_dispatch', 'workflow_call', 'merge_group']);
const TOP_KEYS = new Set(['name', 'run-name', 'on', 'permissions', 'env', 'defaults', 'concurrency', 'jobs']);
const JOB_KEYS = new Set(['name', 'needs', 'if', 'runs-on', 'permissions', 'concurrency', 'outputs', 'env',
  'defaults', 'steps', 'timeout-minutes', 'strategy', 'continue-on-error', 'container', 'services', 'uses', 'with']);
// GitHub ホストのランナーの標準ラベルの形だけ（ubuntu-24.04、windows-2025、macos-15-xlarge など）。
// 先頭だけで判定すると ubuntu-my-runner のようなセルフホストのランナーのラベルも通ってしまう
const RUNNER_OK = /^(ubuntu-(latest|\d{2}\.\d{2})(-arm)?|windows-(latest|\d{4}|11-arm)|macos-(latest|\d{2})(-intel|-large|-xlarge)?)$/;
const LOCAL_WORKFLOW = /^\.\/\.github\/workflows\/[^/]+\.ya?ml$/;   // 同じコミット内の再利用可能なワークフロー（それ自体も検査される）

const git = (...args) => execFileSync('git', args, { encoding: 'utf8', maxBuffer: 1 << 26, stdio: ['ignore', 'pipe', 'inherit'] });
// ls-tree の 1 行（-z）を { mode, type, oid, path } に。-z でないと、ASCII 以外を含むパスが引用符付きになる
const parse = (line) => { const [meta, path] = line.split('\t'); const [mode, type, oid] = meta.split(' '); return { mode, type, oid, path }; };
const list = (rev, path, recursive = false) => git('ls-tree', '-z', ...(recursive ? ['-r'] : []), rev, '--', path)
  .split('\0').filter(Boolean).map(parse);
// パスの項目（なければ null）。ls-tree は存在しないパスでは何も出さず、git 自体の失敗では例外になる
const entry = (rev, path) => list(rev, path).find((e) => e.path === path) ?? null;
const exists = (rev) => { try { git('rev-parse', '-q', '--verify', `${rev}^{commit}`); return true; } catch { return false; } };

const protectedNames = (() => { try { return git('config', '--get', 'gate.protected').split(/\s+/).filter(Boolean); } catch { return []; } })();
if (!protectedNames.length) { console.error('git-push-gate: gate.protected が設定されていません'); process.exit(1); }
// 保護ブランチ側は push の中で変わらないので、一度だけ読む（存在は pre-receive で確認済み）
const bases = protectedNames.map((b) => `refs/heads/${b}`).filter(exists).map((rev) => ({
  actions: entry(rev, ACTIONS)?.oid ?? null,
  files: new Set(workflowFiles(rev).map(({ path, oid }) => `${path}\0${oid}`)),
}));

const errors = [];
const args = process.argv.slice(2);
for (let i = 0; i < args.length; i += 2) checkCommit(args[i], args[i + 1]);

if (errors.length) {
  for (const e of errors) console.error(`git-push-gate: ${e}`);
  process.exit(1);
}

function workflowFiles(rev) {
  // .github や .github/workflows がシンボリックリンクなどだと、中身を列挙できず検査をすり抜けるので拒否
  for (const p of ['.github', DIR]) {
    const e = entry(rev, p);
    if (e && e.type !== 'tree') throw new Error(`${p} がディレクトリではありません（${rev}）`);
  }
  return list(rev, `${DIR}/`, true);
}

function checkCommit(ref, commit) {
  const actions = entry(commit, ACTIONS)?.oid ?? null;
  if (!bases.some((b) => b.actions === actions)) {
    errors.push(`${ref}: ${ACTIONS} を変更しているため拒否。人間が push してください`);
  }
  let files;
  try { files = workflowFiles(commit); } catch (e) { errors.push(`${ref}: ${e.message}`); return; }
  for (const { mode, oid, path } of files) {
    if (bases.some((b) => b.files.has(`${path}\0${oid}`))) continue; // 保護ブランチと同一
    const fail = (msg) => errors.push(`${ref}: ${path}: ${msg}`);
    if (mode !== '100644' && mode !== '100755') { fail('通常のファイル以外は置けません'); continue; }
    checkWorkflow(path, git('cat-file', 'blob', oid), fail);
  }
}

function checkWorkflow(path, text, fail) {
  if (!/\.ya?ml$/.test(path)) return fail('ワークフロー以外のファイルは置けません');

  // GitHub のパーサーとの解釈差を突かれないよう、曖昧な YAML は拒否
  // （%YAML 1.1 などのディレクティブがあると on が真偽値になる等、解釈が変わる）
  if (text.startsWith('\uFEFF')) return fail('BOM で始まるファイルは使えません');
  if (/^%/m.test(text)) return fail('YAML のディレクティブ（%）は使えません');
  const doc = parseDocument(text, { version: '1.2', uniqueKeys: true, merge: false, prettyErrors: false });
  if (doc.errors.length || doc.warnings.length) return fail('YAML として不正または曖昧');
  let tricky = false;
  // シークレットは一切参照させない。エスケープ（"\x73ecrets" など）を避けるため、解釈した後の文字列も見る
  let secrets = /secrets/i.test(text);
  visit(doc, {
    Node(_, n) {
      if (isAlias(n) || n.anchor || n.tag) tricky = true;
      if (isScalar(n) && /secrets/i.test(String(n.value))) secrets = true;
    },
  });
  if (tricky) return fail('アンカー・エイリアス・タグは使えません');
  if (secrets) fail('"secrets" を含められません');

  const wf = doc.toJS();
  if (!isMap(wf)) return fail('空または不正な構造');
  for (const k of Object.keys(wf)) if (!TOP_KEYS.has(k)) fail(`トップレベルのキー ${k} は使えません`);

  const on = wf.on;
  const triggers = typeof on === 'string' ? [on] : Array.isArray(on) ? on : isMap(on) ? Object.keys(on) : null;
  if (!triggers?.length) fail('on がないか、不正です');
  else for (const t of triggers) if (!TRIGGERS.has(t)) fail(`トリガー ${t} は使えません`);

  // GITHUB_TOKEN は読み取り専用を明示必須（省略時はリポジトリ既定値になり、write の可能性がある）
  if (!('permissions' in wf)) fail('トップレベルに permissions の明示が必要');
  else if (!readOnly(wf.permissions)) fail('トップレベルの permissions に write があります');

  if (!isMap(wf.jobs) || !Object.keys(wf.jobs).length) return fail('jobs がないか、不正です');
  for (const [id, job] of Object.entries(wf.jobs)) {
    if (!isMap(job)) { fail(`job ${id} が不正`); continue; }
    for (const k of Object.keys(job)) if (!JOB_KEYS.has(k)) fail(`job ${id}: キー ${k} は使えません`);
    if ('permissions' in job && !readOnly(job.permissions)) fail(`job ${id} の permissions に write があります`);
    if ('uses' in job) {
      // 外部の再利用可能なワークフローは中身を検査できない（呼ばれた側の runs-on でセルフホストのランナーも使える）
      if (typeof job.uses !== 'string' || !LOCAL_WORKFLOW.test(job.uses)) {
        fail(`job ${id}: uses は ./.github/workflows/ の再利用可能なワークフローのみ`);
      }
    } else if (!('runs-on' in job)) {
      fail(`job ${id}: runs-on がありません`);
    } else {
      const r = job['runs-on'];
      const labels = typeof r === 'string' ? [r] : Array.isArray(r) ? r : null;
      if (!labels || !labels.every((l) => typeof l === 'string' && RUNNER_OK.test(l))) {
        fail(`job ${id}: runs-on は GitHub ホストのランナー（ubuntu-* など）のみ`);
      }
    }
  }
}

function isMap(v) { return v !== null && typeof v === 'object' && !Array.isArray(v); }

function readOnly(p) {
  if (p === 'read-all') return true;
  if (isMap(p)) return Object.values(p).every((v) => v === 'read' || v === 'none');
  return false; // write-all、文字列式、null など
}
