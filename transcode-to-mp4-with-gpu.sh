#!/bin/sh
set -eu

# ==============================================================================
# Sabnzbd Post-Processing Script: Transcode to MP4 (GPU or CPU)
# ==============================================================================
#
# Author: Gemini
# Version: 3.0 (Unified)
#
# This script intelligently transcodes video files to a web-optimized MP4
# format (H.264/AAC) for maximum Direct Play compatibility.
#
# It prioritizes using a remote NVIDIA GPU, but falls back to local CPU
# transcoding (with optional Intel QSV hardware acceleration) if the GPU
# host is unavailable or if CPU transcoding is forced.
#
# This is a single, unified script with no external script dependencies.
# ==============================================================================

# --- Tell the system where to find binaries and libraries ---
export PATH="$(dirname "$0"):$PATH"
export LD_LIBRARY_PATH="$(dirname "$0"):${LD_LIBRARY_PATH:-}"

# --- Load Configuration ---
CONFIG_FILE="$(dirname "$0")/transcode.conf"
if [ -f "$CONFIG_FILE" ]; then
    # shellcheck source=/dev/null
    . "$CONFIG_FILE"
fi

# --- Set Defaults for Config Values ---
FORCE_CPU_TRANSCODE="${FORCE_CPU_TRANSCODE:-false}"
ENABLE_CPU_HW_ACCEL="${ENABLE_CPU_HW_ACCEL:-false}"
LOG_KEEP="${LOG_KEEP:-10}"
BITRATE_TARGET="${BITRATE_TARGET:-6M}"
BITRATE_MAX="${BITRATE_MAX:-8M}"
BITRATE_BUFSIZE="${BITRATE_BUFSIZE:-16M}"
RESOLUTION_MAX="${RESOLUTION_MAX:-1920x1080}"
NVENC_PRESET="${NVENC_PRESET:-p4}"
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
PLEX_SECTION_ID_TV="${PLEX_SECTION_ID_TV:-}"
PLEX_SECTION_ID_MOVIES="${PLEX_SECTION_ID_MOVIES:-}"
PLEX_SECTION_ID="${PLEX_SECTION_ID:-}"

# --- Sabnzbd Environment Variables ---
JOB_PATH="$1"
JOB_NAME="$3"
JOB_CATEGORY="${5:-}"

# --- Script Setup ---
SCRIPT_DIR="$(dirname "$0")"
# --- Logging Setup ---
TIMESTAMP=$(date +"%Y-%m-%d_%H-%M-%S")
LOG_DIR="$(dirname "$0")/logs"
# Sanitize job name, but truncate for safety in log files
JOB_NAME_SAFE=$(echo "$JOB_NAME" | sed 's/[^a-zA-Z0-9._-]/_/g' | cut -c 1-50)
# LOG_FILE_BASE should NOT include the directory path.
LOG_FILE_BASE="${TIMESTAMP}_${JOB_NAME_SAFE}"
MAIN_LOG_FILE="${LOG_DIR}/${LOG_FILE_BASE}_main.log"
NEEDS_TRANSCODE=0
NEEDS_NOTIFICATION=0

# --- Logging ---
mkdir -p "$LOG_DIR"
log() {
    echo "$(date +'%Y-%m-%d %H:%M:%S') | $1" | tee -a "$MAIN_LOG_FILE"
}

# --- Log Rotation ---
rotate_logs() {
    (
        find "$LOG_DIR" -maxdepth 1 -name "*.log" -type f -printf '%T@ %p\n' 2>/dev/null |
            sort -n |
            head -n "-$LOG_KEEP" |
            cut -d' ' -f2- |
            xargs -r rm -f
    ) &
}

# --- Cleanup on Exit ---
cleanup() {
    local ec=$?
    # Make sure the progress pipe is removed
    if [ -n "${PROGRESS_PIPE:-}" ] && [ -p "$PROGRESS_PIPE" ]; then
        rm -f "$PROGRESS_PIPE"
    fi

    # Log script end status
    if [ $ec -ne 0 ]; then
        log "--- SCRIPT END (FAILURE) ---"
    else
        log "--- SCRIPT END (SUCCESS) ---"
    fi
}
trap cleanup EXIT INT TERM

# --- Robust Error Trapping ---
# This function is called by the trap on any command that returns a non-zero exit code.
# It explicitly logs the line number and exit code to the main log file.
handle_error() {
    local exit_code=$1
    local line_no=$2
    local log_file_path=${MAIN_LOG_FILE:-"/dev/null"} # Default to /dev/null if not set

    # Use echo directly to the log file for maximum reliability in an error state.
    echo "$(date +"%Y-%m-%d %H:%M:%S") | --- SCRIPT ERROR ---" >> "$log_file_path"
    echo "$(date +"%Y-%m-%d %H:%M:%S") | Error on or near line ${line_no}; exiting with status ${exit_code}." >> "$log_file_path"

    # Manual cleanup, as the EXIT trap is now only for this handler.
    if [ -n "$PROGRESS_PIPE" ] && [ -p "$PROGRESS_PIPE" ]; then
        rm -f "$PROGRESS_PIPE"
    fi
    if [ -n "$TEMP_OUTPUT_FILE" ] && [ -f "$TEMP_OUTPUT_FILE" ]; then
        rm -f "$TEMP_OUTPUT_FILE"
    fi

    echo "$(date +"%Y-%m-%d %H:%M:%S") | --- SCRIPT END (FAILURE) ---" >> "$log_file_path"
    exit "$exit_code"
}

# Unset any previous traps and set our new reliable one.
trap - EXIT INT TERM ERR
trap 'handle_error $? $LINENO' ERR

# ==============================================================================
# --- Main Logic ---
# ==============================================================================

rotate_logs

log "--- SCRIPT START (v3.0 Unified) ---"
log "Job Name: ${JOB_NAME}"
log "Job Path: ${JOB_PATH}"
log "Category: ${JOB_CATEGORY}"

# --- Find Largest Video File ---
VIDEO_FILE=$(find "$JOB_PATH" -type f \( -name "*.mkv" -o -name "*.mp4" -o -name "*.avi" -o -name "*.mov" \) -printf '%s %p\n' | sort -rn | head -n 1 | cut -d' ' -f2-)

if [ -z "$VIDEO_FILE" ]; then
    log "No video file found in '$JOB_PATH'. Nothing to do."
    exit 0
fi

log "Found video file: $VIDEO_FILE"

# --- Check if Transcoding is Needed ---
VIDEO_CODEC=$(ffprobe -v error -select_streams v:0 -show_entries stream=codec_name -of default=noprint_wrappers=1:nokey=1 "$VIDEO_FILE" 2>/dev/null)
AUDIO_CODEC=$(ffprobe -v error -select_streams a:0 -show_entries stream=codec_name -of default=noprint_wrappers=1:nokey=1 "$VIDEO_FILE" 2>/dev/null)
AUDIO_CHANNELS=$(ffprobe -v error -select_streams a:0 -show_entries stream=channels -of default=noprint_wrappers=1:nokey=1 "$VIDEO_FILE" 2>/dev/null)
CONTAINER=$(basename "$VIDEO_FILE" | rev | cut -d . -f 1 | rev)

log "Detected format: Container=$CONTAINER, Video=$VIDEO_CODEC, Audio=$AUDIO_CODEC"

if [ "$CONTAINER" = "mp4" ] && [ "$VIDEO_CODEC" = "h264" ] && [ "$AUDIO_CODEC" = "aac" ] && [ "$AUDIO_CHANNELS" -eq 2 ]; then
    log "File is already compliant. No transcoding needed."
    NEEDS_TRANSCODE=0
    NEEDS_NOTIFICATION=1
else
    log "File requires transcoding."
    NEEDS_TRANSCODE=1
fi

# --- Perform Transcoding ---
if [ "$NEEDS_TRANSCODE" -eq 1 ]; then
    log "File requires transcoding."
    
    # Define file paths. The temporary file should be in the same directory as the final output.
    JOB_DIR=$(dirname "$VIDEO_FILE")
    OUTBASE=$(basename "${VIDEO_FILE%.*}")
    FINAL_OUTPUT_FILE="${JOB_DIR}/${OUTBASE}.mp4"
    TEMP_OUTPUT_FILE="${JOB_DIR}/${OUTBASE}.tmp.mp4"
    PROGRESS_PIPE="${LOG_DIR}/ffmpeg_progress_${RANDOM}.pipe"
    
    log "Attempting to create progress pipe: $PROGRESS_PIPE"
    mkfifo "$PROGRESS_PIPE"

    # --- Check for Force CPU flag ---
    USE_GPU=true
    if [ "$FORCE_CPU_TRANSCODE" = "true" ]; then
        log "FORCE_CPU_TRANSCODE is true. Skipping GPU host check."
        USE_GPU=false
    elif [ -z "$SSH_HOST" ] || [ -z "$SSH_USER" ]; then
        log "SSH_HOST or SSH_USER not defined in config. Attempting CPU fallback..."
        USE_GPU=false
    elif ! ssh -q -o BatchMode=yes -o StrictHostKeyChecking=no -o ConnectTimeout=10 -p "$SSH_PORT" -i "$SSH_KEY" "$SSH_USER@$SSH_HOST" "echo ok" 2>/dev/null; then
        log "GPU host $SSH_HOST is not reachable. Attempting CPU fallback..."
        USE_GPU=false
    fi

    # --- Get Video Duration ---
    TOTAL_DURATION_S=$(ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 "$VIDEO_FILE" | cut -d. -f1)
    if [ -z "$TOTAL_DURATION_S" ]; then
        log "Warning: Could not get video duration. Cannot calculate progress."
        TOTAL_DURATION_S=1
    fi

    # --- Build Audio Command ---
    if [ "$AUDIO_CODEC" = "aac" ] && [ "$AUDIO_CHANNELS" -eq 2 ]; then
        log "Audio is AAC stereo. Stream will be copied."
        AUDIO_PARAMS="-c:a copy"
    else
        log "Audio is '$AUDIO_CODEC'. It will be transcoded to AAC."
        AUDIO_PARAMS="-c:a aac -ac 2 -b:a 192k"
    fi

    FFMPEG_CMD=""
    ENCODER_LABEL=""

    if [ "$USE_GPU" = true ]; then
        # --- GPU TRANSCODING LOGIC ---
        ENCODER_LABEL="GPU"
        log "Starting GPU transcoding..."
        SCALE_FILTER="scale=w='if(gt(iw,${RESOLUTION_MAX%x*}),${RESOLUTION_MAX%x*},iw)':h='if(gt(ih,${RESOLUTION_MAX#*x}),${RESOLUTION_MAX#*x},ih)':force_original_aspect_ratio=decrease"
        
        # The output filename for ssh is just '-', representing stdout, so this is fine.
        FFMPEG_CMD_GPU="ffmpeg -hide_banner -v error -y -i - -map 0:v:0 -map 0:a:0 -c:v h264_nvenc -preset ${NVENC_PRESET} -profile:v high -level:v 4.0 -pix_fmt yuv420p -vf \"$SCALE_FILTER\" -rc:v vbr_hq -b:v \"$BITRATE_TARGET\" -maxrate:v \"$BITRATE_MAX\" -bufsize:v \"$BITRATE_BUFSIZE\" $AUDIO_PARAMS -movflags frag_keyframe+empty_moov -f mp4 - -progress pipe:2"

        log "Streaming to $SSH_HOST for GPU transcoding..."
        ssh -q -T -o "ConnectTimeout=15" -o "StrictHostKeyChecking=no" -p "$SSH_PORT" -i "$SSH_KEY" "$SSH_USER@$SSH_HOST" \
            "$FFMPEG_CMD_GPU" < "$VIDEO_FILE" > "$TEMP_OUTPUT_FILE" 2> "$PROGRESS_PIPE" &

    else
        # --- CPU TRANSCODING LOGIC (INTEGRATED) ---
        log "Starting local CPU transcoding..."
        SCALE_FILTER="scale=w='min(iw,${RESOLUTION_MAX%x*})':h='min(ih,${RESOLUTION_MAX#*x})':force_original_aspect_ratio=decrease"

        # Use VAAPI on Synology as it's more reliable than QSV/libmfx
        # FORCING SOFTWARE ENCODING due to persistent VAAPI driver incompatibility in this container.
        if [ "false" = "true" ] && [ "$ENABLE_CPU_HW_ACCEL" = "true" ] && ffmpeg -v quiet -hwaccels | grep -q 'vaapi' && [ -c /dev/dri/renderD128 ]; then
            log "Using VAAPI hardware acceleration for encoding."
            ENCODER_LABEL="VAAPI"
            FFMPEG_LOG_FILE="${LOG_DIR}/${LOG_FILE_BASE}_vaapi.log"
            # Added -progress pipe:1 to send progress data to stdout for the progress reader.
            FFMPEG_CMD="ffmpeg -loglevel error -hide_banner -progress pipe:1 -init_hw_device vaapi=va:/dev/dri/renderD128 -i \"$VIDEO_FILE\" -vf \"format=nv12,hwupload,${SCALE_FILTER}\" -c:v h264_vaapi -c:a copy -qp 23 -y \"$TEMP_OUTPUT_FILE\""
        else
            log "Using software encoding (libx264)."
            ENCODER_LABEL="CPU"
            FFMPEG_LOG_FILE="${LOG_DIR}/${LOG_FILE_BASE}_cpu.log"
            # Added -progress pipe:1 to send progress data to stdout for the progress reader.
            FFMPEG_CMD="ffmpeg -loglevel error -hide_banner -progress pipe:1 -i \"$VIDEO_FILE\" -vf \"$SCALE_FILTER\" -c:v libx264 -preset medium -crf 23 -pix_fmt yuv420p -c:a copy -c:s mov_text -f mp4 \"$TEMP_OUTPUT_FILE\""
        fi

        log "Creating ffmpeg log file: $FFMPEG_LOG_FILE"
        touch "$FFMPEG_LOG_FILE"
        log "Executing ffmpeg..."
        # Execute the command string using eval to correctly parse quoted arguments.
        # Errors are now sent to the dedicated ffmpeg log file.
        # Use stdbuf to force line-buffering on stdout for more real-time progress.
        eval "stdbuf -oL $FFMPEG_CMD" 1>"$PROGRESS_PIPE" 2>>"$FFMPEG_LOG_FILE" &
    fi

    FFMPEG_PID=$!
    log "ffmpeg process started with PID: $FFMPEG_PID"

    # --- Progress Reader ---
    (
        LAST_PERCENTAGE=-1
        CURRENT_SPEED="1"
        ETR_STR="--:--"
        TIME_S=0
        SPINNER_CHARS="|/-\\"
        i=0

        while IFS= read -r -t 300 LINE; do
            if echo "$LINE" | grep -q "out_time_ms"; then
                TIME_US=$(echo "$LINE" | cut -d= -f2)
                TIME_S=$((TIME_US / 1000000))
                if [ "$TOTAL_DURATION_S" -gt 0 ]; then
                    PERCENTAGE=$((TIME_S * 100 / TOTAL_DURATION_S))
                    if [ "$PERCENTAGE" -gt "$LAST_PERCENTAGE" ]; then
                        LAST_PERCENTAGE=$PERCENTAGE
                    fi
                fi
            fi
            if echo "$LINE" | grep -q "speed"; then
                CURRENT_SPEED=$(echo "$LINE" | cut -d= -f2 | sed 's/x//' | cut -d. -f1)
            fi
            if [ "$CURRENT_SPEED" -gt "0" ] && [ "$TOTAL_DURATION_S" -gt 0 ]; then
                REMAINING_S=$(( (TOTAL_DURATION_S - TIME_S) / CURRENT_SPEED ))
                ETR_STR=$(printf "%02d:%02d" $((REMAINING_S/60)) $((REMAINING_S%60)) )
            fi
            i=$(((i + 1) % 4))
            SPINNER_CHAR=$(echo "$SPINNER_CHARS" | cut -c $((i + 1)))
            printf "\r[%s] Transcoding (%s): %s%% | Speed: %sx | ETA: %s" "$SPINNER_CHAR" "$ENCODER_LABEL" "$LAST_PERCENTAGE" "$CURRENT_SPEED" "$ETR_STR"
        done < "$PROGRESS_PIPE"

        # If the loop finishes, ensure ffmpeg is killed
        kill "$FFMPEG_PID" 2>/dev/null || true
    ) &
    PROGRESS_PID=$!

    wait $FFMPEG_PID
    FFMPEG_EXIT_CODE=$?

    kill "$PROGRESS_PID" 2>/dev/null || true

    if [ $FFMPEG_EXIT_CODE -eq 0 ]; then
        log "Transcoding completed successfully."
        mv "$TEMP_OUTPUT_FILE" "$FINAL_OUTPUT_FILE"
        rm "$VIDEO_FILE"
        log "Original file removed."
        NEEDS_NOTIFICATION=1
    else
        log "Error: Transcoding failed with exit code $FFMPEG_EXIT_CODE."
        rm -f "$TEMP_OUTPUT_FILE"
        exit 1
    fi
fi

# --- Notify Media Servers ---
notify_plex() {
    local SECTION_ID=""
    case "$JOB_CATEGORY" in
        sonarr|tv|series) SECTION_ID="$PLEX_SECTION_ID_TV" ;;
        radarr|movies) SECTION_ID="$PLEX_SECTION_ID_MOVIES" ;;
        *) SECTION_ID="$PLEX_SECTION_ID" ;;
    esac

    if [ -n "$PLEX_URL" ] && [ -n "$PLEX_TOKEN" ] && [ -n "$SECTION_ID" ]; then
        log "Triggering Plex library scan for section: $SECTION_ID"
        curl --connect-timeout 10 --max-time 30 -s -G \
            "${PLEX_URL}/library/sections/${SECTION_ID}/refresh" \
            -H "X-Plex-Token: ${PLEX_TOKEN}" > /dev/null
    fi
}

notify_sonarr() {
    if [ -n "$SONARR_URL" ] && [ -n "$SONARR_API_KEY" ]; then
        log "Triggering Sonarr scan."
        curl --connect-timeout 10 --max-time 30 -s -X POST \
            "${SONARR_URL}/api/v3/command" \
            -H "Content-Type: application/json" -H "X-Api-Key: ${SONARR_API_KEY}" \
            -d '{"name": "DownloadedEpisodesScan"}' > /dev/null
    fi
}

notify_radarr() {
    if [ -n "$RADARR_URL" ] && [ -n "$RADARR_API_KEY" ]; then
        log "Triggering Radarr scan."
        curl --connect-timeout 10 --max-time 30 -s -X POST \
            "${RADARR_URL}/api/v3/command" \
            -H "Content-Type: application/json" -H "X-Api-Key: ${RADARR_API_KEY}" \
            -d '{"name": "DownloadedMoviesScan"}' > /dev/null
    fi
}

if [ "$NEEDS_NOTIFICATION" -eq 1 ]; then
    log "Notifying media servers..."
    case "$JOB_CATEGORY" in
        sonarr|tv|series) notify_sonarr ;;
        radarr|movies) notify_radarr ;;
        *)
            log "Generic category '$JOB_CATEGORY'. Notifying all."
            notify_sonarr
            notify_radarr
            ;;
    esac
    notify_plex
fi

# Final cleanup logic
if [ -f "$TEMP_OUTPUT_FILE" ] && [ ! -s "$FINAL_OUTPUT_FILE" ]; then
    log "Moving temp file to final destination."
    mv "$TEMP_OUTPUT_FILE" "$FINAL_OUTPUT_FILE"
fi

if [ -p "$PROGRESS_PIPE" ]; then
    rm "$PROGRESS_PIPE"
fi

# This will now only be reached on success
log "--- SCRIPT END (SUCCESS) ---"

# Unset the trap on a clean exit
trap - ERR
exit 0 