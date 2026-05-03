import { spawn } from 'child_process';
import path from 'path';
import { writeFile, mkdir } from 'fs/promises';
import { existsSync } from 'fs';
import { fileURLToPath } from 'url';
import { pool } from '../db/pool.js';
import { generateUUID } from '../db/sqlite.js';
import { resolvePythonPath } from './acestep.js';
import { config } from '../config/index.js';

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

function resolveWanPath(): string {
  const envPath = process.env.WAN_PATH;
  if (envPath) return path.isAbsolute(envPath) ? envPath : path.resolve(process.cwd(), envPath);
  // Walk up from __dirname until we find the app root where Wan2.2 lives alongside ACE-Step-1.5
  let dir = __dirname;
  for (let i = 0; i < 10; i++) {
    const candidate = path.resolve(dir, 'Wan2.2');
    if (existsSync(candidate)) {
      return candidate;
    }
    const parent = path.dirname(dir);
    if (parent === dir) break;
    dir = parent;
  }
  // Fallback: assume tsx dev layout
  return path.resolve(__dirname, '../../../Wan2.2');
}

const WAN_DIR = resolveWanPath();
const OUTPUT_DIR = path.join(__dirname, '../../public/wan-output');

export interface WanJobOptions {
  prompt: string;
  audioUrl?: string;
  imageBuffer?: Buffer | null;
  imageName?: string | null;
  size?: string;
  task?: string;
  ckptDir?: string;
}

const activeWanJobs = new Map<string, { status: string; result?: any; error?: string; startedAt?: number }>();

async function ensureDir(p: string) {
  try {
    await mkdir(p, { recursive: true });
  } catch {
    // ignore
  }
}

export async function startWanJob(localJobId: string, userId: string, opts: WanJobOptions) {
  // Create job output directory
  const jobDir = path.join(OUTPUT_DIR, localJobId);
  await ensureDir(jobDir);

  // Save optional image
  let imagePath: string | null = null;
  if (opts.imageBuffer) {
    const name = opts.imageName || 'input_image.jpg';
    imagePath = path.join(jobDir, name.replace(/[^a-zA-Z0-9_.-]/g, '_'));
    await writeFile(imagePath, opts.imageBuffer);
  }

  // Resolve audio: if URL remote, download; if /audio/ path, resolve to public audio dir
  let audioLocalPath: string | undefined = undefined;
  if (opts.audioUrl) {
    if (opts.audioUrl.startsWith('/audio/')) {
      audioLocalPath = path.join(__dirname, '../../public/audio', opts.audioUrl.replace('/audio/', ''));
    } else if (opts.audioUrl.startsWith('http://') || opts.audioUrl.startsWith('https://')) {
      try {
        const res = await fetch(opts.audioUrl);
        if (res.ok) {
          const buf = Buffer.from(await res.arrayBuffer());
          const ext = path.extname(new URL(opts.audioUrl).pathname) || '.mp3';
          audioLocalPath = path.join(jobDir, `input_audio${ext}`);
          await writeFile(audioLocalPath, buf);
        }
      } catch (err) {
        console.warn('Failed to download remote audio for Wan job:', err);
      }
    } else {
      audioLocalPath = opts.audioUrl;
    }
  }

  // Ensure checkpoint dir configured
  const ckptDir = opts.ckptDir || process.env.WAN_CKPT_DIR;
  if (!ckptDir) {
    const err = 'WAN_CKPT_DIR not configured on server';
    await pool.query(`UPDATE generation_jobs SET status = 'failed', error = ? WHERE id = ?`, [err, localJobId]);
    activeWanJobs.set(localJobId, { status: 'failed', error: err });
    return;
  }

  // Prepare process
  const python = resolvePythonPath(WAN_DIR);
  const saveFile = path.join(jobDir, `${localJobId}.mp4`);
  const task = opts.task || 's2v-14B';
  const size = opts.size || '1024*704';

  const args: string[] = [
    'generate.py',
    '--task', task,
    '--size', size,
    '--ckpt_dir', ckptDir,
    '--prompt', opts.prompt,
    '--save_file', saveFile,
    '--offload_model', 'True',
    '--convert_model_dtype'
  ];

  if (audioLocalPath) args.push('--audio', audioLocalPath);
  if (imagePath) args.push('--image', imagePath);

  // Spawn process
  try {
    console.log('[Wan] Starting job:', localJobId);
    console.log('[Wan] Python:', python);
    console.log('[Wan] Working dir:', WAN_DIR);
    console.log('[Wan] Args:', args.join(' '));
    console.log('[Wan] Prompt:', opts.prompt);
    console.log('[Wan] Audio:', audioLocalPath || 'none');
    console.log('[Wan] Image:', imagePath || 'none');
    console.log('[Wan] Output:', saveFile);
    
    const child = spawn(python, args, { cwd: WAN_DIR, env: process.env });

    activeWanJobs.set(localJobId, { status: 'running', startedAt: Date.now() });
    await pool.query(`UPDATE generation_jobs SET status = 'running', updated_at = datetime('now') WHERE id = ?`, [localJobId]);

    let stdoutBuf = '';
    child.stdout.on('data', (data: Buffer) => {
      const s = data.toString();
      stdoutBuf += s;
      console.log('[Wan stdout]', s.trim());
      // Look for save message
      const m = s.match(/Saving generated video to (.+)$/m);
      if (m && m[1]) {
        const saved = m[1].trim();
        console.log('[Wan] Video saved to:', saved);
      }
    });

    child.stderr.on('data', (data: Buffer) => {
      console.error('[Wan stderr]', data.toString());
    });

    child.on('close', async (code) => {
      console.log('[Wan] Process exited with code:', code);
      if (code === 0) {
        // Success - check output file
        if (existsSync(saveFile)) {
          const publicUrl = `/wan-output/${localJobId}/${path.basename(saveFile)}`;
          console.log('[Wan] Job succeeded:', localJobId, '->', publicUrl);
          await pool.query(`UPDATE generation_jobs SET status = 'succeeded', result = ?, updated_at = datetime('now') WHERE id = ?`, [JSON.stringify({ files: [publicUrl] }), localJobId]);
          activeWanJobs.set(localJobId, { status: 'succeeded', result: { files: [publicUrl] } });
        } else {
          const err = `Wan process exited but output not found: ${saveFile}`;
          console.error('[Wan] Output file not found:', saveFile);
          await pool.query(`UPDATE generation_jobs SET status = 'failed', error = ?, updated_at = datetime('now') WHERE id = ?`, [err, localJobId]);
          activeWanJobs.set(localJobId, { status: 'failed', error: err });
        }
      } else {
        const err = `Wan process exited with code ${code}`;
        console.error('[Wan] Job failed:', localJobId, 'code:', code);
        await pool.query(`UPDATE generation_jobs SET status = 'failed', error = ?, updated_at = datetime('now') WHERE id = ?`, [err, localJobId]);
        activeWanJobs.set(localJobId, { status: 'failed', error: err });
      }
    });

    child.on('error', (err) => {
      console.error('[Wan] Process error:', err);
    });
  } catch (err: any) {
    console.error('Failed to spawn Wan process:', err);
    await pool.query(`UPDATE generation_jobs SET status = 'failed', error = ?, updated_at = datetime('now') WHERE id = ?`, [String(err || 'spawn error'), localJobId]);
    activeWanJobs.set(localJobId, { status: 'failed', error: String(err || 'spawn error') });
  }
}

export async function getWanJobStatus(localJobId: string) {
  const r = await pool.query(`SELECT id, user_id, status, result, error, params, created_at FROM generation_jobs WHERE id = ?`, [localJobId]);
  if (r.rows.length === 0) return null;
  const job = r.rows[0];
  return {
    id: job.id,
    status: job.status,
    result: job.result ? JSON.parse(job.result) : null,
    error: job.error || null,
    params: job.params ? JSON.parse(job.params) : null,
    createdAt: job.created_at,
  };
}

export { activeWanJobs };
