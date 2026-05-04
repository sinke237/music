import { spawn } from 'child_process';
import path from 'path';
import { writeFile, mkdir } from 'fs/promises';
import { existsSync } from 'fs';
import { fileURLToPath } from 'url';
import { pool } from '../db/pool.js';
import { generateUUID } from '../db/sqlite.js';
import { resolvePythonPath } from './acestep.js';
import { config } from '../config/index.js';
import { runWithGpuLock } from './gpu-lock.js';

// GPU allocation for Wan video generation
// ACE-Step runs on GPU 0, so Wan2.2 should use different GPU(s)
// We dynamically select GPUs based on current memory usage to avoid OOM

async function getAvailableGPUs(): Promise<string> {
  try {
    const { execSync } = await import('child_process');
    const output = execSync('nvidia-smi --query-gpu=index,memory.used,memory.total --format=csv,noheader').toString();
    const gpus = output.trim().split('\n').map(line => {
      const [index, used, total] = line.split(',').map(s => s.trim());
      return {
        index: parseInt(index),
        used: parseInt(used.replace(' MiB', '')),
        total: parseInt(total.replace(' MiB', ''))
      };
    });

    // Assume ACE-Step uses GPU 0, so we ignore it
    // Find GPUs with plenty of free memory (e.g., > 18GB free)
    const available = gpus
      .filter(g => g.index > 0 && (g.total - g.used) > 18000)
      .map(g => g.index.toString());

    return available.length > 0 ? available.join(',') : '1,2,3'; // Fallback
  } catch (e) {
    console.error('Failed to detect GPUs, using default', e);
    return '1,2,3';
  }
}

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
  return runWithGpuLock(async () => {
    console.log('[Wan] Job', localJobId, 'acquired lock');
    console.log('[Wan] Starting startWanJob for:', localJobId);
    console.log('[Wan] WAN_CKPT_DIR env:', process.env.WAN_CKPT_DIR || 'NOT SET');
    
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
      console.error('[Wan] ERROR:', err, 'for job:', localJobId);
      await pool.query(`UPDATE generation_jobs SET status = 'failed', error = ? WHERE id = ?`, [err, localJobId]);
      activeWanJobs.set(localJobId, { status: 'failed', error: err });
      throw new Error(err);
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
      '--offload_model', 'True',  // Enable offloading to manage memory safely
      '--convert_model_dtype',    // Convert to bf16 for lower memory
    ];

    if (audioLocalPath) args.push('--audio', audioLocalPath);
    if (imagePath) args.push('--image', imagePath);

    // Use torchrun for multi-GPU parallelism
    const nGPU = 3; // GPUs 1, 2, 3 — GPU 0 reserved for ACE-Step

    const torchrunArgs = [
      `--nproc_per_node=${nGPU}`,
      'generate.py',
      '--task', task,
      '--size', size,
      '--ckpt_dir', ckptDir,
      '--prompt', opts.prompt,
      '--save_file', saveFile,
      '--dit_fsdp',            // shard DiT across the 3 GPUs
      '--t5_fsdp',             // shard T5 across the 3 GPUs
      '--ulysses_size', String(nGPU),
      '--convert_model_dtype',
    ];

    if (audioLocalPath) torchrunArgs.push('--audio', audioLocalPath);
    if (imagePath) torchrunArgs.push('--image', imagePath);

    const wanEnv = {
      ...process.env,
      CUDA_VISIBLE_DEVICES: '1,2,3', // GPU 0 stays for ACE-Step
    };

    try {
      console.log('[Wan] Starting job:', localJobId);
      console.log('[Wan] Working dir:', WAN_DIR);
      console.log('[Wan] Args:', torchrunArgs.join(' '));
      console.log('[Wan] Env:', JSON.stringify(wanEnv));
      
      // Use explicit torchrun path
      const torchrun = path.join(WAN_DIR, '.venv/bin/torchrun');
      const child = spawn(torchrun, torchrunArgs, { cwd: WAN_DIR, env: wanEnv });

      activeWanJobs.set(localJobId, { status: 'running', startedAt: Date.now() });
      await pool.query(`UPDATE generation_jobs SET status = 'running', updated_at = datetime('now') WHERE id = ?`, [localJobId]);

      let stdoutBuf = '';
      child.stdout.on('data', (data: Buffer) => {
        const s = data.toString();
        stdoutBuf += s;
        // Log every step clearly
        s.split('\n').forEach(line => {
          if (line.trim()) {
            console.log(`[Wan Progress] ${line.trim()}`);
          }
        });
      });
  
      child.stderr.on('data', (data: Buffer) => {
        console.error('[Wan Error/Log]', data.toString().trim());
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
    console.log('[Wan] Job', localJobId, 'released lock');
  });
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
