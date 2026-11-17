import {createWriteStream} from 'node:fs';
import {mkdir, rename, stat, statfs, unlink} from 'node:fs/promises';
import {join, sep} from 'node:path';
import {randomBytes} from 'node:crypto';
import {pipeline} from 'node:stream/promises';
import {Transform} from 'node:stream';

// Server-side downloads: the gateway fetches a provider file and writes it
// straight into the Jellyfin library folders on the Pi. The browser never
// sees the bytes. Jobs live in memory only and are lost on gateway restart.
const EXTENSIONS = new Set(['mp4', 'm4v', 'mov', 'mkv', 'avi', 'webm', 'ts', 'm3u8']);
const MIN_FREE_BYTES = 1024 * 1024 * 1024;
const RESERVE_BYTES = 100 * 1024 * 1024;
const MAX_JOBS_KEPT = 20;
const KNOWN_ERRORS = new Set(['unsafe_target', 'upstream_timeout', 'upstream_unavailable', 'provider_connection_failed', 'download_not_supported', 'disk_full', 'server_downloads_unavailable', 'stream_session_expired', 'invalid_request', 'download_not_found', 'cancelled']);

const fail = (code, status) => { const error = Error(code); error.code = code; error.status = status; return error; };
// Mirrors safeDownloadFilename in server.mjs (kept separate to avoid a
// circular import): strip separators and control characters, cap length.
function cleanName(value) {
  const clean = String(value ?? '').replace(/[\u0000-\u001f\u007f]/g, ' ').replace(/[/\\:*?"<>|]/g, ' ').replace(/\s+/g, ' ').trim().replace(/^\.+/, '').trim();
  let name = clean;
  if (!name) name = 'download';
  const dot = name.lastIndexOf('.');
  const ext = dot > 0 ? name.slice(dot) : '';
  let base = dot > 0 ? name.slice(0, dot) : name;
  const baseChars = [...base], extChars = [...ext];
  if (baseChars.length + extChars.length > 150) base = baseChars.slice(0, Math.max(1, 150 - extChars.length)).join('').trim();
  return (base || 'download') + ext;
}
function cleanSegment(value, fallback) {
  const clean = String(value ?? '').replace(/[\u0000-\u001f\u007f]/g, ' ').replace(/[/\\:*?"<>|]/g, ' ').replace(/\s+/g, ' ').trim().replace(/^\.+/, '').trim();
  return clean ? clean.slice(0, 100) : fallback;
}
function mapError(error) {
  if (error?.code && KNOWN_ERRORS.has(error.code)) return error.code;
  if (error?.message && KNOWN_ERRORS.has(error.message)) return error.message;
  if (error?.code === 'ENOSPC') return 'disk_full';
  if (error?.name === 'AbortError') return 'cancelled';
  return 'gateway_request_failed';
}

export function createDownloadManager({upstream, moviesDir = '', tvDir = '', now = Date.now, statfsFn = statfs, maxConcurrent = 2} = {}) {
  const configured = Boolean(moviesDir && tvDir);
  const jobs = new Map();
  let active = 0;
  const publicJob = job => ({job_id: job.id, kind: job.kind, stream_id: job.stream_id, filename: job.filename, status: job.status, bytes: job.bytes, total_bytes: job.total_bytes, error: job.error});
  const prune = () => {
    const terminal = [...jobs.values()].filter(j => j.status === 'done' || j.status === 'error').sort((a, b) => a.updatedAt - b.updatedAt);
    while (terminal.length > MAX_JOBS_KEPT) { const old = terminal.shift(); jobs.delete(old.id); }
  };
  const pump = () => {
    while (active < maxConcurrent) {
      const next = [...jobs.values()].filter(j => j.status === 'queued').sort((a, b) => a.createdAt - b.createdAt)[0];
      if (!next) return;
      active++;
      next.status = 'downloading'; next.updatedAt = now();
      void run(next).finally(() => { active--; pump(); });
    }
  };
  async function fetchUpstream(job, range) {
    const {response, url} = await upstream(job.url, range ? {range} : {});
    return {response, finalUrl: String(url)};
  }
  async function run(job) {
    let response = null;
    try {
      await mkdir(job.dir, {recursive: true});
      let partSize = 0;
      try { partSize = (await stat(job.partPath)).size; } catch (error) { if (error.code !== 'ENOENT') throw error; }
      let range = partSize > 0 ? `bytes=${partSize}-` : null;
      let fetched = await fetchUpstream(job, range);
      response = fetched.response;
      if (response.statusCode === 206 && range) {
        const match = /^bytes (\d+)-/.exec(String(response.headers['content-range'] || ''));
        if (!match || Number(match[1]) !== partSize) {
          response.destroy(); response = null;
          await unlink(job.partPath).catch(() => {});
          partSize = 0; range = null;
          fetched = await fetchUpstream(job, null);
          response = fetched.response;
        }
      } else if (response.statusCode === 200 && range) {
        // Provider ignored the range: restart from scratch.
        await unlink(job.partPath).catch(() => {});
        partSize = 0;
      } else if (![200, 206].includes(response.statusCode)) {
        response.destroy(); response = null;
        throw fail('provider_connection_failed');
      }
      const type = String(response.headers['content-type'] || '');
      if (/mpegurl/i.test(type) || /\.m3u8$/i.test(new URL(fetched.finalUrl).pathname)) { response.destroy(); response = null; throw fail('download_not_supported'); }
      const length = Number.parseInt(String(response.headers['content-length'] || ''), 10);
      const remaining = Number.isFinite(length) ? length : null;
      job.total_bytes = remaining === null ? null : (response.statusCode === 206 ? partSize + remaining : remaining);
      const need = job.total_bytes === null ? MIN_FREE_BYTES : Math.max(0, job.total_bytes - partSize) + RESERVE_BYTES;
      const space = await statfsFn(job.dir);
      const free = (space.bavail ?? 0) * (space.bsize ?? 4096);
      if (free < need) { response.destroy(); response = null; throw fail('disk_full'); }
      const controller = new AbortController();
      job.abort = () => controller.abort();
      job.bytes = partSize;
      const counter = new Transform({transform(chunk, _encoding, callback) { job.bytes += chunk.length; job.updatedAt = now(); callback(null, chunk); }});
      const out = createWriteStream(job.partPath, {flags: partSize > 0 ? 'a' : 'w'});
      try {
        await pipeline(response, counter, out, {signal: controller.signal});
      } catch (error) {
        if (job.cancelled) throw fail('cancelled');
        throw error;
      } finally {
        response = null;
      }
      await rename(job.partPath, job.finalPath);
      job.status = 'done';
      if (job.total_bytes === null) job.total_bytes = job.bytes;
      job.updatedAt = now();
    } catch (error) {
      job.status = 'error';
      job.error = mapError(error);
      job.updatedAt = now();
      if (job.error === 'disk_full') await unlink(job.partPath).catch(() => {});
      response?.destroy?.();
    } finally {
      job.abort = null;
    }
  }
  return {
    configured,
    create({session, body}) {
      if (!session || typeof session !== 'object' || !session.base || !session.username || !session.password) throw fail('stream_session_expired', 401);
      if (!configured) throw fail('server_downloads_unavailable', 503);
      if (!body || typeof body !== 'object' || Array.isArray(body)) throw fail('invalid_request', 400);
      const kind = body.kind;
      if (kind !== 'movie' && kind !== 'episode') throw fail('invalid_request', 400);
      const streamId = String(body.stream_id ?? '');
      if (!/^\d{1,20}$/.test(streamId)) throw fail('invalid_request', 400);
      const ext = String(body.container_extension ?? '');
      if (!EXTENSIONS.has(ext)) throw fail('invalid_request', 400);
      if (ext === 'm3u8') throw fail('download_not_supported', 409);
      const filename = cleanName(body.filename);
      if (!filename || filename === 'download') throw fail('invalid_request', 400);
      let dir;
      if (kind === 'movie') {
        dir = moviesDir;
      } else {
        const show = cleanSegment(body.show, 'Unknown show');
        const seasonNum = Math.min(99, Math.max(0, Number(body.season) || 0));
        dir = join(tvDir, show, 'Season ' + String(seasonNum).padStart(2, '0'));
      }
      const finalPath = join(dir, filename);
      if (!finalPath.startsWith(dir + sep)) throw fail('invalid_request', 400);
      for (const existing of jobs.values()) {
        if (existing.finalPath === finalPath && (existing.status === 'queued' || existing.status === 'downloading')) return publicJob(existing);
      }
      const url = session.base + '/' + (kind === 'movie' ? 'movie' : 'series') + '/' + encodeURIComponent(session.username) + '/' + encodeURIComponent(session.password) + '/' + streamId + '.' + ext;
      const job = {id: randomBytes(12).toString('base64url'), kind, stream_id: streamId, filename, status: 'queued', bytes: 0, total_bytes: null, error: null, createdAt: now(), updatedAt: now(), url, dir, finalPath, partPath: finalPath + '.part', cancelled: false, abort: null};
      jobs.set(job.id, job);
      prune();
      const created = publicJob(job);
      pump();
      return created;
    },
    get(id) {
      const job = jobs.get(String(id));
      return job ? publicJob(job) : null;
    },
    list() {
      return [...jobs.values()].sort((a, b) => b.createdAt - a.createdAt).slice(0, MAX_JOBS_KEPT).map(publicJob);
    },
    close() {
      for (const job of jobs.values()) {
        if (job.status === 'queued' || job.status === 'downloading') { job.cancelled = true; job.abort?.(); }
      }
    },
  };
}
