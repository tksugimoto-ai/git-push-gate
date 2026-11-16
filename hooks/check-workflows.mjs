// pre-receive から呼ぶ: node check-workflows.mjs <ref> <commit> [<ref> <commit> ...]
// 保護ブランチ（リポジトリ設定 gate.protected）のどれとも内容が異なるものだけを検査する。
//   .github/actions   : 保護ブランチのどれかと同一でなければ拒否（既存の特権付きワークフローから呼ばれうるため）
//   .github/workflows : 異なるファイルを安全ポリシーで検査
// 方針: 判断に迷うものはすべて拒否（＝人間がホストから push）。
import { execFileSync } from 'node:child_process';
import { parseDocument, visit, isAlias } from 'yaml';

const DIR = '.github/workflows/';
const ACTIONS = '.github/actions';
const BANNED_TRIGGERS = new Set(['pull_request_target', 'workflow_run']); // 特権コンテキストで動くもの
const RUNNER_OK = /^(ubuntu|windows|macos)-[\w.-]+$/;                     // GitHub ホストのランナーのみ

const git = (args, stderr = 'inherit') => execFileSync('git', args, { encoding: 'utf8', maxBuffer: 1 << 26, stdio: ['ignore', 'pipe', stderr] });
// 失敗してよい呼び出し（存在しないブランチやパス）。エラー出力はクライアントに見せない
const tryGit = (...args) => { try { return git(args, 'ignore').trim(); } catch { return null; } };
// -z でないと、ASCII 以外を含むパスが引用符付きで出力され、比較を誤る
const workflows = (rev) => (tryGit('ls-tree', '-r', '-z', rev, '--', DIR) ?? '').split('\0').filter(Boolean)
  .map((line) => { const [meta, path] = line.split('\t'); return { blob: meta.split(' ')[2], path }; });

const protectedNames = tryGit('config', '--get', 'gate.protected')?.split(/\s+/).filter(Boolean);
if (!protectedNames) { console.error('git-push-gate: gate.protected が設定されていません'); process.exit(1); }
// 保護ブランチ側は push の中で変わらないので、一度だけ読む（存在しないブランチは「何もない」として扱う）
const bases = protectedNames.map((b) => {
  const rev = `refs/heads/${b}`;
  return {
    actions: tryGit('rev-parse', '-q', '--verify', `${rev}:${ACTIONS}`),
    files: new Set(workflows(rev).map(({ path, blob }) => `${path}\0${blob}`)),
  };
});

const errors = [];
const args = process.argv.slice(2);
for (let i = 0; i < args.length; i += 2) checkCommit(args[i], args[i + 1]);

if (errors.length) {
  for (const e of errors) console.error(`git-push-gate: ${e}`);
  process.exit(1);
}

function checkCommit(ref, commit) {
  const actions = tryGit('rev-parse', '-q', '--verify', `${commit}:${ACTIONS}`);
  if (!bases.some((b) => b.actions === actions)) {
    errors.push(`${ref}: ${ACTIONS} を変更しているため拒否。人間が push してください`);
  }
  for (const { blob, path } of workflows(commit)) {
    if (bases.some((b) => b.files.has(`${path}\0${blob}`))) continue; // 保護ブランチと同一
    checkWorkflow(blob, (msg) => errors.push(`${ref}: ${path}: ${msg}`), path);
  }
}

function checkWorkflow(blob, fail, path) {
  if (!/\.ya?ml$/.test(path)) return fail('ワークフロー以外のファイルは置けません');
  const text = git(['cat-file', 'blob', blob]);

  // シークレットは一切参照させない（secrets.X / secrets['X'] / toJSON(secrets) / secrets: inherit すべて）
  if (/secrets/i.test(text)) fail('"secrets" を含められません');

  // GitHub のパーサーとの解釈差を突かれないよう、曖昧な YAML は拒否
  const doc = parseDocument(text, { uniqueKeys: true, merge: false, prettyErrors: false });
  if (doc.errors.length || doc.warnings.length) return fail('YAML として不正または曖昧');
  let tricky = false;
  visit(doc, { Node(_, n) { if (isAlias(n) || n.anchor || n.tag) tricky = true; } });
  if (tricky) return fail('アンカー・エイリアス・タグは使えません');

  const wf = doc.toJS();
  if (!wf || typeof wf !== 'object') return fail('空または不正な構造');

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
