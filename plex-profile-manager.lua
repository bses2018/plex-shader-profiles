--[[
    Plex HTPC Profile Manager
    =========================
    Automatic content-aware profile switching for Plex HTPC's embedded mpv player.

    Detects anime vs live-action via Plex library metadata, then applies
    resolution-aware and bitrate-aware shader chains automatically.

    Features:
    - GPU auto-detection (reads GPU name from mpv's renderer log)
    - Anime detection via Plex library name (case-insensitive)
    - Bitrate-aware Anime4K mode selection per resolution tier
    - Cinema profile with FSRCNNX + SSimSuperRes + KrigBilateral
    - HDR passthrough with minimal processing
    - Three GPU tiers: "low", "mid", "high"

    Installation:
    1. Place this script in: %LOCALAPPDATA%\Plex HTPC\scripts\
    2. Place shaders in:     %LOCALAPPDATA%\Plex HTPC\shaders\
    3. Use the accompanying mpv.conf for baseline settings

    Version: 2.2
    License: MIT
]]--

local mp = require("mp")
local msg = require("mp.msg")
local utils = require("mp.utils")

-------------------------------------------------------------------------------
-- CONFIGURATION
-------------------------------------------------------------------------------

local config = {
    ---------------------------------------------------------------------------
    -- GPU TIER
    -- Set to "auto" to detect from your GPU model, or override manually.
    --   "auto" = detect from mpv's renderer log (recommended)
    --   "high" = VL variants (RTX 3060+, RX 6700 XT+)
    --   "mid"  = M variants  (GTX 1070+, RTX 2060, RX 5600 XT+)
    --   "low"  = S variants  (GTX 1060 and below, RX 580 and below)
    ---------------------------------------------------------------------------
    gpu_tier = "auto",

    ---------------------------------------------------------------------------
    -- ANIME LIBRARY DETECTION
    -- Plex library names containing anime (case-insensitive).
    -- "anime" will match "Anime TV Shows", "My Anime", etc.
    ---------------------------------------------------------------------------
    anime_libraries = {
        "anime",
    },

    -- Fallback: keywords checked against actual file path
    anime_path_keywords = {
        "anime",
    },

    ---------------------------------------------------------------------------
    -- OSD
    ---------------------------------------------------------------------------
    show_osd = true,
    osd_duration = 3,

    ---------------------------------------------------------------------------
    -- BITRATE THRESHOLDS (kbps)
    -- Above = clean source (restore modes), below = degraded (denoise modes)
    ---------------------------------------------------------------------------
    bitrate_thresholds = {
        sd_360p  = 800,
        sd_480p  = 1200,
        sd_576p  = 1500,
        hd_720p  = 2500,
        hd_1080p = 4000,
    },
}

-------------------------------------------------------------------------------
-- GPU AUTO-DETECTION
-- Captures GPU name from mpv's renderer init log messages.
-- Maps known GPU models to performance tiers using pattern matching.
-------------------------------------------------------------------------------

local detected_gpu_name = nil
local gpu_tier_resolved = false

-- Enable verbose log messages to capture GPU info from renderer init
mp.enable_messages("v")

mp.register_event("log-message", function(e)
    -- Look for D3D11 or Vulkan device name lines
    -- D3D11:  "[vo/gpu-next/d3d11] Device Name: NVIDIA GeForce RTX 4090"
    -- Vulkan: "[vo/gpu-next/vulkan] Device Name: ..."
    if detected_gpu_name then return end  -- already found

    if e.text and e.text:find("Device Name:") then
        detected_gpu_name = e.text:match("Device Name:%s*(.+)")
        if detected_gpu_name then
            -- Trim whitespace
            detected_gpu_name = detected_gpu_name:match("^%s*(.-)%s*$")
            msg.info("[profile-manager] Detected GPU: " .. detected_gpu_name)
        end
    end
end)

--- NVIDIA tier classification by model number
local function classify_nvidia(name)
    local n = name:lower()

    -- RTX 50xx series
    if n:find("rtx 50") then return "high" end

    -- RTX 40xx series — all high
    if n:find("rtx 40") then return "high" end

    -- RTX 30xx series
    if n:find("rtx 30") then
        local model = tonumber(n:match("rtx 30(%d%d)"))
        if model and model >= 60 then return "high" end  -- 3060+
        return "mid"  -- 3050
    end

    -- RTX 20xx series — mid
    if n:find("rtx 20") then return "mid" end

    -- GTX 16xx series — mid (1660 Super/Ti are decent)
    if n:find("gtx 16") then
        if n:find("1660") and (n:find("super") or n:find("ti")) then
            return "mid"
        end
        return "low"
    end

    -- GTX 10xx series
    if n:find("gtx 10") then
        local model = tonumber(n:match("gtx 10(%d%d)"))
        if model and model >= 70 then return "mid" end   -- 1070+
        return "low"  -- 1060 and below
    end

    -- GTX 9xx series — low
    if n:find("gtx 9") then return "low" end

    -- Anything older — low
    if n:find("gtx") or n:find("gt ") then return "low" end

    return nil  -- unknown NVIDIA
end

--- AMD tier classification
local function classify_amd(name)
    local n = name:lower()

    -- RX 9xxx series
    if n:find("rx 9") then return "high" end

    -- RX 7xxx series
    if n:find("rx 7") then
        local model = tonumber(n:match("rx 7(%d)%d%d"))
        if model and model >= 7 then return "high" end   -- 7700+
        if model and model >= 6 then return "mid" end    -- 7600
        return "mid"
    end

    -- RX 6xxx series
    if n:find("rx 6") then
        local model = tonumber(n:match("rx 6(%d)%d%d"))
        if model and model >= 7 then return "high" end   -- 6700 XT+
        if model and model >= 6 then return "mid" end    -- 6600+
        return "low"  -- 6500/6400
    end

    -- RX 5xxx series
    if n:find("rx 5") then
        local model = tonumber(n:match("rx 5(%d)%d%d"))
        if model and model >= 6 then return "mid" end    -- 5600+
        return "low"  -- 5500 and below
    end

    -- Vega
    if n:find("vega") then
        local model = tonumber(n:match("vega%s*(%d+)"))
        if model and model >= 56 then return "mid" end
        return "low"
    end

    -- RX 500 series
    if n:find("rx 5%d%d") and not n:find("rx 5%d%d%d") then
        return "low"  -- RX 580/570/560
    end

    return nil  -- unknown AMD
end

--- Intel tier classification
local function classify_intel(name)
    local n = name:lower()

    -- Arc discrete GPUs
    if n:find("arc") then
        if n:find("a7") then return "mid" end        -- A770, A750
        if n:find("a5") then return "low" end        -- A580
        if n:find("a3") then return "low" end        -- A380
        return "low"
    end

    -- Intel integrated (UHD, Iris, HD)
    return "low"
end

--- Main GPU classification function
local function classify_gpu(name)
    if not name then return nil end
    local n = name:lower()

    if n:find("nvidia") or n:find("geforce") or n:find("rtx") or n:find("gtx") then
        return classify_nvidia(name)
    elseif n:find("amd") or n:find("radeon") or n:find("rx ") or n:find("vega") then
        return classify_amd(name)
    elseif n:find("intel") or n:find("arc ") or n:find("uhd") or n:find("iris") then
        return classify_intel(name)
    end

    return nil  -- completely unknown
end

--- Resolve the effective GPU tier (auto-detect or manual override)
local function get_gpu_tier()
    if gpu_tier_resolved then
        return config.gpu_tier
    end

    if config.gpu_tier ~= "auto" then
        gpu_tier_resolved = true
        msg.info("[profile-manager] GPU tier manually set: " .. config.gpu_tier)
        return config.gpu_tier
    end

    -- Auto-detect from captured GPU name
    if detected_gpu_name then
        local tier = classify_gpu(detected_gpu_name)
        if tier then
            config.gpu_tier = tier
            gpu_tier_resolved = true
            msg.info(string.format(
                "[profile-manager] GPU auto-detected: '%s' -> tier '%s'",
                detected_gpu_name, tier
            ))
            return tier
        else
            msg.warn(string.format(
                "[profile-manager] GPU '%s' not in lookup table, defaulting to 'mid'",
                detected_gpu_name
            ))
            config.gpu_tier = "mid"
            gpu_tier_resolved = true
            return "mid"
        end
    end

    -- GPU name not captured yet — default to mid
    msg.warn("[profile-manager] GPU name not detected, defaulting to 'mid'")
    config.gpu_tier = "mid"
    gpu_tier_resolved = true
    return "mid"
end

-------------------------------------------------------------------------------
-- SHADER CHAIN DEFINITIONS
-------------------------------------------------------------------------------

local function S(name)
    return "~~/shaders/" .. name
end

local anime_chains = {
    high = {
        mode_a = {
            S("Anime4K_Clamp_Highlights.glsl"),
            S("Anime4K_Restore_CNN_VL.glsl"),
            S("Anime4K_Upscale_CNN_x2_VL.glsl"),
            S("Anime4K_AutoDownscalePre_x2.glsl"),
            S("Anime4K_AutoDownscalePre_x4.glsl"),
            S("Anime4K_Upscale_CNN_x2_M.glsl"),
        },
        mode_b = {
            S("Anime4K_Clamp_Highlights.glsl"),
            S("Anime4K_Restore_CNN_Soft_VL.glsl"),
            S("Anime4K_Upscale_CNN_x2_VL.glsl"),
            S("Anime4K_AutoDownscalePre_x2.glsl"),
            S("Anime4K_AutoDownscalePre_x4.glsl"),
            S("Anime4K_Upscale_CNN_x2_M.glsl"),
        },
        mode_c = {
            S("Anime4K_Clamp_Highlights.glsl"),
            S("Anime4K_Upscale_Denoise_CNN_x2_VL.glsl"),
            S("Anime4K_AutoDownscalePre_x2.glsl"),
            S("Anime4K_AutoDownscalePre_x4.glsl"),
            S("Anime4K_Upscale_CNN_x2_M.glsl"),
        },
        mode_aa = {
            S("Anime4K_Clamp_Highlights.glsl"),
            S("Anime4K_Restore_CNN_VL.glsl"),
            S("Anime4K_Upscale_CNN_x2_VL.glsl"),
            S("Anime4K_Restore_CNN_M.glsl"),
            S("Anime4K_AutoDownscalePre_x2.glsl"),
            S("Anime4K_AutoDownscalePre_x4.glsl"),
            S("Anime4K_Upscale_CNN_x2_M.glsl"),
        },
        mode_bb = {
            S("Anime4K_Clamp_Highlights.glsl"),
            S("Anime4K_Restore_CNN_Soft_VL.glsl"),
            S("Anime4K_Upscale_CNN_x2_VL.glsl"),
            S("Anime4K_AutoDownscalePre_x2.glsl"),
            S("Anime4K_AutoDownscalePre_x4.glsl"),
            S("Anime4K_Restore_CNN_Soft_M.glsl"),
            S("Anime4K_Upscale_CNN_x2_M.glsl"),
        },
        mode_ca = {
            S("Anime4K_Clamp_Highlights.glsl"),
            S("Anime4K_Upscale_Denoise_CNN_x2_VL.glsl"),
            S("Anime4K_AutoDownscalePre_x2.glsl"),
            S("Anime4K_AutoDownscalePre_x4.glsl"),
            S("Anime4K_Restore_CNN_M.glsl"),
            S("Anime4K_Upscale_CNN_x2_M.glsl"),
        },
    },
    mid = {
        mode_a = {
            S("Anime4K_Clamp_Highlights.glsl"),
            S("Anime4K_Restore_CNN_M.glsl"),
            S("Anime4K_Upscale_CNN_x2_M.glsl"),
            S("Anime4K_AutoDownscalePre_x2.glsl"),
            S("Anime4K_AutoDownscalePre_x4.glsl"),
            S("Anime4K_Upscale_CNN_x2_S.glsl"),
        },
        mode_b = {
            S("Anime4K_Clamp_Highlights.glsl"),
            S("Anime4K_Restore_CNN_Soft_M.glsl"),
            S("Anime4K_Upscale_CNN_x2_M.glsl"),
            S("Anime4K_AutoDownscalePre_x2.glsl"),
            S("Anime4K_AutoDownscalePre_x4.glsl"),
            S("Anime4K_Upscale_CNN_x2_S.glsl"),
        },
        mode_c = {
            S("Anime4K_Clamp_Highlights.glsl"),
            S("Anime4K_Upscale_Denoise_CNN_x2_M.glsl"),
            S("Anime4K_AutoDownscalePre_x2.glsl"),
            S("Anime4K_AutoDownscalePre_x4.glsl"),
            S("Anime4K_Upscale_CNN_x2_S.glsl"),
        },
        mode_aa = {
            S("Anime4K_Clamp_Highlights.glsl"),
            S("Anime4K_Restore_CNN_M.glsl"),
            S("Anime4K_Upscale_CNN_x2_M.glsl"),
            S("Anime4K_Restore_CNN_S.glsl"),
            S("Anime4K_AutoDownscalePre_x2.glsl"),
            S("Anime4K_AutoDownscalePre_x4.glsl"),
            S("Anime4K_Upscale_CNN_x2_S.glsl"),
        },
        mode_bb = {
            S("Anime4K_Clamp_Highlights.glsl"),
            S("Anime4K_Restore_CNN_Soft_M.glsl"),
            S("Anime4K_Upscale_CNN_x2_M.glsl"),
            S("Anime4K_AutoDownscalePre_x2.glsl"),
            S("Anime4K_AutoDownscalePre_x4.glsl"),
            S("Anime4K_Restore_CNN_Soft_S.glsl"),
            S("Anime4K_Upscale_CNN_x2_S.glsl"),
        },
        mode_ca = {
            S("Anime4K_Clamp_Highlights.glsl"),
            S("Anime4K_Upscale_Denoise_CNN_x2_M.glsl"),
            S("Anime4K_AutoDownscalePre_x2.glsl"),
            S("Anime4K_AutoDownscalePre_x4.glsl"),
            S("Anime4K_Restore_CNN_S.glsl"),
            S("Anime4K_Upscale_CNN_x2_S.glsl"),
        },
    },
    low = {
        mode_a = {
            S("Anime4K_Clamp_Highlights.glsl"),
            S("Anime4K_Restore_CNN_S.glsl"),
            S("Anime4K_Upscale_CNN_x2_S.glsl"),
            S("Anime4K_AutoDownscalePre_x2.glsl"),
            S("Anime4K_AutoDownscalePre_x4.glsl"),
            S("Anime4K_Upscale_CNN_x2_S.glsl"),
        },
        mode_b = {
            S("Anime4K_Clamp_Highlights.glsl"),
            S("Anime4K_Restore_CNN_Soft_S.glsl"),
            S("Anime4K_Upscale_CNN_x2_S.glsl"),
            S("Anime4K_AutoDownscalePre_x2.glsl"),
            S("Anime4K_AutoDownscalePre_x4.glsl"),
            S("Anime4K_Upscale_CNN_x2_S.glsl"),
        },
        mode_c = {
            S("Anime4K_Clamp_Highlights.glsl"),
            S("Anime4K_Upscale_Denoise_CNN_x2_S.glsl"),
            S("Anime4K_AutoDownscalePre_x2.glsl"),
            S("Anime4K_AutoDownscalePre_x4.glsl"),
            S("Anime4K_Upscale_CNN_x2_S.glsl"),
        },
        -- Low tier: no double-pass modes — fall back to single
        mode_aa = nil,
        mode_bb = nil,
        mode_ca = nil,
    },
}

local cinema_chains = {
    high = {
        S("FSRCNNX_x2_16-0-4-1.glsl"),
        S("SSimSuperRes-mitchell.glsl"),
        S("KrigBilateral.glsl"),
    },
    mid = {
        S("FSRCNNX_x2_8-0-4-1.glsl"),
        S("SSimDownscaler.glsl"),
        S("KrigBilateral.glsl"),
    },
    low = {
        S("KrigBilateral.glsl"),
    },
}

-------------------------------------------------------------------------------
-- STATE
-------------------------------------------------------------------------------

local current_profile = "none"
local current_mode = "none"
local profile_applied = false

-------------------------------------------------------------------------------
-- UTILITY
-------------------------------------------------------------------------------

local function osd(text)
    if config.show_osd then
        mp.osd_message(text, config.osd_duration)
    end
end

local function log(text)
    msg.info("[profile-manager] " .. text)
end

-------------------------------------------------------------------------------
-- PLEX METADATA PARSING
-------------------------------------------------------------------------------

local function get_plex_metadata()
    local raw = mp.get_property("user-data/plex/playing-media", "")
    if not raw or raw == "" then
        log("No Plex metadata available")
        return nil
    end

    local meta, err = utils.parse_json(raw)
    if not meta then
        log("Failed to parse Plex metadata JSON: " .. tostring(err))
        return nil
    end

    local result = {}

    local decision = meta.decision or {}
    local item = decision.metadataItem or {}
    result.library = item.librarySectionTitle or ""
    result.title = item.grandparentTitle or item.title or ""
    result.type = item.type or ""

    result.file_path = ""
    result.bitrate = 0
    result.meta_height = 0
    result.meta_width = 0
    result.video_codec = ""

    local mediaItems = item.mediaItems
    if mediaItems and #mediaItems > 0 then
        local mi = mediaItems[1]
        local parts = mi.parts
        if parts and #parts > 0 then
            result.file_path = parts[1].file or ""
        end
        result.meta_height = mi.height or 0
        result.meta_width = mi.width or 0
        result.bitrate = mi.bitrate or 0
        result.video_codec = mi.videoCodec or ""
    end

    log(string.format(
        "Plex metadata: library='%s' title='%s' res=%dx%d bitrate=%dkbps codec=%s",
        result.library, result.title,
        result.meta_width, result.meta_height,
        result.bitrate, result.video_codec
    ))

    return result
end

-------------------------------------------------------------------------------
-- DETECTION
-------------------------------------------------------------------------------

local function detect_anime(plex_meta)
    if plex_meta and plex_meta.library ~= "" then
        local lib_lower = plex_meta.library:lower()
        for _, name in ipairs(config.anime_libraries) do
            if lib_lower:find(name:lower(), 1, true) then
                log("Anime detected via library: " .. plex_meta.library)
                return true
            end
        end
    end

    if plex_meta and plex_meta.file_path ~= "" then
        local path_lower = plex_meta.file_path:lower()
        for _, kw in ipairs(config.anime_path_keywords) do
            if path_lower:find(kw:lower(), 1, true) then
                log("Anime detected via file path: " .. plex_meta.file_path)
                return true
            end
        end
    end

    local mpv_path = mp.get_property("path", "")
    if mpv_path ~= "" then
        local path_lower = mpv_path:lower()
        for _, kw in ipairs(config.anime_path_keywords) do
            if path_lower:find(kw:lower(), 1, true) then
                log("Anime detected via mpv path")
                return true
            end
        end
    end

    return false
end

local function detect_hdr()
    local prim = mp.get_property("video-params/primaries", "")
    local trc = mp.get_property("video-params/gamma", "")
    if prim == "bt.2020" and (trc == "pq" or trc == "hlg") then
        return true, trc
    end
    return false, "sdr"
end

local function get_resolution_info(plex_meta)
    local h = mp.get_property_number("video-params/h", 0)
    local w = mp.get_property_number("video-params/w", 0)

    if h == 0 and plex_meta then
        h = plex_meta.meta_height or 0
        w = plex_meta.meta_width or 0
        if h > 0 then
            log("Using Plex metadata resolution: " .. w .. "x" .. h)
        end
    end

    if h == 0 then return "unknown", "unknown", 0, 0 end

    if h <= 400 then     return "sd",  "360p",  w, h
    elseif h <= 500 then return "sd",  "480p",  w, h
    elseif h <= 576 then return "sd",  "576p",  w, h
    elseif h <= 810 then return "hd",  "720p",  w, h
    elseif h <= 1200 then return "hd", "1080p", w, h
    else                 return "uhd", "4k",    w, h
    end
end

local function get_bitrate(plex_meta)
    if plex_meta and plex_meta.bitrate > 0 then
        return plex_meta.bitrate
    end
    local vbr = mp.get_property_number("video-bitrate", 0)
    if vbr > 0 then return math.floor(vbr / 1000) end
    return 0
end

-------------------------------------------------------------------------------
-- ANIME MODE SELECTION ENGINE
-------------------------------------------------------------------------------

local function select_anime_mode(sub_tier, bitrate)
    local tier = get_gpu_tier()
    local chains = anime_chains[tier]
    if not chains then
        log("ERROR: Unknown gpu_tier '" .. tier .. "', falling back to mid")
        chains = anime_chains.mid
    end

    local thresholds = config.bitrate_thresholds
    local mode, chain, reason

    if sub_tier == "4k" then
        return nil, "4K native", "No upscale needed"

    elseif sub_tier == "1080p" then
        if bitrate == 0 then
            mode = "A"; chain = chains.mode_a
            reason = "1080p, bitrate unknown -> default Mode A"
        elseif bitrate >= thresholds.hd_1080p then
            mode = "A+A"; chain = chains.mode_aa or chains.mode_a
            if not chains.mode_aa then mode = "A" end
            reason = string.format("1080p @ %dkbps >= %d -> clean, Mode %s",
                bitrate, thresholds.hd_1080p, mode)
        else
            mode = "A"; chain = chains.mode_a
            reason = string.format("1080p @ %dkbps < %d -> compressed, Mode A",
                bitrate, thresholds.hd_1080p)
        end

    elseif sub_tier == "720p" then
        if bitrate == 0 then
            mode = "B"; chain = chains.mode_b
            reason = "720p, bitrate unknown -> default Mode B"
        elseif bitrate >= thresholds.hd_720p then
            mode = "B"; chain = chains.mode_b
            reason = string.format("720p @ %dkbps >= %d -> clean, Mode B",
                bitrate, thresholds.hd_720p)
        else
            mode = "C"; chain = chains.mode_c
            reason = string.format("720p @ %dkbps < %d -> compressed, Mode C",
                bitrate, thresholds.hd_720p)
        end

    elseif sub_tier == "576p" then
        if bitrate == 0 then
            mode = "A"; chain = chains.mode_a
            reason = "576p, bitrate unknown -> default Mode A"
        elseif bitrate >= thresholds.sd_576p then
            mode = "A"; chain = chains.mode_a
            reason = string.format("576p @ %dkbps >= %d -> clean, Mode A",
                bitrate, thresholds.sd_576p)
        else
            mode = "C"; chain = chains.mode_c
            reason = string.format("576p @ %dkbps < %d -> compressed, Mode C",
                bitrate, thresholds.sd_576p)
        end

    elseif sub_tier == "480p" then
        if bitrate == 0 then
            mode = "C"; chain = chains.mode_c
            reason = "480p, bitrate unknown -> default Mode C"
        elseif bitrate >= thresholds.sd_480p then
            mode = "A"; chain = chains.mode_a
            reason = string.format("480p @ %dkbps >= %d -> clean, Mode A",
                bitrate, thresholds.sd_480p)
        else
            mode = "C+A"; chain = chains.mode_ca or chains.mode_c
            if not chains.mode_ca then mode = "C" end
            reason = string.format("480p @ %dkbps < %d -> degraded, Mode %s",
                bitrate, thresholds.sd_480p, mode)
        end

    elseif sub_tier == "360p" then
        if bitrate == 0 then
            mode = "C+A"; chain = chains.mode_ca or chains.mode_c
            if not chains.mode_ca then mode = "C" end
            reason = "360p, bitrate unknown -> default Mode " .. mode
        elseif bitrate >= thresholds.sd_360p then
            mode = "C"; chain = chains.mode_c
            reason = string.format("360p @ %dkbps >= %d -> decent, Mode C",
                bitrate, thresholds.sd_360p)
        else
            mode = "C+A"; chain = chains.mode_ca or chains.mode_c
            if not chains.mode_ca then mode = "C" end
            reason = string.format("360p @ %dkbps < %d -> degraded, Mode %s",
                bitrate, thresholds.sd_360p, mode)
        end

    else
        mode = "A"; chain = chains.mode_a
        reason = "Unknown sub-tier -> fallback Mode A"
    end

    return chain, mode, reason
end

-------------------------------------------------------------------------------
-- PROFILE APPLICATION
-------------------------------------------------------------------------------

local function apply_shaders(chain, label)
    local shader_str = table.concat(chain, ";")
    mp.set_property("glsl-shaders", shader_str)
    current_mode = label
    log("Applied shaders: " .. label .. " (" .. #chain .. " shaders)")
end

local function clear_shaders()
    mp.set_property("glsl-shaders", "")
    current_mode = "none"
    log("Cleared all shaders")
end

local function apply_anime_profile(sub_tier, w, h, bitrate)
    mp.set_property("scale", "ewa_lanczos")
    mp.set_property("cscale", "ewa_lanczos")
    mp.set_property("scale-antiring", "0.7")
    mp.set_property("cscale-antiring", "0.7")

    mp.set_property("deband", "yes")
    mp.set_property("deband-iterations", "2")
    mp.set_property("deband-threshold", "45")
    mp.set_property("deband-range", "16")
    mp.set_property("deband-grain", "20")

    local chain, mode, reason = select_anime_mode(sub_tier, bitrate)
    log("Mode selection: " .. reason)

    if chain == nil then
        clear_shaders()
        current_profile = "Anime 4K"
        osd("Anime 4K (native)")
    else
        apply_shaders(chain, "Anime4K Mode " .. mode)
        current_profile = "Anime " .. sub_tier
        local tier = get_gpu_tier()
        local br_str = bitrate > 0 and (bitrate .. "kbps") or "?kbps"
        osd(string.format("Anime %s [%s] Mode %s [%s] (%dx%d)",
            sub_tier, br_str, mode, tier, w, h))
    end

    log("Applied anime profile: " .. current_profile)
end

local function apply_cinema_profile(sub_tier, w, h)
    mp.set_property("scale", "spline36")
    mp.set_property("cscale", "mitchell")
    mp.set_property("scale-antiring", "0.7")
    mp.set_property("cscale-antiring", "0.7")

    mp.set_property("deband", "yes")
    mp.set_property("deband-iterations", "2")
    mp.set_property("deband-threshold", "35")
    mp.set_property("deband-range", "16")
    mp.set_property("deband-grain", "0")

    if sub_tier == "4k" then
        clear_shaders()
        current_profile = "Cinema 4K"
        osd("Cinema 4K (native)")
    else
        local tier = get_gpu_tier()
        local chain = cinema_chains[tier] or cinema_chains.mid
        apply_shaders(chain, "Cinema (" .. tier .. ")")
        current_profile = "Cinema"
        osd("Cinema [" .. tier .. "] (" .. w .. "x" .. h .. ")")
    end

    log("Applied cinema profile: " .. current_profile)
end

local function apply_hdr_profile(hdr_type, sub_tier, w, h, is_anime_content)
    mp.set_property("scale", "spline36")
    mp.set_property("cscale", "mitchell")
    mp.set_property("scale-antiring", "0.7")
    mp.set_property("cscale-antiring", "0.7")

    mp.set_property("deband", "yes")
    mp.set_property("deband-iterations", "1")
    mp.set_property("deband-threshold", "32")
    mp.set_property("deband-range", "16")
    mp.set_property("deband-grain", "0")

    clear_shaders()

    local type_label = is_anime_content and "HDR Anime" or "HDR"
    current_profile = type_label .. " " .. hdr_type:upper()
    osd(current_profile .. " (" .. w .. "x" .. h .. ")")
    log("Applied HDR profile: " .. current_profile)
end

-------------------------------------------------------------------------------
-- MAIN DECISION ENGINE
-------------------------------------------------------------------------------

local function apply_profile()
    if profile_applied then
        log("Profile already applied for this file, skipping")
        return
    end
    profile_applied = true

    local plex_meta = get_plex_metadata()
    local hdr, hdr_type = detect_hdr()
    local tier, sub_tier, w, h = get_resolution_info(plex_meta)
    local bitrate = get_bitrate(plex_meta)
    local anime = detect_anime(plex_meta)
    local gpu = get_gpu_tier()

    log(string.format(
        "Decision: gpu=%s | sub=%s (%dx%d) | bitrate=%dkbps | hdr=%s (%s) | anime=%s | lib='%s'",
        gpu, sub_tier, w, h, bitrate,
        tostring(hdr), hdr_type,
        tostring(anime),
        plex_meta and plex_meta.library or "N/A"
    ))

    if hdr then
        apply_hdr_profile(hdr_type, sub_tier, w, h, anime)
        return
    end

    if anime then
        apply_anime_profile(sub_tier, w, h, bitrate)
        return
    end

    apply_cinema_profile(sub_tier, w, h)
end

-------------------------------------------------------------------------------
-- EVENT HOOKS
-------------------------------------------------------------------------------

mp.register_event("file-loaded", function()
    log("File loaded event fired")
    profile_applied = false

    mp.add_timeout(1.0, function()
        log("Running profile detection...")
        apply_profile()
    end)
end)

mp.register_event("end-file", function()
    clear_shaders()
    current_profile = "none"
    current_mode = "none"
    profile_applied = false
    log("Playback ended, reset to baseline")
end)

-------------------------------------------------------------------------------
-- STARTUP
-------------------------------------------------------------------------------

log("Plex HTPC Profile Manager v2.2 loaded")
if config.gpu_tier == "auto" then
    log("GPU tier: auto (will detect on first playback)")
else
    log("GPU tier: " .. config.gpu_tier .. " (manual)")
end
log("Anime libraries: " .. table.concat(config.anime_libraries, ", "))
