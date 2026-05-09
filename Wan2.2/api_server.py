#!/usr/bin/env python3
"""
Wan2.2 API Server
FastAPI wrapper for Wan2.2 video generation

This server provides REST API endpoints for:
- Text-to-Video generation
- Image-to-Video generation
- Speech-to-Video generation

GPU Configuration:
- Uses CUDA_VISIBLE_DEVICES environment variable
- Defaults to GPU 0 for g5.4xlarge (1x A10G 24GB)
- Wan2.2-14B-GGUF (Q6_K) runs in ~12-14GB VRAM
"""

import argparse
import json
import logging
import os
import sys
import tempfile
import traceback
from datetime import datetime
from pathlib import Path
from typing import Optional

import torch
import uvicorn
from fastapi import FastAPI, File, Form, HTTPException, UploadFile
from fastapi.responses import FileResponse, JSONResponse
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel

sys.path.insert(0, str(Path(__file__).parent))

logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s'
)
logger = logging.getLogger(__name__)

app = FastAPI(
    title="Wan2.2 Video Generation API",
    description="API for Wan2.2 video generation models",
    version="2.2.0",
    docs_url="/docs",
    redoc_url="/redoc"
)

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

global_checkpoint_dir = None
global_default_size = "1280x720"


class TextToVideoRequest(BaseModel):
    prompt: str
    size: str = "1280x720"
    num_frames: Optional[int] = None
    sample_steps: Optional[int] = None
    seed: Optional[int] = None
    use_prompt_extend: bool = False
    prompt_extend_model: str = "Qwen/Qwen2.5-14B-Instruct"


class ImageToVideoRequest(BaseModel):
    prompt: str
    size: str = "1280x720"
    num_frames: Optional[int] = None
    sample_steps: Optional[int] = None
    seed: Optional[int] = None


class HealthResponse(BaseModel):
    status: str
    cuda_available: bool
    cuda_device_count: int
    cuda_devices: list
    checkpoint_dir: str


@app.get("/health", response_model=HealthResponse)
async def health_check():
    cuda_available = torch.cuda.is_available()
    return HealthResponse(
        status="healthy",
        cuda_available=cuda_available,
        cuda_device_count=torch.cuda.device_count() if cuda_available else 0,
        cuda_devices=[f"cuda:{i}" for i in range(torch.cuda.device_count())] if cuda_available else [],
        checkpoint_dir=str(global_checkpoint_dir) if global_checkpoint_dir else ""
    )


@app.post("/api/wan22/t2v")
async def text_to_video(request: TextToVideoRequest):
    logger.info(f"Text-to-Video request: {request.prompt[:50]}...")
    
    if not global_checkpoint_dir:
        raise HTTPException(status_code=500, detail="Checkpoint directory not configured")
    
    try:
        import wan
        from wan.configs import WAN_CONFIGS
        from wan.utils.utils import save_video
        
        task = "t2v-A14B"
        cfg = WAN_CONFIGS[task]
        
        logger.info(f"Generating video with {task}...")
        logger.info(f"Prompt: {request.prompt}")
        logger.info(f"Size: {request.size}")
        
        output_dir = Path(tempfile.mkdtemp(prefix="wan_output_"))
        output_path = output_dir / "output.mp4"
        
        import subprocess
        import shlex
        
        cmd = [
            "python", str(Path(__file__).parent / "generate.py"),
            "--task", task,
            "--size", request.size.replace("x", "*"),
            "--ckpt_dir", str(global_checkpoint_dir),
            "--offload_model", "True",
            "--convert_model_dtype",
            "--prompt", request.prompt,
        ]
        
        if request.seed is not None:
            cmd.extend(["--base_seed", str(request.seed)])
        
        if request.sample_steps:
            cmd.extend(["--sample_steps", str(request.sample_steps)])
        
        if request.use_prompt_extend:
            cmd.extend([
                "--use_prompt_extend",
                "--prompt_extend_model", request.prompt_extend_model
            ])
        
        env = os.environ.copy()
        if "CUDA_VISIBLE_DEVICES" not in env:
            env["CUDA_VISIBLE_DEVICES"] = "1,2,3,4,5,6,7"
        
        logger.info(f"Running command: {' '.join(cmd)}")
        result = subprocess.run(
            cmd,
            cwd=str(Path(__file__).parent),
            env=env,
            capture_output=True,
            text=True
        )
        
        if result.returncode != 0:
            logger.error(f"Generation failed: {result.stderr}")
            raise HTTPException(status_code=500, detail=f"Generation failed: {result.stderr}")
        
        output_files = list(output_dir.glob("*.mp4"))
        if output_files:output_file = output_files[0]
            return FileResponse(
                path=str(output_file),
                media_type="video/mp4",
                filename=f"wan22_t2v_{datetime.now().strftime('%Y%m%d_%H%M%S')}.mp4"
            )
        else:
            results_dir = Path(__file__).parent
            mp4_files = sorted(results_dir.glob("*.mp4"), key=lambda x: x.stat().st_mtime, reverse=True)
            if mp4_files:
                latest_video = mp4_files[0]
                return FileResponse(
                    path=str(latest_video),
                    media_type="video/mp4",
                    filename=f"wan22_t2v_{datetime.now().strftime('%Y%m%d_%H%M%S')}.mp4"
                )
        
        raise HTTPException(status_code=500, detail="No video file generated")
        
    except Exception as e:
        logger.error(f"Error in text-to-video generation: {traceback.format_exc()}")
        raise HTTPException(status_code=500, detail=str(e))


@app.post("/api/wan22/i2v")
async def image_to_video(
    prompt: str = Form(...),
    image: UploadFile = File(...),
    size: str = Form("1280x720"),
    sample_steps: Optional[int] = Form(None),
    seed: Optional[int] = Form(None)
):
    logger.info(f"Image-to-Video request: {prompt[:50]}...")
    
    if not global_checkpoint_dir:
        raise HTTPException(status_code=500, detail="Checkpoint directory not configured")
    
    try:
        output_dir = Path(tempfile.mkdtemp(prefix="wan_output_"))
        image_path = output_dir / "input_image.jpg"
        
        with open(image_path, "wb") as f:
            f.write(await image.read())
        import subprocess
        
        cmd = [
            "python", str(Path(__file__).parent / "generate.py"),
            "--task", "i2v-A14B",
            "--size", size.replace("x", "*"),
            "--ckpt_dir", str(global_checkpoint_dir),
            "--offload_model", "True",
            "--convert_model_dtype",
            "--prompt", prompt,
            "--image", str(image_path),
        ]
        
        if seed is not None:
            cmd.extend(["--base_seed", str(seed)])
        
        if sample_steps:
            cmd.extend(["--sample_steps", str(sample_steps)])
        
        env = os.environ.copy()
        if "CUDA_VISIBLE_DEVICES" not in env:
            env["CUDA_VISIBLE_DEVICES"] = "1,2,3,4,5,6,7"
        
        result = subprocess.run(cmd, cwd=str(Path(__file__).parent), env=env, capture_output=True, text=True)
        
        if result.returncode != 0:
            logger.error(f"Generation failed: {result.stderr}")
            raise HTTPException(status_code=500, detail=f"Generation failed: {result.stderr}")
        
        results_dir = Path(__file__).parent
        mp4_files = sorted(results_dir.glob("*.mp4"), key=lambda x: x.stat().st_mtime, reverse=True)
        
        if mp4_files:
            latest_video = mp4_files[0]
            return FileResponse(
                path=str(latest_video),
                media_type="video/mp4",
                filename=f"wan22_i2v_{datetime.now().strftime('%Y%m%d_%H%M%S')}.mp4"
            )
        
        raise HTTPException(status_code=500, detail="No video file generated")
        
    except Exception as e:
        logger.error(f"Error in image-to-video generation: {traceback.format_exc()}")
        raise HTTPException(status_code=500, detail=str(e))


@app.get("/")
async def root():
    return {
        "service": "Wan2.2 Video Generation API",
        "version": "2.2.0",
        "endpoints": {
            "health": "/health",
            "docs": "/docs",
            "text_to_video": "/api/wan22/t2v",
            "image_to_video": "/api/wan22/i2v"
        }
    }


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Wan2.2 API Server")
    parser.add_argument("--host", type=str, default="127.0.0.1", help="Host to bind to")
    parser.add_argument("--port", type=int, default=8080, help="Port to bind to")
    parser.add_argument("--ckpt-dir", type=str, required=True, help="Path to model checkpoint directory")
    parser.add_argument("--default-size", type=str, default="1280x720", help="Default video size")
    
    args = parser.parse_args()
    
    global_checkpoint_dir = Path(args.ckpt_dir)
    global_default_size = args.default_size
    
    if not global_checkpoint_dir.exists():
        logger.error(f"Checkpoint directory not found: {global_checkpoint_dir}")
        sys.exit(1)
    
    logger.info(f"Starting Wan2.2 API Server on {args.host}:{args.port}")
    logger.info(f"Checkpoint directory: {global_checkpoint_dir}")
    logger.info(f"CUDA devices: {os.environ.get('CUDA_VISIBLE_DEVICES', 'all')}")
    
    uvicorn.run(
        app,
        host=args.host,
        port=args.port,
        log_level="info"
    )