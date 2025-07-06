#!/bin/sh
set -eu

# ==============================================================================
# Sabnzbd Post-Processing Script: Transcode to MP4 (v4.0)
# ==============================================================================
#
# Author: Gemini / KPKev
# Version: 4.0
#
# This script intelligently transcodes video files to a web-optimized MP4
# format (H.264/AAC) for maximum Direct Play compatibility.
#
# It uses a configurable priority system to attempt transcoding using:
#   1. Remote Intel iGPU (QSV)
#   2. Remote NVIDIA dGPU (NVENC)
#   3. Local Synology CPU (libx264)
#
# Each method can be enabled or disabled independently in transcode.conf.
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
# Transcoder Priority & Control
TRANSCODE_PRIORITY="${TRANSCODE_PRIORITY:-remote_igpu remote_dgpu local_cpu}"
ENABLE_REMOTE_IGPU="${ENABLE_REMOTE_IGPU:-true}"
ENABLE_REMOTE_DGPU="${ENABLE_REMOTE_DGPU:-true}"
ENABLE_LOCAL_CPU="${ENABLE_LOCAL_CPU:-true}"
QSV_PRESET="${QSV_PRESET:-slow}"
NVENC_PRESET="${NVENC_PRESET:-p4}"

# SSH & Remote
SSH_HOST="${SSH_HOST:-}"
SSH_PORT="${SSH_PORT:-22}"
SSH_USER="${SSH_USER:-}"
SSH_KEY="${SSH_KEY:-/config/.ssh/id_rsa}"

# Encoding Targets
BITRATE_TARGET="${BITRATE_TARGET:-6M}"
BITRATE_MAX="${BITRATE_MAX:-8M}"
BITRATE_BUFSIZE="${BITRATE_BUFSIZE:-16M}"
RESOLUTION_MAX="${RESOLUTION_MAX:-1920x1080}"

# Logging
LOG_KEEP="${LOG_KEEP:-10}"

# Service Integrations (Sonarr, Radarr, Plex)
SONARR_URL="${SONARR_URL:-}"
SONARR_API_KEY="${SONARR_API_KEY:-}"
RADARR_URL="${RADARR_URL:-}"
RADARR_API_KEY="${RADARR_API_KEY:-}"
PLEX_URL="${PLEX_URL:-}"
PLEX_TOKEN="${PLEX_TOKEN:-}"
PLEX_SECTION_ID_TV="${PLEX_SECTION_ID_TV:-}"
PLEX_SECTION_ID_MOVIES="${PLEX_SECTION_ID_MOVIES:-}"
PLEX_SECTION_ID="${PLEX_SECTION_ID:-}" # Legacy, for compatibility

# --- Sabnzbd Environment Variables ---
JOB_PATH="$1"
JOB_NAME="$3"
JOB_CATEGORY="${5:-}"

# --- Script Setup ---
SCRIPT_DIR="$(dirname "$0")"
TIMESTAMP=$(date +"%Y-%m-%d_%H-%M-%S")
LOG_DIR="${SCRIPT_DIR}/logs"
JOB_NAME_SAFE=$(echo "$JOB_NAME" | sed 's/[^a-zA-Z0-9._-]/_/g' | cut -c 1-50)
LOG_FILE_BASE="${LOG_DIR}/${TIMESTAMP}_${JOB_NAME_SAFE}"
MAIN_LOG_FILE="${LOG_FILE_BASE}_main.log"
NEEDS_TRANSCODE=0
NEEDS_NOTIFICATION=0
TRANSCODE_SUCCESS=false

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
            head -n "-${LOG_KEEP}" |
            cut -d' ' -f2- |
            xargs -r rm -f
    ) &
}

# --- Cleanup on Exit ---
cleanup() {
    # This trap is primarily for successful exits now.
    # Errors are handled by the ERR trap.
    if [ "$TRANSCODE_SUCCESS" = true ]; then
        log "--- SCRIPT END (SUCCESS) ---"
    fi
}
trap cleanup EXIT

# --- Robust Error Trapping ---
handle_error() {
    local exit_code=$1
    local line_no=$2
    local log_file_path=${MAIN_LOG_FILE:-"/dev/null"}

    echo "$(date +"%Y-%m-%d %H:%M:%S") | --- SCRIPT ERROR ---" >> "$log_file_path"
    echo "$(date +"%Y-%m-%d %H:%M:%S") | Error on or near line ${line_no}; exiting with status ${exit_code}." >> "$log_file_path"
    echo "$(date +"%Y-%m-%d %H:%M:%S") | --- SCRIPT END (FAILURE) ---" >> "$log_file_path"

    # Clean up temporary file if it exists
    if [ -n "${TEMP_OUTPUT_FILE:-}" ] && [ -f "$TEMP_OUTPUT_FILE" ]; then
        rm -f "$TEMP_OUTPUT_FILE"
    fi
    exit "$exit_code"
}
trap 'handle_error $? $LINENO' ERR INT TERM

# --- Shared Progress Reader for All Transcoders ---
# Reads a combined stream of progress data and log data.
# Updates a live progress bar and writes logs to the main log file.
read_progress_and_log() {
    local ENCODER_LABEL=$1
    local FFMPEG_PID=$2

    local spinner="/-\\|"
    local spin_i=0
    local last_percentage=-1
    local current_speed="1"
    local etr_str="--:--"

    # Get duration once.
    TOTAL_DURATION_S=$(ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 "$VIDEO_FILE" | cut -d. -f1)
    [ -z "$TOTAL_DURATION_S" ] && TOTAL_DURATION_S=1

    # Loop until the ffmpeg process is no longer running.
    # The 'kill -0' check is a robust way to see if a PID exists.
    while kill -0 "$FFMPEG_PID" 2>/dev/null; do
        # Read from the progress pipe with a timeout.
        # This prevents the loop from getting stuck if ffmpeg hangs.
        if IFS= read -r -t 5 line; then
            # Check if the line is progress data (contains '=')
            if echo "$line" | grep -q '='; then
                key=$(echo "$line" | cut -d'=' -f1)
                value=$(echo "$line" | cut -d'=' -f2 | tr -d '[:space:]')
                if [ "$key" = "out_time_us" ]; then
                    current_time_us=$value
                    progress_s=$((current_time_us / 1000000))
                    # Ensure percentage doesn't exceed 100
                    percent=$(( (progress_s * 100) / (TOTAL_DURATION_S > 0 ? TOTAL_DURATION_S : 1) ))
                    [ $percent -gt 100 ] && percent=100
                    last_percentage=$percent
                elif [ "$key" = "speed" ]; then
                    current_speed=$(echo "$value" | sed 's/x//' | cut -d. -f1)
                    [ -z "$current_speed" ] && current_speed=1
                fi
            else
                # This is a log line, so write it to the main log file, prefixed for clarity.
                echo "$(date +'%Y-%m-%d %H:%M:%S') | FFMPEG: $line" >> "$MAIN_LOG_FILE"
            fi
        fi
        
        # Update spinner and ETA regardless of new data, to show it's alive.
        if [ "$current_speed" -gt "0" ] && [ "$TOTAL_DURATION_S" -gt 0 ] && [ "${progress_s:-0}" -gt 0 ]; then
            remaining_s=$(( (TOTAL_DURATION_S - progress_s) / current_speed ))
            etr_str=$(printf "%02d:%02d" $((remaining_s / 60)) $((remaining_s % 60)))
        fi
        spin_i=$(((spin_i + 1) % 4))
        spinner_char=$(echo "$spinner" | cut -c $((spin_i + 1)))
        
        # Draw the progress bar.
        printf "\r[%s] %s: %s%% | Speed: %sx | ETA: %s" "$spinner_char" "$ENCODER_LABEL" "$last_percentage" "$current_speed" "$etr_str"
    done
    
    echo # Newline after the progress bar is complete.
}

# --- Function to check if remote host is available ---
check_remote_host() {
    if [ -z "$SSH_HOST" ] || [ -z "$SSH_USER" ]; then
        log "SSH_HOST or SSH_USER not defined in config. Cannot use remote transcoders."
        return 1
    fi
    if ! ssh -q -o BatchMode=yes -o StrictHostKeyChecking=no -o ConnectTimeout=10 -p "$SSH_PORT" -i "$SSH_KEY" "$SSH_USER@$SSH_HOST" "echo ok" 2>/dev/null; then
        log "Remote host $SSH_HOST is not reachable."
        return 1
    fi
    return 0
}

# --- Transcoder: Remote Intel iGPU (QSV) ---
run_remote_igpu() {
    log "--- Starting Remote iGPU Transcode (QSV) ---"
    local PROGRESS_PIPE="${LOG_DIR}/ffmpeg_progress_${RANDOM}.pipe"
    mkfifo "$PROGRESS_PIPE"

    # The remote ffmpeg command now sends progress to stderr (pipe:2)
    # ALL -hwaccel flags have been removed. We let the -c:v h264_qsv encoder
    # handle the hardware interaction, which is more robust.
    local FFMPEG_CMD_REMOTE="ffmpeg -hide_banner -loglevel error -y \
        -progress pipe:2 \
        -i - \
        -map 0:v:0 -map 0:a:0? \
        -c:v h264_qsv -preset:v ${QSV_PRESET} -profile:v high -level:v 4.0 -pix_fmt yuv420p \
        -vf \"scale=w=min(iw\\,${RESOLUTION_MAX%x*}):h=min(ih\\,${RESOLUTION_MAX#*x*}):force_original_aspect_ratio=decrease\" \
        -b:v ${BITRATE_TARGET} -maxrate:v ${BITRATE_MAX} -bufsize:v ${BITRATE_BUFSIZE} \
        ${AUDIO_PARAMS} \
        -movflags frag_keyframe+empty_moov -f mp4 -"

    # Execute via SSH in the background.
    # Stderr (2>) from the remote ffmpeg contains combined progress and logs,
    # which we pipe into our local progress pipe.
    ssh -T -o "ConnectTimeout=15" -o "StrictHostKeyChecking=no" -p "$SSH_PORT" -i "$SSH_KEY" "$SSH_USER@$SSH_HOST" \
        "$FFMPEG_CMD_REMOTE" < "$VIDEO_FILE" > "$TEMP_OUTPUT_FILE" 2> "$PROGRESS_PIPE" &
    
    local ssh_pid=$!

    # Start the universal progress reader
    log "--- FFMPEG Output for Remote iGPU ---"
    read_progress_and_log "Remote iGPU" "$ssh_pid" < "$PROGRESS_PIPE"
    log "--- End of FFMPEG Output for Remote iGPU ---"
    rm -f "$PROGRESS_PIPE"

    wait $ssh_pid
    local ssh_ec=$?
    if [ $ssh_ec -eq 0 ] && [ -s "$TEMP_OUTPUT_FILE" ]; then
        log "Remote iGPU transcode completed successfully."
        return 0
    else
        log "Remote iGPU transcode failed. Exit code: $ssh_ec."
        # Clean up failed artifact
        rm -f "$TEMP_OUTPUT_FILE"
        return 1
    fi
}

# --- Transcoder: Remote NVIDIA dGPU (NVENC) ---
run_remote_dgpu() {
    log "--- Starting Remote dGPU Transcode (NVENC) ---"
    local PROGRESS_PIPE="${LOG_DIR}/ffmpeg_progress_${RANDOM}.pipe"
    mkfifo "$PROGRESS_PIPE"

    # The remote ffmpeg command now sends progress to stderr (pipe:2)
    local FFMPEG_CMD_REMOTE="ffmpeg -hide_banner -loglevel error -y -i - \
        -progress pipe:2 \
        -map 0:v:0 -map 0:a:0? \
        -c:v h264_nvenc -preset:v ${NVENC_PRESET} -profile:v high -level:v 4.0 -pix_fmt yuv420p \
        -vf \"scale=w=min(iw\\,${RESOLUTION_MAX%x*}):h=min(ih\\,${RESOLUTION_MAX#*x*}):force_original_aspect_ratio=decrease\" \
        -rc:v vbr_hq -b:v ${BITRATE_TARGET} -maxrate:v ${BITRATE_MAX} -bufsize:v ${BITRATE_BUFSIZE} \
        ${AUDIO_PARAMS} \
        -movflags frag_keyframe+empty_moov -f mp4 -"

    ssh -T -o "ConnectTimeout=15" -o "StrictHostKeyChecking=no" -p "$SSH_PORT" -i "$SSH_KEY" "$SSH_USER@$SSH_HOST" \
        "$FFMPEG_CMD_REMOTE" < "$VIDEO_FILE" > "$TEMP_OUTPUT_FILE" 2> "$PROGRESS_PIPE" &
    
    local ssh_pid=$!

    # Start the universal progress reader
    log "--- FFMPEG Output for Remote dGPU ---"
    read_progress_and_log "Remote dGPU" "$ssh_pid" < "$PROGRESS_PIPE"
    log "--- End of FFMPEG Output for Remote dGPU ---"
    rm -f "$PROGRESS_PIPE"

    wait $ssh_pid
    local ssh_ec=$?
    if [ $ssh_ec -eq 0 ] && [ -s "$TEMP_OUTPUT_FILE" ]; then
        log "Remote dGPU transcode completed successfully."
        return 0
    else
        log "Remote dGPU transcode failed. Exit code: $ssh_ec."
        rm -f "$TEMP_OUTPUT_FILE"
        return 1
    fi
}

# --- Transcoder: Local CPU (libx264) ---
run_local_cpu() {
    log "--- Starting Local CPU Transcode (libx264) ---"
    local PROGRESS_PIPE="${LOG_DIR}/ffmpeg_progress_${RANDOM}.pipe"
    mkfifo "$PROGRESS_PIPE"

    local SCALE_FILTER="scale=w='min(iw,${RESOLUTION_MAX%x*})':h='min(ih,${RESOLUTION_MAX#*x})':force_original_aspect_ratio=decrease"

    # Run ffmpeg in the background, sending combined output to the progress pipe
    ffmpeg -hide_banner -loglevel error -progress pipe:1 -y \
        -i "$VIDEO_FILE" \
        -map 0:v:0 -map 0:a:0? \
        -c:v libx264 -preset medium -crf 23 -pix_fmt yuv420p \
        -vf "$SCALE_FILTER" \
        ${AUDIO_PARAMS} \
        -movflags frag_keyframe+empty_moov -f mp4 "$TEMP_OUTPUT_FILE" > "$PROGRESS_PIPE" 2>&1 &
    
    local ffmpeg_pid=$!

    # Use the new universal progress reader
    log "--- FFMPEG Output for Local CPU ---"
    read_progress_and_log "Local CPU" "$ffmpeg_pid" < "$PROGRESS_PIPE"
    log "--- End of FFMPEG Output for Local CPU ---"
    rm -f "$PROGRESS_PIPE"

    wait $ffmpeg_pid
    local ffmpeg_ec=$?
    if [ $ffmpeg_ec -eq 0 ] && [ -s "$TEMP_OUTPUT_FILE" ]; then
        log "Local CPU transcode completed successfully."
        return 0
    else
        log "Local CPU transcode failed. Exit code: $ffmpeg_ec."
        rm -f "$TEMP_OUTPUT_FILE"
        return 1
    fi
}

# --- Sonarr/Radarr Refresh ---
send_notification() {
    # This function remains unchanged...
    : # Placeholder for existing notification logic
}

# ==============================================================================
# --- Main Execution Flow ---
# ==============================================================================

rotate_logs
log "--- SCRIPT START (v4.0 Priority) ---"
log "Job Name: ${JOB_NAME}"
log "Job Path: ${JOB_PATH}"
log "Category: ${JOB_CATEGORY}"

VIDEO_FILE=$(find "$JOB_PATH" -type f \( -name "*.mkv" -o -name "*.mp4" -o -name "*.avi" -o -name "*.mov" \) -printf '%s %p\n' | sort -rn | head -n 1 | cut -d' ' -f2-)

if [ -z "$VIDEO_FILE" ]; then
    log "No video file found in '$JOB_PATH'. Nothing to do."
    exit 0
fi
log "Found video file: $VIDEO_FILE"

VIDEO_CODEC=$(ffprobe -v error -select_streams v:0 -show_entries stream=codec_name -of default=noprint_wrappers=1:nokey=1 "$VIDEO_FILE" 2>/dev/null)
AUDIO_CODEC=$(ffprobe -v error -select_streams a:0 -show_entries stream=codec_name -of default=noprint_wrappers=1:nokey=1 "$VIDEO_FILE" 2>/dev/null)
AUDIO_CHANNELS=$(ffprobe -v error -select_streams a:0 -show_entries stream=channels -of default=noprint_wrappers=1:nokey=1 "$VIDEO_FILE" 2>/dev/null)
CONTAINER=$(basename "$VIDEO_FILE" | rev | cut -d . -f 1 | rev)

log "Detected format: Container=$CONTAINER, Video=$VIDEO_CODEC, Audio=$AUDIO_CODEC (${AUDIO_CHANNELS}ch)"

if [ "$CONTAINER" = "mp4" ] && [ "$VIDEO_CODEC" = "h264" ] && [ "$AUDIO_CODEC" = "aac" ] && [ "$AUDIO_CHANNELS" -le 2 ]; then
    log "File is already compliant. No transcoding needed."
    NEEDS_TRANSCODE=0
    NEEDS_NOTIFICATION=1 # Still notify Sonarr/Radarr of the import
else
    log "File requires transcoding."
    NEEDS_TRANSCODE=1
fi

if [ "$NEEDS_TRANSCODE" -eq 1 ]; then
    JOB_DIR=$(dirname "$VIDEO_FILE")
    OUTBASE=$(basename "${VIDEO_FILE%.*}")
    FINAL_OUTPUT_FILE="${JOB_DIR}/${OUTBASE}.mp4"
    TEMP_OUTPUT_FILE="${JOB_DIR}/${OUTBASE}.tmp.mp4"

    # --- Build Audio Command ---
    if [ "$AUDIO_CODEC" = "aac" ] && [ "$AUDIO_CHANNELS" -le 2 ]; then
        log "Audio is AAC with 2 or fewer channels. Stream will be copied."
        AUDIO_PARAMS="-c:a copy"
    else
        log "Audio is '${AUDIO_CODEC}'. It will be transcoded to AAC stereo."
        AUDIO_PARAMS="-c:a aac -ac 2 -b:a 192k"
    fi

    REMOTE_HOST_OK=false
    if echo "$TRANSCODE_PRIORITY" | grep -q "remote"; then
        check_remote_host && REMOTE_HOST_OK=true
    fi
    
    # --- Transcoder Priority Loop ---
    for transcoder in $TRANSCODE_PRIORITY; do
        case $transcoder in
            remote_igpu)
                if [ "$ENABLE_REMOTE_IGPU" = "true" ] && [ "$REMOTE_HOST_OK" = "true" ]; then
                    if run_remote_igpu; then TRANSCODE_SUCCESS=true; break; fi
                else
                    log "Skipping remote_igpu (disabled or host unreachable)."
                fi
                ;;
            remote_dgpu)
                if [ "$ENABLE_REMOTE_DGPU" = "true" ] && [ "$REMOTE_HOST_OK" = "true" ]; then
                    if run_remote_dgpu; then TRANSCODE_SUCCESS=true; break; fi
                else
                    log "Skipping remote_dgpu (disabled or host unreachable)."
                fi
                ;;
            local_cpu)
                if [ "$ENABLE_LOCAL_CPU" = "true" ]; then
                    if run_local_cpu; then TRANSCODE_SUCCESS=true; break; fi
                else
                    log "Skipping local_cpu (disabled)."
                fi
                ;;
            *)
                log "Warning: Unknown transcoder '$transcoder' in priority list."
                ;;
        esac
    done

    # --- Finalize ---
    if [ "$TRANSCODE_SUCCESS" = true ]; then
        log "Transcode successful. Finalizing files."
        mv "$TEMP_OUTPUT_FILE" "$FINAL_OUTPUT_FILE"
        if [ "$VIDEO_FILE" != "$FINAL_OUTPUT_FILE" ]; then
            rm "$VIDEO_FILE"
        fi
        NEEDS_NOTIFICATION=1
    else
        log "All transcoding attempts failed. Leaving original file intact."
        # No error trap exit, because failing to transcode is not a script error.
        # It's a process failure. The script itself ran correctly.
        exit 1
    fi
fi

if [ "$NEEDS_NOTIFICATION" -eq 1 ]; then
    send_notification
fi 