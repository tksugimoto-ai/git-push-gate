// pre-receive から呼ぶ: node check-workflows.mjs <commit>
// 保護ブランチ（既定: main / develop）のどれとも内容が異なるワークフローファイルだけを、安全ポリシーで検査する。
// 方針: 判断に迷うものはすべて拒否（＝人間がホストから push）。
import { execFileSync } from 'node:child_process';
import { parseDocument, visit, isAlias } from 'yaml';

const commit = process.argv[2];
const BASES = (process.env.GIT_PUSH_GATE_PROTECTED ?? 'main develop').split(/\s+/).filter(Boolean).map((b) => `refs/heads/${b}`);
const DIR = '.github/workflows/';
const BANNED_TRIGGERS = new Set(['pull_request_target', 'workflow_run']); // 特権コンテキストで動くもの
const RUNNER_OK = /^(ubuntu|windows|macos)-[\w.-]+$/;                     // GitHub ホストのランナーのみ

const git = (...args) => execFileSync('git', args, { encoding: 'utf8', maxBuffer: 1 << 26 });
const tryGit = (...args) => { try { return git(...args).trim(); } catch { return null; } };

const files = git('ls-tree', '-r', '--name-only', commit, '--', DIR).split('\n').filter(Boolean);
const errors = [];

for (const path of files) {
  const blob = tryGit('rev-parse', `${commit}:${path}`);
  if (BASES.some((b) => tryGit('rev-parse', `${b}:${path}`) === blob)) continue; // 未変更
  const fail = (msg) => errors.push(`${path}: ${msg}`);

  if (!/\.ya?ml$/.test(path)) { fail('ワークフロー以外のファイルは置けません'); continue; }
  const text = git('cat-file', 'blob', blob);

  // シークレットは一切参照させない（secrets.X / secrets['X'] / toJSON(secrets) / secrets: inherit すべて）
  if (/secrets/i.test(text)) fail('"secrets" を含められません');

  // GitHub のパーサーとの解釈差を突かれないよう、曖昧な YAML は拒否
  const doc = parseDocument(text, { uniqueKeys: true, merge: false, prettyErrors: false });
  if (doc.errors.length || doc.warnings.length) { fail('YAML として不正または曖昧'); continue; }
  let tricky = false;
  visit(doc, { Node(_, n) { if (isAlias(n) || n.anchor || n.tag) tricky = true; } });
  if (tricky) { fail('アンカー・エイリアス・タグは使えません'); continue; }

  const wf = doc.toJS();
  if (!wf || typeof wf !== 'object') { fail('空または不正な構造'); continue; }

  const on = wf.on;
  const triggers = typeof on === 'string' ? [on] : Array.isArray(on) ? on : Object.keys(on ?? {});
  for (const t of triggers) if (BANNED_TRIGGERS.has(t)) fail(`トリガー ${t} は使えません`);

  // GITHUB_TOKEN は読み取り専用を明示必須（省略時はリポジトリ既定値になり、write の可能性がある）
  if (!('permissions' in wf)) fail('トップレベルに permissions の明示が必要');
  else if (!readOnly(wf.permissions)) fail('トップレベルの permissions に write があります');

  for (const [id, job] of Object.entries(wf.jobs ?? {})) {
    if (!job || typeof job !== 'object') { fail(`job ${id} が不正`); continue; }
    if ('permissions' in job && !readOnly(job.permissions)) fail(`job ${id} の permissions に write があります`);
    if ('environment' in job) fail(`job ${id}: environment は使えません`);
    if ('runs-on' in job) {
      const r = job['runs-on'];
      const labels = typeof r === 'string' ? [r] : Array.isArray(r) ? r : null;
      if (!labels || !labels.every((l) => typeof l === 'string' && RUNNER_OK.test(l))) {
        fail(`job ${id}: runs-on は GitHub ホストのランナー（ubuntu-* など）のみ`);
      }
    } else if (!('uses' in job)) {
      fail(`job ${id}: runs-on がありません`);
    }
  }
}

function readOnly(p) {
  if (p === 'read-all') return true;
  if (p && typeof p === 'object' && !Array.isArray(p)) {
    return Object.values(p).every((v) => v === 'read' || v === 'none');
  }
  return false; // write-all、文字列式、null など
}

if (errors.length) {
  for (const e of errors) console.error(`git-push-gate: ${e}`);
  process.exit(1);
}
