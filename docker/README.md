# Running Studio in Docker

This setup runs YuE2 and Studio in a container on a Linux host with an NVIDIA GPU. It does not use a
Dockerfile of its own: it is built on the
[`mmartial/comfyui-nvidia-docker`](https://github.com/mmartial/ComfyUI-Nvidia-Docker) image, which
already ships everything NVIDIA acceleration needs (Ubuntu 24.04, the CUDA 13.0 toolkit with `nvcc`,
GCC 13, Python and a user mapped to your host UID). The image is made for ComfyUI, but it runs a
user script on start; `user_script.bash` sets up YuE2 and Studio there and exits before ComfyUI would
start.

## Requirements

- A Linux host with an NVIDIA GPU. YuE2's baseline is a BF16-capable GPU with 24 GB VRAM; see
  [settings and performance](../docs/settings.md).
- An NVIDIA driver new enough for CUDA 13.0 (the R580 series or newer). Check with `nvidia-smi`.
- Docker with Compose v2 and the
  [NVIDIA Container Toolkit](https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/latest/install-guide.html),
  so containers can see the GPU.
- Disk space: about 30 GB to start. The image is about 5 GB, the image's own ComfyUI venv about 7 GB,
  and YuE2's venv and the two required models about 15 GB. If you use GGUF, the audio.cpp build adds about
  5 GB and each GGUF model 3 to 7.5 GB.
- Internet access on the first start, for the image, the Git repos, Python packages and model weights.

## Layout

Create a folder on the host and copy the two files from this directory into it:

```text
yue2_studio/
├── compose.yaml            # copy of docker/compose.yaml
├── basedir/                # ComfyUI's data folder; the image requires it, Studio does not use it
├── userscripts_dir/        # unused by Studio
└── run/                    # mounted at /comfy/mnt
    ├── user_script.bash    # copy of docker/user_script.bash; must be executable
    ├── venv/  ComfyUI/  HF/  # created by the image itself
    └── YuE/                # created by the script: YuE2 checkout, its .venv and models/
        ├── models/YuE2-3B
        ├── models/YuE2-Vae
        ├── tools/audio.cpp # only with YUE2_BUILD_AUDIOCPP=1
        └── Yue2_Studio/    # this repository, dockerized branch
```

```bash
mkdir -p yue2_studio/run yue2_studio/basedir yue2_studio/userscripts_dir
cp docker/compose.yaml yue2_studio/
cp docker/user_script.bash yue2_studio/run/ && chmod +x yue2_studio/run/user_script.bash
```

`compose.yaml` also mounts `../models` at `/basedir/models` for ComfyUI. Studio does not use it;
remove that line if the folder does not exist on your host.

Set `WANTED_UID` and `WANTED_GID` in `compose.yaml` to the output of `id -u` and `id -g`. The image runs
as that user, so everything written under `run/` belongs to you on the host.

## Start

```bash
cd yue2_studio
docker compose up        # add -d to run in the background, then: docker compose logs -f
```

Then open <http://localhost:7862> on the host.

What `user_script.bash` does on each start (log lines start with `[yue2_studio]`):

1. Clones or updates [YuE2](https://github.com/multimodal-art-projection/YuE) into `/comfy/mnt/YuE` and
   pins it to the commit Studio supports.
2. Creates `YuE/.venv` if missing and installs YuE2 into it.
3. Downloads the pinned `m-a-p/YuE2-3B` and `m-a-p/YuE2-Vae` weights into `YuE/models/` (about 8 GB),
   the folders Studio uses by default. A `.yue2-revision` stamp in each folder skips this on later
   starts; an interrupted download resumes.
4. If `YUE2_BUILD_AUDIOCPP=1`, builds the audio.cpp engine (see below).
5. Clones or updates this repository's `dockerized` branch into `YuE/Yue2_Studio`, and runs
   `install_studio.py`, which copies Studio into the YuE2 checkout.
6. Starts Studio with `--host 0.0.0.0 --no-browser --keep-alive`.

The first start takes a while: the image prepares its own venv, then YuE2 installs and the weights
download. Later starts only check for updates.

When Studio stops, the script exits with status 1. That is deliberate: it stops the image from going on
to start ComfyUI, so the container stops with it.

## Settings

| Setting | Where | Default | Effect |
| --- | --- | --- | --- |
| `YUE2_BUILD_AUDIOCPP` | `environment:` in `compose.yaml` | `0` | `1` builds audio.cpp for the GGUF engine |
| `YUE2_STUDIO_ALLOW_HOSTS` | `environment:` in `compose.yaml` | empty | Extra host names or IPs the browser may use, comma-separated |
| `ports:` | `compose.yaml` | `"7862:7862"` | Where the host publishes Studio |
| `STUDIO_REPO`, `STUDIO_BRANCH` | top of `user_script.bash` | this fork, `dockerized` | Which Studio code is installed |
| `YUE2_MODEL_REVISION`, `YUE2_VAE_REVISION` | top of `user_script.bash` | pinned | Change to fetch other model revisions |
| `AUDIOCPP_COMMIT`, `AUDIOCPP_CUDA_ARCH` | top of `user_script.bash` | pinned, `native` | audio.cpp source and GPU target |

To give the launcher other flags, such as `--allow-host studio.lan` or `--runs-dir`, add them to the
`launch_studio.py` line in `user_script.bash`.

### Optional: audio.cpp for GGUF models

Studio's default engine, Torch, needs nothing extra. The experimental GGUF engine runs compressed YuE2
weights through a separate C++ program, audio.cpp. It uses less VRAM, but cannot play LoRAs, train or
export plan-only scores. To use it, set `YUE2_BUILD_AUDIOCPP=1`. The script then installs `cmake` and
`ninja-build` and builds `audiocpp_cli` with CUDA into `YuE/tools/audio.cpp/build/bin`, where Studio
finds it automatically. The first build takes several minutes; later starts skip it until
`AUDIOCPP_COMMIT` changes. Download a GGUF model from Studio's **Music models** panel afterwards. If the
build fails, the script logs a warning and starts Studio with Torch.

## Access and security

Studio has no login: anyone who can open the page can generate, upload files and shut it down.

- `"7862:7862"` publishes Studio on every host interface. Use `"127.0.0.1:7862:7862"` to keep it on the
  host only.
- Studio only answers to the host names `localhost` and `127.0.0.1`, on any port, so a remapped port
  such as `"8080:7862"` works. To browse by a LAN name or IP, add it to `YUE2_STUDIO_ALLOW_HOSTS`;
  other names get "Studio accepts loopback hosts only".
- From another machine without publishing on the LAN, use an SSH tunnel:
  `ssh -L 7862:127.0.0.1:7862 you@docker-host`, then open `http://localhost:7862` there.

## Stopping and updating

- Stop with `docker compose down`, or Ctrl+C when running in the foreground. Closing browser tabs does
  not stop Studio in the container (`--keep-alive`).
- Restarting updates YuE2 to its pinned commit and Studio to the latest `dockerized` commit. Models,
  the venv, the audio.cpp build and Studio's songs and uploads under `YuE/runs/studio` are kept, since they live
  in the mounted `run/` folder.
- Each start resets `YuE/Yue2_Studio` to `origin/dockerized`. If that checkout has uncommitted changes,
  the script skips the update and logs a warning instead, so the work is not lost. Commit and push to
  pick up updates again.
- `user_script.bash` in `run/` is a copy and is not updated automatically. After pulling changes to
  `docker/user_script.bash`, copy it again (while the container is stopped; bash reads a running script
  from disk as it goes).

## Troubleshooting

- **No GPU in the container**: `docker compose exec comfyui-nvidia130-yue2_studio nvidia-smi` should list
  it. If not, check the NVIDIA Container Toolkit and the `deploy.resources` block in `compose.yaml`.
- **The page does not load from the host**: the log should show `YuE2 Studio: http://127.0.0.1:7862`
  (it listens on `0.0.0.0` even though it prints `127.0.0.1`). Check that `ports:` publishes 7862 and
  that nothing else on the host uses it.
- **"Studio accepts loopback hosts only"**: the address in the browser is not `localhost` or
  `127.0.0.1`; add it to `YUE2_STUDIO_ALLOW_HOSTS`.
- **"User script ... failed or exited with an error"** right after start: read the `[yue2_studio]` lines
  above it. Studio stopping normally ends the same way, since the script exits with status 1.
- **Models not found in Studio**: `YuE/models/YuE2-3B` and `YuE/models/YuE2-Vae` should each contain a
  `config.json` and a `.yue2-revision` file. If a download was interrupted, restart the container to
  resume it.
