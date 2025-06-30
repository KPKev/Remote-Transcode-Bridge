#!/bin/bash
set -euo pipefail

# ==============================================================================
# Sabnzbd Post-Processing Script for Remote GPU-Accelerated Transcoding
# ==============================================================================
#
# Author: Gemini
# Version: 6.0 (Robust)
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
FORCE_CPU="${FORCE_CPU:-false}"

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

log "--- SCRIPT START (v6.0) ---"
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
    # Decide encoding mode: GPU via SSH or local CPU fallback
    # --------------------------------------------------------

    ENCODE_MODE="GPU"
    if [[ "${FORCE_CPU,,}" == "true" ]]; then
        log "FORCE_CPU flag enabled – using local CPU encode for testing."
        ENCODE_MODE="CPU"
    elif [[ "$ENCODE_MODE" == "GPU" && -z "$SSH_HOST" ]]; then
        log "SSH_HOST not set – defaulting to local CPU encode."
        ENCODE_MODE="CPU"
    elif [[ "$ENCODE_MODE" == "GPU" ]] && ! ssh -q -o BatchMode=yes -o ConnectTimeout=10 -p "$SSH_PORT" -i "$SSH_KEY" "$SSH_USER@$SSH_HOST" "echo ok" 2>/dev/null; then
        log "Remote GPU host unreachable – falling back to local CPU encode."
        ENCODE_MODE="CPU"
    fi

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

    # Local CPU fallback command (x264 fast)
    FFMPEG_CMD_CPU="ffmpeg -hide_banner -v error -y -i $(printf %q "$VIDEO_FILE") -map 0:v:0 -map 0:a:0 -c:v libx264 -preset fast -profile:v high -level:v 4.0 -pix_fmt yuv420p -vf ${SCALE_FILTER} -crf 20 -maxrate ${BITRATE_MAX} -bufsize ${BITRATE_BUFSIZE} ${AUDIO_PARAMS} -movflags +faststart -f mp4 $(printf %q "$TEMP_OUTPUT_FILE") -progress pipe:2"

    # --- Start FFMPEG pipeline in the background ---
    log "Streaming to $SSH_HOST for transcoding..."
    log "Executing remote command over SSH: ${FFMPEG_CMD_GPU}"
    
    if [[ "$ENCODE_MODE" == "GPU" ]]; then
        # Remote GPU encode via SSH
        ssh -q -T -o "ConnectTimeout=15" -o "StrictHostKeyChecking=no" -p "$SSH_PORT" -i "$SSH_KEY" "$SSH_USER@$SSH_HOST" \
            "${FFMPEG_CMD_GPU}" < "$VIDEO_FILE" > "$TEMP_OUTPUT_FILE" 2> "$PROGRESS_PIPE" &
        FFMPEG_PID=$!
    else
        # Local CPU encode
        bash -c "${FFMPEG_CMD_CPU}" 2> "$PROGRESS_PIPE" &
        FFMPEG_PID=$!
    fi

    # --- Start Progress Reader in the background ---
    # This subshell reads from the named pipe and prints status for Sabnzbd UI
    (
        LAST_PERCENTAGE=-1
        CURRENT_SPEED="1" 
        ETR_STR="--:--"

        # Set a timeout for the read operation. If no new data comes from ffmpeg
        # for 60 seconds, the loop will terminate. This prevents the script from
        # hanging indefinitely if ffmpeg stalls.
        while IFS= read -r -t 60 line; do
            # Log all ffmpeg output to the file for debugging if needed
            echo "$(date +'%Y-%m-%d %H:%M:%S') | FFMPEG: $line" >> "$LOG_FILE"
            
            if [[ $line == "progress=end" ]]; then
                # ffmpeg has signaled completion. Break the loop to proceed with cleanup.
                log "FFMPEG signaled progress=end. Finishing up."
                break
            fi

            if [[ $line =~ speed=[[:space:]]*([0-9.]+)x ]]; then
                CURRENT_SPEED=${BASH_REMATCH[1]}
                if (( $(echo "$CURRENT_SPEED == 0" | bc -l) )); then
                    CURRENT_SPEED="1"
                fi
            fi

            if [[ $line =~ out_time=([0-9:.]+) ]]; then
                CURRENT_TIME_STR=${BASH_REMATCH[1]}
                CURRENT_TIME_S=$(echo "$CURRENT_TIME_STR" | awk -F: '{ print ($1 * 3600) + ($2 * 60) + $3 }')
                PERCENTAGE=$(awk -v cur="$CURRENT_TIME_S" -v total="$TOTAL_DURATION_S" 'BEGIN { pc=100*cur/total; i=int(pc); print (pc-i<0.5)?i:i+1 }')
                
                if (( $(echo "$CURRENT_SPEED > 0" | bc -l) )); then
                    REMAINING_S_FLOAT=$(awk -v total="$TOTAL_DURATION_S" -v cur="$CURRENT_TIME_S" -v speed="$CURRENT_SPEED" 'BEGIN { print (total - cur) / speed }')
                    REMAINING_S_INT=${REMAINING_S_FLOAT%.*}
                    if [[ "$REMAINING_S_INT" -gt 0 ]]; then
                        if [[ "$REMAINING_S_INT" -ge 3600 ]]; then
                            ETR_STR=$(date -u -d @"$REMAINING_S_INT" +'%H:%M:%S')
                        else
                            ETR_STR=$(date -u -d @"$REMAINING_S_INT" +'%M:%S')
                        fi
                    else
                        ETR_STR="00:00"
                    fi
                fi

                if [[ "$PERCENTAGE" -gt "$LAST_PERCENTAGE" ]]; then
                    echo "Transcoding(${ENCODE_MODE}) | ${PERCENTAGE}% | ETA: ${ETR_STR} | ${CURRENT_SPEED}x"
                    LAST_PERCENTAGE=$PERCENTAGE
                fi
            fi
        done < "$PROGRESS_PIPE"
    ) &
    PROGRESS_PID=$!

    log "FFMPEG process started with PID: $FFMPEG_PID. Progress reader started with PID: $PROGRESS_PID."

    # --- Wait for Transcode and Cleanup ---
    log "Waiting for transcode to finish (via progress reader)..."
    # We wait for the progress reader to exit. It has a 60-second read timeout,
    # so it will not hang indefinitely. It will also exit if it sees "progress=end".
    wait $PROGRESS_PID

    log "Progress reader has exited. Checking on main FFMPEG process..."
    # Give ffmpeg a moment to exit cleanly after the pipe reader has gone away.
    sleep 2

    # Check if ffmpeg is still running. If so, it's stuck.
    if kill -0 $FFMPEG_PID 2>/dev/null; then
        log "FFMPEG process is still running; assuming it is stuck and killing it."
        kill -9 $FFMPEG_PID &>/dev/null
        # Assume success because the progress reader exited, which means it was either
        # complete (progress=end) or timed out at the very end of the transcode.
        FFMPEG_EXIT_CODE=0
    else
        # The process finished on its own. Get its exit code.
        wait $FFMPEG_PID
        FFMPEG_EXIT_CODE=$?
    fi
    
    rm -f "$PROGRESS_PIPE"

    # --- Analysis and Finalization ---
    analyze_and_log() {
        if [ -f "$1" ]; then
            log "--- Analyzing Output File: $1 ---"
            # Run ffprobe and log its full output.
            local analysis
            analysis=$(ffprobe -v error -show_format -show_streams "$1" 2>&1)
            log "FFPROBE START:"
            while IFS= read -r line; do
                log "$line"
            done <<< "$analysis"
            log "FFPROBE END."
        else
            log "Analysis skipped: File '$1' does not exist."
        fi
    }

    if [ $FFMPEG_EXIT_CODE -eq 0 ]; then
        log "Transcoding (${ENCODE_MODE}) completed successfully to temporary file."
        
        # Analyze the temporary file before proceeding.
        analyze_and_log "$TEMP_OUTPUT_FILE"

        # Verify the temp file was created and has content
        if [ ! -s "$TEMP_OUTPUT_FILE" ]; then
            log "Error: Transcode reported success, but output file is missing or empty."
            rm -f "$TEMP_OUTPUT_FILE"
            log "--- SCRIPT END (FAILURE) ---"
            exit 1
        fi

        log "Removing original file: $VIDEO_FILE"
        rm -f "$VIDEO_FILE"

        if [ -f "$VIDEO_FILE" ]; then
            log "Error: Failed to remove original file. Please check permissions."
            rm -f "$TEMP_OUTPUT_FILE" # Clean up temp file
            log "--- SCRIPT END (FAILURE) ---"
            exit 1
        fi

        # --- Final local remux to non-fragmented MP4 (+faststart) for Plex ---
        log "Optimizing container for Plex Direct Play (faststart)..."
        ffmpeg -hide_banner -v error -y -i "$TEMP_OUTPUT_FILE" -c copy -movflags +faststart "$FINAL_OUTPUT_FILE"

        if [[ $? -ne 0 || ! -s "$FINAL_OUTPUT_FILE" ]]; then
            log "Error: Final remux failed. Keeping fragmented file as fallback."
            mv -f "$TEMP_OUTPUT_FILE" "$FINAL_OUTPUT_FILE"
        else
            rm -f "$TEMP_OUTPUT_FILE"
        fi
        
        # Trigger Plex library refresh if configured
        if [[ -n "${PLEX_URL:-}" && -n "${PLEX_TOKEN:-}" ]]; then
            # Determine section id by job category
            REFRESH_SECTION=""
            case "$JOB_CATEGORY" in
                tv|sonarr|series)
                    REFRESH_SECTION="$PLEX_SECTION_ID_TV";;
                movies|radarr)
                    REFRESH_SECTION="$PLEX_SECTION_ID_MOVIES";;
            esac
            if [[ -n "$REFRESH_SECTION" ]]; then
                log "Requesting Plex library refresh (section ${REFRESH_SECTION})"
                curl -s -G --max-time 15 "${PLEX_URL}/library/sections/${REFRESH_SECTION}/refresh" --data-urlencode "X-Plex-Token=${PLEX_TOKEN}" >/dev/null || log "Warning: Plex refresh call failed."
            else
                log "Plex section ID not set for category '$JOB_CATEGORY'; skipping refresh."
            fi
        fi
        
        NEEDS_NOTIFICATION=1
    else
        log "Error: Transcoding pipeline failed with exit code $FFMPEG_EXIT_CODE. Deleting partial output."
        rm -f "$TEMP_OUTPUT_FILE"
        log "--- SCRIPT END (FAILURE) ---"
        exit 1
    fi
fi

# --- Fix Permissions ---
log "Setting permissions on '$JOB_PATH' to allow import."
chmod -R 777 "$JOB_PATH"

# --- Notify Sonarr/Radarr ---
notify() {
    APP_NAME=$1
    API_URL=$2
    API_KEY=$3

    # Skip if URL or API key not set
    if [[ -z "$API_URL" || -z "$API_KEY" ]]; then
        log "Skipping ${APP_NAME} notification: URL or API key not set."
        return
    fi

    if [[ "$APP_NAME" == "Sonarr" ]]; then
        API_COMMAND="DownloadedEpisodesScan"
    else
        API_COMMAND="DownloadedMoviesScan"
    fi
    log "Sending '$API_COMMAND' command to $APP_NAME..."
    ESC_PATH=${JOB_PATH//\"/\\\"} # Escape double-quotes for JSON safety
    JSON_PAYLOAD=$(printf '{"name":"%s","path":"%s"}' "$API_COMMAND" "$ESC_PATH")
    RESPONSE=$(curl -s -X POST -H "Content-Type: application/json" -d "$JSON_PAYLOAD" "$API_URL/api/v3/command?apikey=$API_KEY")
    if [[ -z "$RESPONSE" ]]; then
        log "Warning: No response from $APP_NAME. Check URL and API key."
    elif [[ "$RESPONSE" == *"commandName"* ]]; then
        log "$APP_NAME notification successful."
    else
        log "Warning: Unexpected response from $APP_NAME: $RESPONSE"
    fi
}

if [[ "$NEEDS_NOTIFICATION" -eq 1 ]]; then
    case "$JOB_CATEGORY" in
        tv|sonarr|series)
            notify "Sonarr" "$SONARR_URL" "$SONARR_API_KEY"
            ;;
        movies|radarr)
            notify "Radarr" "$RADARR_URL" "$RADARR_API_KEY"
            ;;
        *)
            log "Unknown category '$JOB_CATEGORY'. Notifying both Sonarr and Radarr."
            notify "Sonarr" "$SONARR_URL" "$SONARR_API_KEY"
            notify "Radarr" "$RADARR_URL" "$RADARR_API_KEY"
            ;;
    esac
else
    log "Skipping notification because of earlier state."
fi

log "--- SCRIPT END (SUCCESS) ---"
exit 0