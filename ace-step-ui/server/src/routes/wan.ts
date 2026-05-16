import { Router, Response } from 'express';
import multer from 'multer';
import path from 'path';
import { pool } from '../db/pool.js';
import { generateUUID } from '../db/sqlite.js';
import { authMiddleware, AuthenticatedRequest } from '../middleware/auth.js';
import { startWanJob } from '../services/wan.js';
import { ensureWan22Running, resetIdleTimer } from '../services/gpu-service.js';

const router = Router();

const upload = multer({ storage: multer.memoryStorage(), limits: { fileSize: 50 * 1024 * 1024 } });

router.post('/generate', authMiddleware, upload.single('image'), async (req: AuthenticatedRequest, res: Response) => {
  console.log('[Wan Route] POST /api/wan/generate called');
  console.log('[Wan Route] User:', req.user?.id);
  console.log('[Wan Route] Body:', req.body);
  console.log('[Wan Route] File:', req.file ? { name: req.file.originalname, size: req.file.size } : null);
  
  try {
    const prompt = (req.body.prompt || '').toString().trim();
    const audioUrl = req.body.audioUrl ? req.body.audioUrl.toString() : undefined;
    const size = req.body.size ? req.body.size.toString() : undefined;
    const task = req.body.task ? req.body.task.toString() : 's2v-14B';

    console.log('[Wan Route] Prompt:', prompt);
    console.log('[Wan Route] AudioUrl:', audioUrl);
    console.log('[Wan Route] Task:', task);

    if (!prompt) {
      console.log('[Wan Route] ERROR: Prompt is required');
      res.status(400).json({ error: 'Prompt is required' });
      return;
    }

    // Ensure Wan2.2 GPU service is running (on-demand)
    try {
      await ensureWan22Running();
    } catch (gpuError) {
      console.error('Failed to start Wan2.2 GPU service:', gpuError);
      res.status(503).json({ 
        error: 'Wan2.2 service is starting up. Please try again in a moment.',
        retryAfter: 60 
      });
      return;
    }

    const localJobId = generateUUID();
    console.log('[Wan Route] Created job ID:', localJobId);
    const params = { prompt, audioUrl, size, task };

    await pool.query(
      `INSERT INTO generation_jobs (id, user_id, status, params, created_at, updated_at)
       VALUES (?, ?, 'queued', ?, datetime('now'), datetime('now'))`,
      [localJobId, req.user!.id, JSON.stringify(params)]
    );

    // Kick off the Wan process asynchronously
    startWanJob(localJobId, req.user!.id, {
      prompt,
      audioUrl,
      imageBuffer: req.file ? (req.file.buffer as Buffer) : null,
      imageName: req.file ? req.file.originalname : null,
      size,
      task,
    }).catch(async (err) => {
      console.error('startWanJob error', err);
      await pool.query(`UPDATE generation_jobs SET status = 'failed', error = ? WHERE id = ?`, [String(err || 'start error'), localJobId]);
    });

    res.json({ jobId: localJobId, status: 'queued' });
  } catch (error) {
    console.error('Wan generate route error:', error);
    res.status(500).json({ error: (error as Error).message || 'Failed to create Wan job' });
  }
});

router.get('/status/:jobId', authMiddleware, async (req: AuthenticatedRequest, res: Response) => {
  try {
    const jobId = req.params.jobId;
    const r = await pool.query(`SELECT id, user_id, status, result, error, params, created_at FROM generation_jobs WHERE id = ?`, [jobId]);
    if (r.rows.length === 0) {
      res.status(404).json({ error: 'Job not found' });
      return;
    }
    const job = r.rows[0];
    if (job.user_id !== req.user!.id) {
      res.status(403).json({ error: 'Access denied' });
      return;
    }

    // Reset idle timer while user is waiting
    resetIdleTimer();

    res.json({
      id: job.id,
      status: job.status,
      result: job.result ? JSON.parse(job.result) : null,
      error: job.error || null,
      params: job.params ? JSON.parse(job.params) : null,
      createdAt: job.created_at,
    });
  } catch (error) {
    console.error('Wan status route error:', error);
    res.status(500).json({ error: (error as Error).message || 'Failed to fetch job status' });
  }
});

export default router;
