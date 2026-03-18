# Plex HTPC Profile Manager

Automatic content-aware profile switching for Plex HTPC and Plex Desktop's embedded mpv player.

Detects **anime vs live-action** using Plex library metadata, then applies the optimal shader chain, scaling algorithm, and debanding settings — automatically adapting to your **GPU**, source **resolution**, and **bitrate**. No manual shader switching needed.

---

## Table of Contents

- [Overview](#overview)
- [How It Works](#how-it-works)
- [Profile Decision Tree](#profile-decision-tree)
- [Anime Detection](#anime-detection)
- [Bitrate-Aware Mode Selection](#bitrate-aware-mode-selection)
- [GPU Auto-Detection](#gpu-auto-detection)
- [Anime4K Modes Explained](#anime4k-modes-explained)
- [Cinema Profile](#cinema-profile)
- [HDR Profile](#hdr-profile)
- [Audio Passthrough](#audio-passthrough)
- [Requirements](#requirements)
- [Installation](#installation)
- [Configuration](#configuration)
- [Manual Overrides](#manual-overrides)
- [Troubleshooting](#troubleshooting)
- [File Reference](#file-reference)
- [Shader Credits and Licensing](#shader-credits-and-licensing)
- [License](#license)

---

## Overview

Plex HTPC uses mpv as its video renderer and supports GLSL shader pipelines, custom scaling algorithms, and per-content configuration through Lua scripts. This project provides a Lua script that automatically detects what you're watching and applies the best settings for it.

The problem it solves: without this script, you either apply the same shaders to everything (anime shaders on live-action look terrible, cinema shaders on anime miss the point) or you manually switch profiles with keybinds every time you play something. The profile manager reads Plex's own metadata to make the right choice automatically.

---

## How It Works

```
1. You press play in Plex HTPC / Plex Desktop
2. Plex sets metadata in user-data/plex/playing-media (JSON)
   → library name, file path, resolution, bitrate, codec
3. mpv initializes its renderer
   → GPU name appears in log ("Device Name: NVIDIA GeForce RTX 4090")
4. mpv fires "file-loaded" event
5. Script waits 1 second (for Plex to finish its own setup)
6. Script reads:
   → GPU name → maps to tier (high/mid/low)
   → Library name → anime or cinema?
   → Resolution → which sub-tier? (360p/480p/576p/720p/1080p/4K)
   → Bitrate → clean source or degraded?
   → HDR primaries → HDR passthrough needed?
7. Script applies:
   → Shader chain (Anime4K modes or FSRCNNX cinema chain)
   → Scaling algorithm (ewa_lanczos for anime, spline36 for cinema)
   → Debanding settings (stronger for anime, lighter for cinema/HDR)
8. OSD shows active profile:
   "Anime 576p [3246kbps] Mode A [high] (768x576)"
```

### Why the 1-Second Delay?

From mpv log analysis, Plex HTPC sets its own properties (audio-spdif, audio-exclusive, glsl-shaders, scale, deband) at approximately 10.700 seconds after launch. The `file-loaded` event fires at approximately 11.404 seconds. Our script fires 1 second after `file-loaded` (at ~12.4s) to ensure it always applies *after* Plex finishes its setup, overriding Plex's defaults with our optimized settings.

---

## Profile Decision Tree

The script uses a priority-based decision tree:

**Priority 1: HDR** — If HDR is detected (BT.2020 primaries + PQ or HLG transfer), the HDR profile is applied regardless of whether the content is anime or live-action. Shaders can interfere with HDR tone mapping, so the HDR profile uses no shaders and minimal processing.

**Priority 2: Anime** — If the Plex library name contains "anime" (case-insensitive), the anime profile is applied. The specific Anime4K mode is selected based on resolution and bitrate (see [Bitrate-Aware Mode Selection](#bitrate-aware-mode-selection)).

**Priority 3: Cinema** — Everything else gets the cinema profile with FSRCNNX neural upscaling for sub-4K content, or no shaders for native 4K.

| Content | Profile Applied |
|---|---|
| HDR (any content) | No shaders, light deband, display handles tone mapping |
| Anime 1080p (high bitrate) | Anime4K Mode A+A — double restore, max quality |
| Anime 1080p (low bitrate) | Anime4K Mode A — single restore |
| Anime 720p (high bitrate) | Anime4K Mode B — soft restore |
| Anime 720p (low bitrate) | Anime4K Mode C — denoise + upscale |
| Anime 576p (high bitrate) | Anime4K Mode A — clean Blu-ray, sharp restore |
| Anime 576p (low bitrate) | Anime4K Mode C — denoise before upscale |
| Anime 480p (high bitrate) | Anime4K Mode A — clean DVD |
| Anime 480p (low bitrate) | Anime4K Mode C+A — max cleanup |
| Anime 360p | Mode C or C+A (always needs denoising) |
| Anime 4K | No shaders — already native resolution |
| Cinema (sub-4K) | FSRCNNX + SSimSuperRes + KrigBilateral |
| Cinema 4K | No shaders — upscalers have nothing to do |

---

## Anime Detection

The script detects anime by reading Plex's `user-data/plex/playing-media` JSON property, which is set before every playback. This JSON contains the `librarySectionTitle` field — the name of the Plex library the content belongs to.

**All comparisons are case-insensitive.** If your library is called "Anime TV Shows", "anime movies", "My Anime Collection", or anything containing the word "anime", it matches.

### Detection Priority Chain

1. **`librarySectionTitle`** from Plex metadata — the most reliable method. Plex always sets this.
2. **Actual file path** from Plex metadata (`"file":"/media/Anime TV Shows/..."`) — fallback if library name is missing.
3. **mpv `path` property** — last resort. In Plex HTPC, this is usually a streaming URL (`https://ipaddress...plex.direct`) which rarely contains useful keywords. Included as a safety net.

### Why Not Use the File Path Directly?

Plex HTPC passes a streaming URL to mpv, not the actual file path. The real file path is only available inside the Plex metadata JSON. This is why v1 of this script (which checked mpv's `path` property) failed to detect anime — the streaming URL contains no useful content information.

---

## Bitrate-Aware Mode Selection

The same resolution can look very different depending on source quality. A 576p Blu-ray encode at 3000+ kbps has clean linework that just needs sharp upscaling. A 576p fansub at 800 kbps has compression artifacts, banding, and smearing that need denoising before you upscale — otherwise you're just making the artifacts bigger.

The script reads the bitrate from Plex metadata and uses it to select the appropriate Anime4K mode:

| Resolution | Bitrate Threshold | Above Threshold (Clean) | Below Threshold (Degraded) | Unknown Bitrate |
|---|---|---|---|---|
| **360p** | 800 kbps | Mode C | Mode C+A | Mode C+A |
| **480p** | 1200 kbps | Mode A | Mode C+A | Mode C |
| **576p** | 1500 kbps | Mode A | Mode C | Mode A |
| **720p** | 2500 kbps | Mode B | Mode C | Mode B |
| **1080p** | 4000 kbps | Mode A+A | Mode A | Mode A |
| **4K** | N/A | No shaders | No shaders | No shaders |

### Why These Thresholds?

The thresholds are based on typical encoding quality at each resolution:

- **576p @ 1500 kbps**: A Blu-ray SD encode (like Rurouni Kenshin at 3246 kbps) is well above this. A compressed fansub or old TV rip falls below. The threshold separates "clean source that just needs upscaling" from "degraded source that needs cleaning first."
- **480p @ 1200 kbps**: Good DVD encodes typically run 1500-3000+ kbps. Below 1200 kbps you're looking at heavy compression.
- **720p @ 2500 kbps**: A 720p Blu-ray or good WEB-DL runs 3000-5000+ kbps. Below 2500 suggests a re-encode with visible compression.
- **1080p @ 4000 kbps**: Remuxes run 8000-40000+ kbps. Good WEB-DLs run 4000-8000 kbps. Below 4000 is heavily compressed streaming quality.

All thresholds are configurable in the script's `config.bitrate_thresholds` table.

### Why Mode A for Clean SD Instead of Mode C?

Mode A's Restore shader is trained to recover edges and sharpen detail. It assumes the source is relatively clean and just needs artifact restoration plus edge recovery. On a high-bitrate Blu-ray SD encode, this assumption is correct — the source has clean linework, it's just low resolution.

Mode C's Denoise shader aggressively removes noise and compression artifacts. On a clean source, it's removing "problems" that don't exist and softening fine details in the process. You get a smoother but less detailed result.

This was validated by testing with Rurouni Kenshin (576p Blu-ray @ 3246 kbps) — Mode A produced noticeably sharper results with better preserved line detail compared to Mode C, which softened the image unnecessarily.

---

## GPU Auto-Detection

Set `gpu_tier = "auto"` (the default) and the script reads your GPU model from mpv's renderer initialization log. It captures the "Device Name:" line that mpv outputs when it initializes D3D11 (Windows) or Vulkan, then maps the GPU model to a performance tier.

### GPU Tiers

| Tier | Anime4K Variants | Cinema Shaders | Performance Target |
|---|---|---|---|
| **high** | VL (Very Large) | FSRCNNX_x2_16 + SSimSuperRes + KrigBilateral | 8-15ms per frame at 4K |
| **mid** | M (Medium) | FSRCNNX_x2_8 + SSimDownscaler + KrigBilateral | 8-15ms per frame at 4K |
| **low** | S (Small) | KrigBilateral only | <16ms per frame at 4K |

The low tier also skips double-pass modes (A+A, B+B, C+A) since those GPUs can't handle the extra shader passes within the frame time budget. They fall back to single-pass equivalents.

### Classification by GPU Model

**NVIDIA:**

| Series | Models | Tier |
|---|---|---|
| RTX 50xx | All | High |
| RTX 40xx | All | High |
| RTX 30xx | 3060 and above | High |
| RTX 30xx | 3050 | Mid |
| RTX 20xx | All | Mid |
| GTX 16xx | 1660 Super/Ti | Mid |
| GTX 16xx | 1650, 1660 base | Low |
| GTX 10xx | 1070 and above | Mid |
| GTX 10xx | 1060 and below | Low |
| GTX 9xx and older | All | Low |

**AMD:**

| Series | Models | Tier |
|---|---|---|
| RX 9xxx | All | High |
| RX 7xxx | 7700 XT and above | High |
| RX 7xxx | 7600 | Mid |
| RX 6xxx | 6700 XT and above | High |
| RX 6xxx | 6600–6650 XT | Mid |
| RX 6xxx | 6500/6400 | Low |
| RX 5xxx | 5600 XT and above | Mid |
| RX 5xxx | 5500 and below | Low |
| Vega | 56 and above | Mid |
| RX 500 series | All | Low |

**Intel:**

| GPU | Tier |
|---|---|
| Arc A770/A750 | Mid |
| Arc A580/A380 | Low |
| Integrated (UHD/Iris/HD) | Low |

If your GPU isn't recognized, the script defaults to **mid** and logs a warning. You can always override with `gpu_tier = "high"` / `"mid"` / `"low"`.

---

## Anime4K Modes Explained

Anime4K v4.x provides modular shader components that can be combined into processing pipelines ("modes"). Each mode is optimized for a different class of source degradation:

| Mode | Shaders Used | Best For | What It Does |
|---|---|---|---|
| **A** | Clamp + Restore + Upscale x2 + AutoDownscale + Upscale x2 | Clean sources (Blu-ray, good encodes) | The Restore shader recovers edges and detail lost to compression, then the CNN upscaler doubles the resolution. Best when the source is already clean. |
| **B** | Clamp + Restore_Soft + Upscale x2 + AutoDownscale + Upscale x2 | 720p downsampled content | Restore_Soft is tuned for downsampling artifacts (aliasing, stairstepping) rather than compression artifacts. Used when 720p content was mastered at 1080p and downsampled. |
| **C** | Clamp + Upscale_Denoise x2 + AutoDownscale + Upscale x2 | Compressed/degraded sources | Combines denoising with the upscale pass in a single shader. Removes noise, banding, and compression artifacts before upscaling. More aggressive than Mode A. |
| **A+A** | Clamp + Restore + Upscale x2 + Restore (2nd pass) + AutoDownscale + Upscale x2 | High-bitrate 1080p | Two restore passes for maximum perceptual quality. The second pass catches artifacts the first one missed. Only viable on high-end GPUs. |
| **B+B** | Clamp + Restore_Soft + Upscale x2 + AutoDownscale + Restore_Soft (2nd) + Upscale x2 | High-bitrate 720p | Double soft restore for maximum quality on downsampled content. |
| **C+A** | Clamp + Upscale_Denoise x2 + AutoDownscale + Restore + Upscale x2 | Heavily degraded SD | Denoise first to clean up the source, then restore to recover detail. The most aggressive cleanup pipeline. |

### Clamp_Highlights

Present in every mode. Computes image statistics before the shader chain runs, then clamps highlight values at the end to prevent overshoot and reduce ringing artifacts that the upscaling process can introduce.

### AutoDownscalePre

Present in every mode between the two upscale passes. If the first x2 upscale produces an image larger than the output resolution, this shader downscales it to match, preventing the second upscale pass from doing unnecessary work on oversized frames.

---

## Cinema Profile

For non-anime, non-HDR content (movies, TV shows, documentaries), the cinema profile applies:

- **Scaling:** `spline36` (luma) + `mitchell` (chroma) — natural-looking algorithms optimized for photographic content
- **Debanding:** Standard settings (iterations=2, threshold=35, grain=0)
- **Shaders (sub-4K):** FSRCNNX + SSimSuperRes + KrigBilateral

### Cinema Shader Chain

| Shader | Purpose | Author |
|---|---|---|
| **FSRCNNX** | Neural network luma upscaler. Doubles resolution using a fast super-resolution CNN. The 16-0-4-1 variant is the highest quality; 8-0-4-1 is faster for mid-tier GPUs. | igv |
| **SSimSuperRes** | Perceptual upscaling refinement. Works with the scaling algorithm to sharpen the upscaled image while preventing ringing. An accurate sharpener tuned for super-resolution. | igv |
| **KrigBilateral** | Chroma upscaler. Uses the luma channel as a guide to intelligently upscale the chroma (color) channels. Produces significantly better chroma than the default bilinear interpolation. | Shiandow / igv |

### Why No Cinema Shaders on 4K?

FSRCNNX and SSimSuperRes are *upscalers* — they improve image quality by doubling the resolution. When the source is already 3840x2160 on a 4K display, there's nothing to upscale. The shaders' WHEN conditions check if the output is significantly larger than the input, so they either don't activate or do redundant work. KrigBilateral could still help with 4:2:0 chroma on 4K, but the improvement is marginal.

---

## HDR Profile

HDR content (detected via BT.2020 primaries + PQ or HLG transfer function) gets minimal processing:

- **Scaling:** `spline36` + `mitchell`
- **Debanding:** Light settings (iterations=1, threshold=32) — HDR remuxes are usually clean
- **Shaders:** None — shaders can interfere with the HDR signal path. The display handles tone mapping.

This applies to both anime and live-action HDR content. HDR takes priority over anime detection because preserving the HDR signal is more important than applying Anime4K shaders.

---

## Audio Passthrough

The included `mpv.conf` contains three settings that improve audio bitstream passthrough behavior with AVRs:

```
audio-wait-open=1
audio-buffer=0.4
audio-stream-silence=yes
```

### What These Do

**`audio-wait-open=1`** — Tells mpv to wait up to 1 second for the audio device (WASAPI exclusive mode) to be ready before starting playback. Without this, mpv fires playback immediately and audio can drop out while WASAPI is still negotiating exclusive mode with the AVR through the eARC/ARC chain.

**`audio-buffer=0.4`** — Doubles the default audio buffer from ~0.2s to 0.4s. Gives the audio pipeline more runway — if there's a brief hiccup during the eARC handshake, the buffer absorbs it. The tradeoff is ~200ms of extra audio latency, which is imperceptible for media playback.

**`audio-stream-silence=yes`** — The most impactful setting. When you stop a file, pause, or navigate back to the Plex menu, instead of releasing the WASAPI exclusive session (which kills the eARC link and forces a full renegotiation), mpv keeps the session open and streams inaudible silence. The AVR never sees the audio drop, so the eARC connection stays alive continuously. This is essentially SoundKeeper scoped to Plex only.

### Tradeoff

Since `audio-stream-silence=yes` keeps WASAPI exclusive mode locked, other Windows applications cannot output audio through that device while Plex is open (even during menu browsing). This is the same behavior as running SoundKeeper system-wide.

---

## Requirements

- **Plex HTPC** or **Plex Desktop** for Windows (both use mpv internally)
- **Shader files** — included in the `shaders/` directory of this repo
- A **dedicated GPU** for shader processing (see [GPU Auto-Detection](#gpu-auto-detection) for tier requirements)

### Plex HTPC vs Plex Desktop

Both are supported. Plex Desktop has faster audio switching (nearly instant) but lacks HDR passthrough. Plex HTPC has HDR support but can have slower audio handshaking with AVRs. The profile manager script works identically in both.

| Feature | Plex HTPC | Plex Desktop |
|---|---|---|
| HDR passthrough | Yes | No |
| Audio bitstream | Yes (WASAPI exclusive) | Yes (faster switching) |
| GLSL shaders | Yes | Yes |
| Profile manager | Works | Works |
| Config path | `%LOCALAPPDATA%\Plex HTPC\` | `%LOCALAPPDATA%\Plex\` |

---

## Installation

### 1. Copy files

Navigate to `%LOCALAPPDATA%\Plex HTPC\` (or `%LOCALAPPDATA%\Plex\` for Plex Desktop).

Copy the entire directory structure:

```
Plex HTPC\
├── mpv.conf
├── input.conf
├── scripts\
│   └── plex-profile-manager.lua
└── shaders\
    ├── Anime4K_Clamp_Highlights.glsl
    ├── Anime4K_Restore_CNN_VL.glsl
    ├── Anime4K_Restore_CNN_Soft_VL.glsl
    ├── Anime4K_Restore_CNN_M.glsl
    ├── Anime4K_Restore_CNN_S.glsl
    ├── Anime4K_Restore_CNN_Soft_M.glsl
    ├── Anime4K_Restore_CNN_Soft_S.glsl
    ├── Anime4K_Upscale_CNN_x2_VL.glsl
    ├── Anime4K_Upscale_CNN_x2_M.glsl
    ├── Anime4K_Upscale_CNN_x2_S.glsl
    ├── Anime4K_Upscale_Denoise_CNN_x2_VL.glsl
    ├── Anime4K_Upscale_Denoise_CNN_x2_M.glsl
    ├── Anime4K_Upscale_Denoise_CNN_x2_S.glsl
    ├── Anime4K_AutoDownscalePre_x2.glsl
    ├── Anime4K_AutoDownscalePre_x4.glsl
    ├── FSRCNNX_x2_16-0-4-1.glsl
    ├── FSRCNNX_x2_8-0-4-1.glsl
    ├── SSimSuperRes-mitchell.glsl
    ├── SSimDownscaler.glsl
    ├── KrigBilateral.glsl
    └── (additional shaders: filmgrain, CRT, NVScaler, etc.)
```

### 2. Launch Plex and play something

The script loads automatically. The OSD will show the active profile.

---

## Configuration

Open `plex-profile-manager.lua` and edit the `config` table at the top:

```lua
local config = {
    -- GPU tier: "auto" (recommended), "high", "mid", or "low"
    gpu_tier = "auto",

    -- Plex library names containing anime (case-insensitive)
    anime_libraries = {
        "anime",  -- matches any library with "anime" in the name
    },

    -- Bitrate thresholds (kbps) per resolution tier
    bitrate_thresholds = {
        sd_360p  = 800,
        sd_480p  = 1200,
        sd_576p  = 1500,
        hd_720p  = 2500,
        hd_1080p = 4000,
    },

    -- OSD settings
    show_osd = true,
    osd_duration = 3,
}
```

---

## Manual Overrides

The `input.conf` keybinds work during playback to override auto-selection:

| Key | Shader Chain |
|---|---|
| CTRL+1 | Anime4K Mode A (HQ) |
| CTRL+2 | Anime4K Mode B (HQ) |
| CTRL+3 | Anime4K Mode C (HQ) |
| CTRL+4 | Anime4K Mode A+A (HQ) |
| CTRL+5 | Anime4K Mode B+B (HQ) |
| CTRL+6 | Anime4K Mode C+A (HQ) |
| CTRL+7 | Film Grain only |
| CTRL+8 | Film Grain (Light) |
| CTRL+9 | Film Grain + SSimSuperRes |
| ALT+1-4 | CRT shader variants |
| ALT+5 | FSRCNNX + KrigBilateral |
| ALT+6 | FSRCNNX + SSimSuperRes + KrigBilateral |
| ALT+0 | Animation hybrid (FilmGrain + FSR + Denoise) |
| CTRL+0 | Clear all shaders |

---

## Troubleshooting

### Enable Logging

Uncomment `log-file=~~/mpv-log.txt` in mpv.conf. Then search for `[profile-manager]`:

```
[profile-manager] Detected GPU: NVIDIA GeForce RTX 4090
[profile-manager] GPU auto-detected: 'NVIDIA GeForce RTX 4090' -> tier 'high'
[profile-manager] Plex metadata: library='Anime TV Shows' title='Rurouni Kenshin' res=768x576 bitrate=3246kbps codec=mpeg2video
[profile-manager] Anime detected via library: Anime TV Shows
[profile-manager] Mode selection: 576p @ 3246kbps >= 1500 -> clean, Mode A
[profile-manager] Applied shaders: Anime4K Mode A (6 shaders)
```

### Common Issues

**GPU not detected:** The script captures the GPU name from mpv's renderer init log. If auto-detect fails, set `gpu_tier` manually. Look for "GPU name not detected" in the log.

**Wrong anime mode selected:** Adjust `bitrate_thresholds` in the config. Check the actual bitrate in Plex's media info panel (Get Info → Media).

**Shaders not loading:** Verify `.glsl` files exist in `%LOCALAPPDATA%\Plex HTPC\shaders\`. Press Shift+I then 2 during playback to open mpv's shader profiler.

**No OSD notification:** The script waits 1 second after file-loaded. If your system is slower, increase the timeout in the `mp.add_timeout(1.0, ...)` call.

**Anime not detected:** Check that your Plex library name contains "anime" (case-insensitive). Check the log for `Plex metadata: library='...'` to see what name the script is seeing.

**Audio delayed on first play:** This is normal eARC/ARC handshake behavior (1-3 seconds). The `audio-stream-silence=yes` setting keeps the link alive for subsequent plays.

---

## File Reference

| File | Purpose |
|---|---|
| `scripts/plex-profile-manager.lua` | Main profile manager script — anime detection, GPU auto-detect, mode selection, profile application |
| `mpv.conf` | Baseline mpv configuration — GPU renderer, scaling defaults, dithering, audio passthrough fixes |
| `input.conf` | Manual shader keybinds — CTRL/ALT number keys for Anime4K, CRT, film grain, cinema shaders |
| `shaders/` | GLSL shader files — Anime4K v4.x, FSRCNNX, SSimSuperRes, SSimDownscaler, KrigBilateral, film grain, CRT |

---

## Shader Credits and Licensing

### Anime4K Shaders (MIT License)

Copyright (c) 2019-2021 bloc97. [GitHub](https://github.com/bloc97/Anime4K)

Includes: `Anime4K_Clamp_Highlights`, `Anime4K_Restore_CNN_*`, `Anime4K_Restore_CNN_Soft_*`, `Anime4K_Upscale_CNN_x2_*`, `Anime4K_Upscale_Denoise_CNN_x2_*`, `Anime4K_AutoDownscalePre_*`, `Anime4K_Denoise_Bilateral_Median`

Licensed under the MIT License. Full license text is embedded in each shader file header.

### KrigBilateral (LGPL v3)

Original algorithm by Shiandow, ported to mpv GLSL by igv. [Gist](https://gist.github.com/igv/a015fc885d5c22e6891820ad89555637)

Licensed under the GNU Lesser General Public License v3.0.

### FSRCNNX, SSimSuperRes, SSimDownscaler (igv)

By igv. [FSRCNN-TensorFlow](https://github.com/igv/FSRCNN-TensorFlow) / [Gists](https://gist.github.com/igv)

Published as public gists and GitHub releases. Individual shader file headers contain license information where applicable.

### Film Grain, CRT, and Other Shaders

Sourced from the [LitCastVlog/Plex-GLSL-Shaders](https://github.com/LitCastVlog/Plex-GLSL-Shaders) community shader pack for Plex HTPC.

---

## License

This project (the Lua script, mpv.conf, input.conf, and README) is licensed under the MIT License.

Individual shader files retain their original licenses as noted in their file headers and the [Shader Credits](#shader-credits-and-licensing) section above.
