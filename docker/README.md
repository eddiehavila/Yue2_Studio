# Running Studio in Docker

This setup runs YuE2 and Studio inside the
[`mmartial/comfyui-nvidia-docker`](https://github.com/mmartial/ComfyUI-Nvidia-Docker) image, using its
user-script hook instead of starting ComfyUI. The image provides CUDA and the NVIDIA runtime.

## Files

- `compose.yaml`: the container definition. `./run` is mounted at `/comfy/mnt` and port 7862 is published.
- `user_script.bash`: runs at container start (from `/comfy/mnt/user_script.bash`). It:
  1. clones or updates YuE into `/comfy/mnt/YuE` and pins it to a known commit,
  2. builds a venv there and installs YuE,
  3. clones or updates this repo (`dockerized` branch) into `/comfy/mnt/YuE/Yue2_Studio`,
  4. runs `install_studio.py`, which copies Studio into the YuE checkout,
  5. if `YUE2_BUILD_AUDIOCPP=1`, builds the audio.cpp engine for the optional GGUF backend into
     `YuE/tools/audio.cpp` (once per pinned commit),
  6. starts the installed launcher with `--host 0.0.0.0 --no-browser --keep-alive`.

  The script exits 1 when Studio stops, so the image does not go on to start ComfyUI.

## Setup

```
yue2_studio/
├── compose.yaml          # copy of docker/compose.yaml
└── run/
    └── user_script.bash  # copy of docker/user_script.bash
```

```bash
docker compose up
```

Then open <http://localhost:7862> on the host.

## Notes

- Each start resets the Studio checkout to `origin/dockerized`. A checkout with uncommitted changes is
  left alone, with a warning, so work in progress there is not lost. Commit or push it to get updates again.
- Studio has no login. `"7862:7862"` publishes it on every host interface; use
  `"127.0.0.1:7862:7862"` to keep it on the host only.
- audio.cpp is off by default; Torch, the default engine, does not need it. GGUF trades LoRA, training
  and plan-only support for lower VRAM. To build it, add `YUE2_BUILD_AUDIOCPP=1` under `environment:`
  in `compose.yaml`. The first build takes several minutes.
- To open it by a LAN name or IP, pass `--allow-host <name>` to the launcher, or set
  `YUE2_STUDIO_ALLOW_HOSTS` in `compose.yaml`.
