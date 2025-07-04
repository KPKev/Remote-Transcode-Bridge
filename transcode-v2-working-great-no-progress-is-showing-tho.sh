#!/bin/bash

# ==============================================================================
# SUPER-VERBOSE DEBUGGING
# ==============================================================================
# This block is for extreme debugging. It creates a dedicated debug log
# that captures every command executed and its output.
DEBUG_LOG_FILE="$(dirname "$0")/transcode_debug.log"
echo "--- SCRIPT LAUNCHED: $(date) ---" > "$DEBUG_LOG_FILE"
exec 3>&1 4>&2
trap 'exec 2>&4 1>&3' 0 1 2 3
exec 1>>"$DEBUG_LOG_FILE" 2>&1
set -x # Print all commands to the debug log.
# --- END DEBUGGING BLOCK ---

set -euo pipefail

# ==============================================================================
# Sabnzbd Post-Processing Script for Remote GPU-Accelerated Transcoding
# ==============================================================================
#
# Author: Gemini
# Version: 6.1
#
# V6.1 Changes:
# - Removed initial permission self-diagnostic block, as it was causing issues
#   in some non-interactive environments. Permissions are assumed to be correct.
#
# V6.0 Changes:
# - Complete rewrite of the transcoding logic block to fix execution order.
# - Correctly waits for the main FFMPEG process to finish.
# - Explicitly kills the background progress-reader to prevent script hanging.
# - Improved remote command on the Windows host for better stability.
#
# ==============================================================================
#                              CONFIGURATION
# ==============================================================================

# ===================================================================
# All sensitive and tunable values now live in transcode.conf
# ===================================================================

# ============================================================
# Optional external configuration file (same dir as script)
# ============================================================
CONFIG_FILE="$(dirname "$0")/transcode.conf"
if [[ -f "$CONFIG_FILE" ]]; then
    # shellcheck source=/dev/null
    source "$CONFIG_FILE"
fi

# Defaults for config values if not supplied by transcode.conf
LOG_MAX_LINES="${LOG_MAX_LINES:-1000}"
LOG_KEEP="${LOG_KEEP:-5}"
BITRATE_TARGET="${BITRATE_TARGET:-6M}"
BITRATE_MAX="${BITRATE_MAX:-8M}"
BITRATE_BUFSIZE="${BITRATE_BUFSIZE:-16M}"
RESOLUTION_MAX="${RESOLUTION_MAX:-1920x1080}"
NVENC_PRESET="${NVENC_PRESET:-p4}"

# --- Other optional values (provide sane defaults if not set) ---
SSH_HOST="${SSH_HOST:-}"
SSH_PORT="${SSH_PORT:-22}"
SSH_USER="${SSH_USER:-}"
SSH_KEY="${SSH_KEY:-/config/.ssh/id_rsa}"

SONARR_URL="${SONARR_URL:-}"
SONARR_API_KEY="${SONARR_API_KEY:-}"
RADARR_URL="${RADARR_URL:-}"
RADARR_API_KEY="${RADARR_API_KEY:-}"

PLEX_URL="${PLEX_URL:-}"
PLEX_TOKEN="${PLEX_TOKEN:-}"
PLEX_SECTION_ID="${PLEX_SECTION_ID:-}"
PLEX_SECTION_ID_TV="${PLEX_SECTION_ID_TV:-}"
PLEX_SECTION_ID_MOVIES="${PLEX_SECTION_ID_MOVIES:-}"

# ==============================================================================
#                                SCRIPT LOGIC
# ==============================================================================

# Sabnzbd provides job details via environment variables.
JOB_PATH="$1"
# Parameter $5 is the category
JOB_CATEGORY="$5"
# Default log path: same directory as this script, unless overridden by transcode.conf
SCRIPT_DIR="$(dirname "$0")"
LOG_FILE="${LOG_FILE:-"${SCRIPT_DIR}/transcode_script.log"}"
# Prefer local binaries placed next to this script (ffmpeg, ffprobe, curl, etc.)
export PATH="${SCRIPT_DIR}:$PATH"
mkdir -p "$(dirname "$LOG_FILE")"  # Ensure log directory exists
NEEDS_TRANSCODE=0
NEEDS_NOTIFICATION=0

# Logging function that appends to a dedicated log file and also prints to stdout
log() {
    # Rotate if exceeding max lines
    if [[ -f "$LOG_FILE" && $(wc -l < "$LOG_FILE") -ge "$LOG_MAX_LINES" ]]; then
        local TS
        TS=$(date +'%Y%m%d%H%M%S')
        mv "$LOG_FILE" "${LOG_FILE}.${TS}" 2>/dev/null || true
        # Keep only last N archives
        ls -1t "${LOG_FILE}".* 2>/dev/null | tail -n +$((LOG_KEEP + 1)) | xargs -r rm -f --
    fi
    echo "$(date +'%Y-%m-%d %H:%M:%S') | $1" | tee -a "$LOG_FILE"
}

log "--- SCRIPT START (v6.1) ---"
log "Job Path: $JOB_PATH"
log "Category: $JOB_CATEGORY"

if [[ ! -d "$JOB_PATH" ]]; then
    log "Error: Job path '$JOB_PATH' does not exist or is not a directory."
    log "--- SCRIPT END (FAILURE) ---"
    exit 1
fi

# --- Find Video File and Check Format ---

VIDEO_FILE=$(find "$JOB_PATH" -type f \( -name "*.mkv" -o -name "*.mp4" -o -name "*.avi" -o -name "*.mov" \) -printf '%s %p\n' | sort -rn | head -n 1 | cut -d' ' -f2-)

if [[ -z "$VIDEO_FILE" ]]; then
    log "No video file found in '$JOB_PATH'. Assuming compliant and notifying."
    NEEDS_NOTIFICATION=1
else
    log "Found video file: $VIDEO_FILE"

    VIDEO_CODEC=$(ffprobe -v error -select_streams v:0 -show_entries stream=codec_name -of default=noprint_wrappers=1:nokey=1 "$VIDEO_FILE" 2>/dev/null)
    AUDIO_CODEC=$(ffprobe -v error -select_streams a:0 -show_entries stream=codec_name -of default=noprint_wrappers=1:nokey=1 "$VIDEO_FILE" 2>/dev/null)
    AUDIO_CHANNELS=$(ffprobe -v error -select_streams a:0 -show_entries stream=channels -of default=noprint_wrappers=1:nokey=1 "$VIDEO_FILE" 2>/dev/null)
    CONTAINER=$(basename "$VIDEO_FILE" | rev | cut -d . -f 1 | rev)

    log "Detected format: Container=$CONTAINER, Video=$VIDEO_CODEC, Audio=$AUDIO_CODEC"

    if [[ "$CONTAINER" == "mp4" && "$VIDEO_CODEC" == "h264" && "$AUDIO_CODEC" == "aac" && "$AUDIO_CHANNELS" -eq 2 ]]; then
        log "File is already compliant. No transcoding needed."
        NEEDS_TRANSCODE=0
        NEEDS_NOTIFICATION=1
    else
        log "File requires transcoding."
        NEEDS_TRANSCODE=1
    fi
fi

# --- Helper: Clean-up temp artefacts on exit or error ---
cleanup() {
    local ec=$?
    [[ -n "$PROGRESS_PIPE" && -p "$PROGRESS_PIPE" ]] && rm -f "$PROGRESS_PIPE"
    [[ -f "$TEMP_OUTPUT_FILE" && $ec -ne 0 ]] && rm -f "$TEMP_OUTPUT_FILE"
    exit $ec
}

# Ensure cleanup executes on any termination path
trap cleanup EXIT INT TERM

# --- Perform Transcoding if Needed ---

if [[ "$NEEDS_TRANSCODE" -eq 1 ]]; then
    BASENAME=$(basename "$VIDEO_FILE")
    OUTBASE="${BASENAME%.*}"
    JOB_DIR=$(dirname "$VIDEO_FILE")
    FINAL_OUTPUT_FILE="${JOB_DIR}/${OUTBASE}.mp4"
    TEMP_OUTPUT_FILE="${FINAL_OUTPUT_FILE}.tmp"

    log "Output will be written to: $FINAL_OUTPUT_FILE (via $TEMP_OUTPUT_FILE)"

    # Get video duration to calculate progress percentage
    TOTAL_DURATION_S=$(ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 "$VIDEO_FILE")
    if [[ ! "$TOTAL_DURATION_S" || "$TOTAL_DURATION_S" == "N/A" ]]; then
        log "Warning: Could not get video duration. Cannot calculate progress."
        TOTAL_DURATION_S=1 # Avoid division by zero
    fi

    # Create a named pipe for ffmpeg to send progress to
    PROGRESS_PIPE=$(mktemp -u)
    mkfifo "$PROGRESS_PIPE"

    # --------------------------------------------------------
    # Verify remote GPU host is configured and reachable
    # --------------------------------------------------------
    log "Verifying remote GPU host connectivity..."

    if [[ -z "$SSH_HOST" || -z "$SSH_USER" ]]; then
        log "Error: SSH_HOST or SSH_USER not defined in transcode.conf. Cannot proceed with GPU transcoding."
        log "--- SCRIPT END (FAILURE) ---"
        exit 1
    fi

    if ! ssh -q -o BatchMode=yes -o StrictHostKeyChecking=no -o ConnectTimeout=10 -p "$SSH_PORT" -i "$SSH_KEY" "$SSH_USER@$SSH_HOST" "echo ok" 2>/dev/null; then
        log "Error: Remote GPU host ($SSH_USER@$SSH_HOST) is unreachable. Check network, firewall, and SSH server status."
        log "--- SCRIPT END (FAILURE) ---"
        exit 1
    fi

    log "Remote GPU host is reachable."

    # --- Build Audio Command ---
    AUDIO_PARAMS=""
    if [[ "$AUDIO_CODEC" == "aac" && "$AUDIO_CHANNELS" -eq 2 ]]; then
        log "Audio is AAC stereo. Stream will be copied."
        AUDIO_PARAMS="-c:a copy"
    else
        log "Audio is '$AUDIO_CODEC'. It will be transcoded to AAC."
        AUDIO_PARAMS="-c:a aac -ac 2 -b:a 192k"
    fi

    # Build video parameters for Direct-Play compatibility:
    #   – H.264 High Profile Level 4.0 (8-bit, yuv420p)
    #   – Max resolution 1080p (down-scale if source larger)
    #   – Bitrate VBR-HQ targeting ~6 Mbps, capped at 8 Mbps
    #     (Good balance of quality vs. file size, ensures ≤8 Mbps)
    #   – Use GPU encoder with quality-focused preset (p4)
    SCALE_FILTER="scale=w='if(gt(iw,${RESOLUTION_MAX%x*}),${RESOLUTION_MAX%x*},iw)':h='if(gt(ih,${RESOLUTION_MAX#*x}),${RESOLUTION_MAX#*x},ih)':force_original_aspect_ratio=decrease"

    FFMPEG_CMD_GPU="ffmpeg -hide_banner -v error -y -i - -map 0:v:0 -map 0:a:0 -c:v h264_nvenc -preset ${NVENC_PRESET} -profile:v high -level:v 4.0 -pix_fmt yuv420p -vf ${SCALE_FILTER} -rc:v vbr_hq -b:v ${BITRATE_TARGET} -maxrate:v ${BITRATE_MAX} -bufsize:v ${BITRATE_BUFSIZE} ${AUDIO_PARAMS} -movflags frag_keyframe+empty_moov -f mp4 - -progress pipe:2"

    # --- Start FFMPEG pipeline in the background ---
    log "Streaming to $SSH_HOST for GPU transcoding..."
    log "Executing remote command over SSH: ${FFMPEG_CMD_GPU}"
    
    # Remote GPU encode via SSH
    ssh -q -T -o "ConnectTimeout=15" -o "StrictHostKeyChecking=no" -p "$SSH_PORT" -i "$SSH_KEY" "$SSH_USER@$SSH_HOST" \
        "${FFMPEG_CMD_GPU}" < "$VIDEO_FILE" > "$TEMP_OUTPUT_FILE" 2> "$PROGRESS_PIPE" &
    FFMPEG_PID=$!

    # --- Start Progress Reader in the background ---
    # This subshell reads from the named pipe and prints status for Sabnzbd UI
    (
        LAST_PERCENTAGE=-1
        CURRENT_SPEED="1" 
        ETR_STR="--:--"

        # Set a timeout for the read operation. If no new data comes from ffmpeg
        # for 60 seconds, the loop will terminate. This prevents the script from
        # hanging if ffmpeg dies without closing the pipe.
        while IFS= read -r -t 60 LINE; do
            if [[ "$LINE" == *"out_time_ms"* ]]; then
                TIME_US=$(echo "$LINE" | cut -d= -f2)
                TIME_S=$((TIME_US / 1000000))
                PERCENTAGE=$((TIME_S * 100 / ${TOTAL_DURATION_S%.*}))
                if (( PERCENTAGE > LAST_PERCENTAGE )); then
                    LAST_PERCENTAGE=$PERCENTAGE
                fi
            fi

            if [[ "$LINE" == *"speed"* ]]; then
                CURRENT_SPEED=$(echo "$LINE" | cut -d= -f2 | sed 's/x//' | cut -d. -f1)
            fi

            # Calculate ETR
            if [[ "$CURRENT_SPEED" -gt "0" ]]; then
                REMAINING_S=$(( (${TOTAL_DURATION_S%.*} - TIME_S) / CURRENT_SPEED ))
                ETR_STR=$(printf "%02d:%02d" $((REMAINING_S/60)) $((REMAINING_S%60)) )
            fi
            
            # Print a clean progress line
            printf "\rProgress: %s%% | Speed: %sx | ETA: %s" "$LAST_PERCENTAGE" "$CURRENT_SPEED" "$ETR_STR"

        done < "$PROGRESS_PIPE"

        # After the loop finishes (either by completion or timeout), kill the
        # background FFMPEG process to make sure nothing is left hanging.
        kill $FFMPEG_PID 2>/dev/null || true
        # Also clean up the named pipe.
        rm -f "$PROGRESS_PIPE"

    ) & PROGRESS_PID=$!
    
    # Wait for the main FFMPEG process to finish
    wait $FFMPEG_PID
    FFMPEG_EC=$?

    # Now that FFMPEG is done, we can kill the progress reader subshell
    # as it's no longer needed.
    kill $PROGRESS_PID 2>/dev/null || true

    # --- Check FFMPEG exit code ---
    if [[ $FFMPEG_EC -eq 0 ]]; then
        log "Transcoding completed successfully."
        # Move the temporary output file to the final destination
        mv "$TEMP_OUTPUT_FILE" "$FINAL_OUTPUT_FILE"
        # Delete original file
        rm "$VIDEO_FILE"
        log "Original file removed."
        NEEDS_NOTIFICATION=1 # Transcode done, now we notify
    else
        log "Error: FFMPEG failed with exit code $FFMPEG_EC."
        rm -f "$TEMP_OUTPUT_FILE" # Clean up failed temp file
        log "--- SCRIPT END (FAILURE) ---"
        exit 1
    fi
fi

# ==============================================================================
#                      MEDIA SERVER NOTIFICATIONS
# ==============================================================================
# To be run for both transcoded and compliant files

notify_plex() {
    # Determine the section ID based on category
    local SECTION_ID=""
    case "$JOB_CATEGORY" in
        sonarr|tv|series)
            SECTION_ID="$PLEX_SECTION_ID_TV"
            ;;
        radarr|movies)
            SECTION_ID="$PLEX_SECTION_ID_MOVIES"
            ;;
        *)
            # Fallback for general categories
            SECTION_ID="$PLEX_SECTION_ID"
            ;;
    esac

    if [[ -n "$PLEX_URL" && -n "$PLEX_TOKEN" && -n "$SECTION_ID" ]]; then
        log "Triggering Plex library scan for section: $SECTION_ID"
        # The scan is triggered via a simple GET request.
        curl --connect-timeout 10 --max-time 30 -s -G \
            "${PLEX_URL}/library/sections/${SECTION_ID}/refresh" \
            -H "X-Plex-Token: ${PLEX_TOKEN}" > /dev/null
    fi
}


notify_sonarr() {
    if [[ -n "$SONARR_URL" && -n "$SONARR_API_KEY" ]]; then
        log "Triggering Sonarr scan."
        # Sonarr API: DownloadedEpisodesScan
        curl --connect-timeout 10 --max-time 30 -s -X POST \
            "${SONARR_URL}/api/v3/command" \
            -H "Content-Type: application/json" \
            -H "X-Api-Key: ${SONARR_API_KEY}" \
            -d '{"name": "DownloadedEpisodesScan"}' > /dev/null
    fi
}

notify_radarr() {
    if [[ -n "$RADARR_URL" && -n "$RADARR_API_KEY" ]]; then
        log "Triggering Radarr scan."
        # Radarr API: DownloadedMoviesScan
        curl --connect-timeout 10 --max-time 30 -s -X POST \
            "${RADARR_URL}/api/v3/command" \
            -H "Content-Type: application/json" \
            -H "X-Api-Key: ${RADARR_API_KEY}" \
            -d '{"name": "DownloadedMoviesScan"}' > /dev/null
    fi
}

if [[ "$NEEDS_NOTIFICATION" -eq 1 ]]; then
    log "Notifying media servers..."
    case "$JOB_CATEGORY" in
        sonarr|tv|series)
            notify_sonarr
            ;;
        radarr|movies)
            notify_radarr
            ;;
        *)
            # If category is generic, try to notify all known servers
            log "Generic category '$JOB_CATEGORY'. Notifying all."
            notify_sonarr
            notify_radarr
            ;;
    esac
    notify_plex
fi

log "--- SCRIPT END (SUCCESS) ---"
exit 0 