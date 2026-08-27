#!/usr/bin/env node
// D-5b 週次オフサイトバックアップ本体。
// 設計書: ns-portal/docs/設計書_全社バックアップと復旧_2026-08-27.md §6
//
// やること:
//   1. ハブSupabase（uuvsxzhpxtghojoubjcc）の public/info 全テーブルをJSONでエクスポート
//   2. Storage全バケットをコピー（report-photosのみ直近1年に絞る。invoice-files/documents/manual-files/
//      export-outputs/export-templatesは全量。__claude_write_test__は使い捨て検証用のため対象外）
//   3. 専用の共有ドライブ（Workload Identity連携でGitHub Actionsが直接書く。鍵ファイルは使わない）に
//      日付フォルダとしてアップロード
//   4. 直近8世代（週）を超えた古いフォルダを削除
//
// 認証: google-github-actions/auth（このジョブ内で発行されたOIDCトークン→GCPアクセストークン）。
// 実行主体は書き込み専用サービスアカウント（このドライブ以外には何もできない）。
'use strict';

const SUPABASE_URL = process.env.SUPABASE_URL || 'https://uuvsxzhpxtghojoubjcc.supabase.co';
const SUPABASE_SERVICE_KEY = required('SUPABASE_SERVICE_ROLE_KEY');
const GDRIVE_ACCESS_TOKEN = required('GDRIVE_ACCESS_TOKEN');
const DRIVE_ID = required('BACKUP_DRIVE_ID'); // 共有ドライブのURL末尾のID
const DRY_RUN = process.env.DRY_RUN === '1';
const RETAIN_GENERATIONS = 8;
// テスト時はここをtestフォルダ配下に向ける運用（既存ルール: 送信系テストは使い捨て場所で）
const ROOT_FOLDER_NAME_PREFIX = process.env.BACKUP_ROOT_PREFIX || '';

function required(name) {
  const v = process.env[name];
  if (!v) { console.error(`::error::環境変数 ${name} が未設定です`); process.exit(1); }
  return v;
}

const STORAGE_BUCKETS = [
  { name: 'invoice-files', maxAgeDays: null },
  { name: 'documents', maxAgeDays: null },
  { name: 'manual-files', maxAgeDays: null },
  { name: 'export-outputs', maxAgeDays: null },
  { name: 'export-templates', maxAgeDays: null },
  { name: 'photos', maxAgeDays: null },
  { name: 'report-photos', maxAgeDays: 366 }, // 日報写真=直近1年（設計書§6確定仕様）
];
const DB_SCHEMAS = ['public', 'info'];

// ── Supabase REST（PostgREST）ヘルパー ──
function sbHeaders(schema) {
  const h = { apikey: SUPABASE_SERVICE_KEY, Authorization: `Bearer ${SUPABASE_SERVICE_KEY}` };
  if (schema && schema !== 'public') h['Accept-Profile'] = schema;
  return h;
}

// PostgRESTのOpenAPI定義からテーブル名一覧を取得（ハードコードせず自動発見。新テーブルにも追従）
async function listTables(schema) {
  const res = await fetch(`${SUPABASE_URL}/rest/v1/`, {
    headers: { ...sbHeaders(schema), Accept: 'application/openapi+json' },
  });
  if (!res.ok) throw new Error(`テーブル一覧取得失敗 [${schema}] ${res.status}`);
  const spec = await res.json();
  return Object.keys(spec.definitions || spec.components?.schemas || {}).sort();
}

// 1テーブル分を全件ページング取得（Range-Unit: items）
async function fetchAllRows(schema, table) {
  const PAGE = 1000;
  let offset = 0; const rows = [];
  for (;;) {
    const res = await fetch(`${SUPABASE_URL}/rest/v1/${table}?select=*`, {
      headers: { ...sbHeaders(schema), 'Range-Unit': 'items', Range: `${offset}-${offset + PAGE - 1}` },
    });
    if (res.status === 416) break; // 範囲外=データ終端
    if (!res.ok && res.status !== 206) throw new Error(`${schema}.${table} 取得失敗 ${res.status}: ${(await res.text()).slice(0, 200)}`);
    const chunk = await res.json();
    rows.push(...chunk);
    if (chunk.length < PAGE) break;
    offset += PAGE;
  }
  return rows;
}

// ── Supabase Storage ヘルパー ──
async function listStorageObjects(bucket, prefix = '', out = []) {
  const res = await fetch(`${SUPABASE_URL}/storage/v1/object/list/${bucket}`, {
    method: 'POST',
    headers: { apikey: SUPABASE_SERVICE_KEY, Authorization: `Bearer ${SUPABASE_SERVICE_KEY}`, 'Content-Type': 'application/json' },
    body: JSON.stringify({ prefix, limit: 1000, sortBy: { column: 'name', order: 'asc' } }),
  });
  if (!res.ok) throw new Error(`Storage一覧取得失敗 [${bucket}/${prefix}] ${res.status}`);
  const items = await res.json();
  for (const it of items) {
    if (it.id === null) { // フォルダ（サブディレクトリ）は再帰
      await listStorageObjects(bucket, `${prefix}${it.name}/`, out);
    } else {
      out.push({ path: `${prefix}${it.name}`, updatedAt: it.updated_at || it.created_at });
    }
  }
  return out;
}
async function downloadStorageObject(bucket, path) {
  const res = await fetch(`${SUPABASE_URL}/storage/v1/object/${bucket}/${encodeURIComponent(path).replace(/%2F/g, '/')}`, {
    headers: { apikey: SUPABASE_SERVICE_KEY, Authorization: `Bearer ${SUPABASE_SERVICE_KEY}` },
  });
  if (!res.ok) throw new Error(`Storageダウンロード失敗 [${bucket}/${path}] ${res.status}`);
  return Buffer.from(await res.arrayBuffer());
}

// ── Google Drive ヘルパー（鍵ファイル不要。google-github-actions/authが発行したアクセストークンを使う）──
function gHeaders(extra = {}) { return { Authorization: `Bearer ${GDRIVE_ACCESS_TOKEN}`, ...extra }; }

async function driveCreateFolder(name, parentId) {
  const res = await fetch('https://www.googleapis.com/drive/v3/files?supportsAllDrives=true', {
    method: 'POST',
    headers: gHeaders({ 'Content-Type': 'application/json' }),
    body: JSON.stringify({ name, mimeType: 'application/vnd.google-apps.folder', parents: [parentId] }),
  });
  if (!res.ok) throw new Error(`Driveフォルダ作成失敗 [${name}] ${res.status}: ${(await res.text()).slice(0, 300)}`);
  return (await res.json()).id;
}

// multipart(1リクエストでメタデータ+中身を送る)。2026-08-27の本番初回実行が
// 「1ファイルにつき2リクエストを順番に」で650回近くかかり30分タイムアウトしたため、
// リクエスト数半減＋並列化(mapPool)の両方で対応する。
async function driveUploadFile(name, parentId, buffer, mimeType = 'application/octet-stream') {
  const boundary = `nstylebackup${Math.random().toString(16).slice(2)}`;
  const metadata = JSON.stringify({ name, parents: [parentId] });
  const body = Buffer.concat([
    Buffer.from(`--${boundary}\r\nContent-Type: application/json; charset=UTF-8\r\n\r\n${metadata}\r\n--${boundary}\r\nContent-Type: ${mimeType}\r\n\r\n`),
    buffer,
    Buffer.from(`\r\n--${boundary}--`),
  ]);
  const res = await fetch('https://www.googleapis.com/upload/drive/v3/files?uploadType=multipart&supportsAllDrives=true', {
    method: 'POST',
    headers: gHeaders({ 'Content-Type': `multipart/related; boundary=${boundary}` }),
    body,
  });
  if (!res.ok) throw new Error(`Driveアップロード失敗 [${name}] ${res.status}: ${(await res.text()).slice(0, 300)}`);
  return (await res.json()).id;
}

// 同時実行数を絞った並列マップ（Drive/Supabase APIへの負荷とタイムアウト対策のバランス）
async function mapPool(items, concurrency, fn) {
  const results = new Array(items.length);
  let next = 0;
  async function worker() {
    for (;;) {
      const i = next++;
      if (i >= items.length) return;
      results[i] = await fn(items[i], i);
    }
  }
  await Promise.all(Array.from({ length: Math.min(concurrency, items.length) }, worker));
  return results;
}

async function driveListChildren(parentId) {
  const out = []; let pageToken;
  do {
    const qs = new URLSearchParams({
      q: `'${parentId}' in parents and trashed = false`,
      fields: 'nextPageToken, files(id, name, createdTime)',
      supportsAllDrives: 'true', includeItemsFromAllDrives: 'true',
      pageSize: '1000',
    });
    if (pageToken) qs.set('pageToken', pageToken);
    const res = await fetch(`https://www.googleapis.com/drive/v3/files?${qs}`, { headers: gHeaders() });
    if (!res.ok) throw new Error(`Drive一覧取得失敗 ${res.status}: ${(await res.text()).slice(0, 300)}`);
    const j = await res.json();
    out.push(...(j.files || []));
    pageToken = j.nextPageToken;
  } while (pageToken);
  return out;
}
async function driveDeleteFile(id) {
  const res = await fetch(`https://www.googleapis.com/drive/v3/files/${id}?supportsAllDrives=true`, {
    method: 'DELETE', headers: gHeaders(),
  });
  if (!res.ok && res.status !== 404) throw new Error(`Drive削除失敗 [${id}] ${res.status}`);
}

// ── 本体 ──
function todayFolderName() {
  const d = new Date();
  const p = (n) => String(n).padStart(2, '0');
  return `${ROOT_FOLDER_NAME_PREFIX}${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())}`;
}

async function main() {
  const summary = { tables: 0, tableRows: 0, files: 0, bytes: 0, errors: [] };
  const rootName = todayFolderName();
  console.log(`バックアップ開始: ${rootName}（DRY_RUN=${DRY_RUN}）`);

  // 同じ日付のフォルダが既にあれば削除してから作る（前回が失敗・タイムアウトで
  // 中途半端に残っていても、再実行すればきれいに作り直される＝冪等）
  if (!DRY_RUN) {
    const existing = (await driveListChildren(DRIVE_ID)).filter((f) => f.name === rootName);
    for (const f of existing) { console.log(`同名フォルダ${rootName}が既存のため削除して作り直す`); await driveDeleteFile(f.id); }
  }
  const rootId = DRY_RUN ? '(dry-run)' : await driveCreateFolder(rootName, DRIVE_ID);
  const dbFolderId = DRY_RUN ? '(dry-run)' : await driveCreateFolder('db-export', rootId);
  const CONCURRENCY = 8; // Drive/Supabase双方への同時リクエスト数（速度とレート制限のバランス）

  // 1. DB全テーブル（テーブル単位で並列）
  for (const schema of DB_SCHEMAS) {
    let tables;
    try { tables = await listTables(schema); }
    catch (e) { summary.errors.push(`テーブル一覧[${schema}]: ${e.message}`); continue; }
    await mapPool(tables, CONCURRENCY, async (table) => {
      try {
        const rows = await fetchAllRows(schema, table);
        const buf = Buffer.from(JSON.stringify(rows));
        summary.tables++; summary.tableRows += rows.length; summary.bytes += buf.length;
        if (!DRY_RUN) await driveUploadFile(`${schema}.${table}.json`, dbFolderId, buf, 'application/json');
      } catch (e) {
        summary.errors.push(`テーブル[${schema}.${table}]: ${e.message}`);
      }
    });
    console.log(`DBエクスポート完了: ${schema}（${tables.length}テーブル）`);
  }

  // 2. Storage全バケット（バケット内はファイル単位で並列）
  const storageFolderId = DRY_RUN ? '(dry-run)' : await driveCreateFolder('storage', rootId);
  const cutoffByAge = (days) => days ? Date.now() - days * 86400000 : null;
  for (const { name: bucket, maxAgeDays } of STORAGE_BUCKETS) {
    let objects;
    try { objects = await listStorageObjects(bucket); }
    catch (e) { summary.errors.push(`Storage一覧[${bucket}]: ${e.message}`); continue; }
    const cutoff = cutoffByAge(maxAgeDays);
    const targets = cutoff ? objects.filter((o) => !o.updatedAt || new Date(o.updatedAt).getTime() >= cutoff) : objects;
    if (!targets.length) { console.log(`Storage[${bucket}]: 対象0件`); continue; }
    const bucketFolderId = DRY_RUN ? '(dry-run)' : await driveCreateFolder(bucket, storageFolderId);
    // サブフォルダ構造は平坦化せずファイル名にパスを埋め込む（Drive側フォルダ階層を都度作るコストを避ける）
    await mapPool(targets, CONCURRENCY, async (obj) => {
      try {
        const buf = await downloadStorageObject(bucket, obj.path);
        summary.files++; summary.bytes += buf.length;
        if (!DRY_RUN) await driveUploadFile(obj.path.replace(/\//g, '__'), bucketFolderId, buf);
      } catch (e) {
        summary.errors.push(`Storageファイル[${bucket}/${obj.path}]: ${e.message}`);
      }
    });
    console.log(`Storageコピー完了: ${bucket}（${targets.length}/${objects.length}件。maxAgeDays=${maxAgeDays || '無制限'}）`);
  }

  // 3. 世代整理（直近8世代=週を超えたフォルダを削除）
  if (!DRY_RUN) {
    const children = (await driveListChildren(DRIVE_ID))
      .filter((f) => /^\d{4}-\d{2}-\d{2}$/.test(f.name))
      .sort((a, b) => (a.name < b.name ? 1 : -1)); // 新しい順
    const toDelete = children.slice(RETAIN_GENERATIONS);
    for (const f of toDelete) {
      try { await driveDeleteFile(f.id); console.log(`世代整理: ${f.name} を削除`); }
      catch (e) { summary.errors.push(`世代整理[${f.name}]: ${e.message}`); }
    }
  }

  const mb = (summary.bytes / 1024 / 1024).toFixed(1);
  console.log(`===== 完了: テーブル${summary.tables}件(${summary.tableRows}行)・ファイル${summary.files}件・計${mb}MB・エラー${summary.errors.length}件 =====`);
  if (summary.errors.length) {
    console.log(summary.errors.slice(0, 20).join('\n'));
    process.exitCode = 1; // 失敗としてマークするが、成功した分は既にアップロード済み（部分失敗）
  }
  // GitHub Actions側でLark通知に使う要約をファイルに書き出す
  require('fs').writeFileSync('backup-summary.txt',
    `${rootName}: テーブル${summary.tables}件(${summary.tableRows}行)・ファイル${summary.files}件・計${mb}MB・エラー${summary.errors.length}件` +
    (summary.errors.length ? `\n${summary.errors.slice(0, 10).join('\n')}` : ''));
}

main().catch((e) => { console.error('::error::' + (e && e.stack || e)); process.exit(1); });
