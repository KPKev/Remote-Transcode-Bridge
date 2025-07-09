#!/bin/bash
set -euo pipefail

# ==============================================================================
# Sabnzbd Post-Processing Script: Transcode to MP4 (v4.1 - Hardened Recovery)
# ==============================================================================

# --- Tell the system where to find binaries and libraries ---
export PATH="$(dirname "$0"):$PATH"
export LD_LIBRARY_PATH="$(dirname "$0"):${LD_LIBRARY_PATH:-}"

# --- Load Configuration ---
CONFIG_FILE="$(dirname "$0")/transcode.conf"
if [ -f "$CONFIG_FILE" ]; then
    . "$CONFIG_FILE"
fi

# --- Set Defaults for Config Values ---
TRANSCODE_PRIORITY="${TRANSCODE_PRIORITY:-remote_igpu remote_dgpu local_cpu}"
ENABLE_REMOTE_IGPU="${ENABLE_REMOTE_IGPU:-true}"
ENABLE_REMOTE_DGPU="${ENABLE_REMOTE_DGPU:-true}"
ENABLE_LOCAL_CPU="${ENABLE_LOCAL_CPU:-true}"
QSV_PRESET="${QSV_PRESET:-slow}"
NVENC_PRESET="${NVENC_PRESET:-p4}"
SSH_HOST="${SSH_HOST:-}"
SSH_PORT="${SSH_PORT:-22}"
SSH_USER="${SSH_USER:-}"
SSH_KEY="${SSH_KEY:-/config/.ssh/id_rsa}"
BITRATE_TARGET="${BITRATE_TARGET:-6M}"
BITRATE_MAX="${BITRATE_MAX:-8M}"
BITRATE_BUFSIZE="${BITRATE_BUFSIZE:-16M}"
RESOLUTION_MAX="${RESOLUTION_MAX:-1920x1080}"
LOG_KEEP="${LOG_KEEP:-10}"
SONARR_URL="${SONARR_URL:-}"
SONARR_API_KEY="${SONARR_API_KEY:-}"
RADARR_URL="${RADARR_URL:-}"
RADARR_API_KEY="${RADARR_API_KEY:-}"
PLEX_URL="${PLEX_URL:-}"
PLEX_TOKEN="${PLEX_TOKEN:-}"
PLEX_SECTION_ID_TV="${PLEX_SECTION_ID_TV:-}"
PLEX_SECTION_ID_MOVIES="${PLEX_SECTION_ID_MOVIES:-}"
PLEX_SECTION_ID="${PLEX_SECTION_ID:-}"
TAUTULLI_URL="${TAUTULLI_URL:-}"
TAUTULLI_API_KEY="${TAUTULLI_API_KEY:-}"
NOTIFICATION_DELAY_S="${NOTIFICATION_DELAY_S:-45}"

VERBOSE_LOGGING="${VERBOSE_LOGGING:-false}"
ENABLE_TMP_RECOVERY="${ENABLE_TMP_RECOVERY:-true}"
RECOVERY_MAX_DURATION_DIFF_PERCENT="${RECOVERY_MAX_DURATION_DIFF_PERCENT:-2}"
RECOVERY_MIN_SIZE="${RECOVERY_MIN_SIZE:-104857600}"
RECOVERY_LOG_FILE="${RECOVERY_LOG_FILE:-recovery.log}"
GPU_ENCODE_MODE="${GPU_ENCODE_MODE:-cqp}"
GPU_CQ_LEVEL="${GPU_CQ_LEVEL:-25}"

# --- Sabnzbd Environment Variables ---
JOB_PATH="$1"
JOB_NAME="$3"
JOB_CATEGORY="${5:-}"

SCRIPT_DIR="$(dirname "$0")"
TIMESTAMP=$(date +"%Y-%m-%d_%H-%M-%S")
LOG_DIR="${SCRIPT_DIR}/logs"
JOB_NAME_SAFE=$(echo "$JOB_NAME" | sed 's/[^a-zA-Z0-9._-]/_/g' | cut -c 1-50)
LOG_FILE_BASE="${LOG_DIR}/${TIMESTAMP}_${JOB_NAME_SAFE}"
MAIN_LOG_FILE="${LOG_FILE_BASE}_main.log"
RECOVERY_LOG_PATH="${LOG_DIR}/${RECOVERY_LOG_FILE}"
FAILED_MARKER="${JOB_PATH}/_FAILED_TRANSCODE"
mkdir -p "$LOG_DIR"

log() {
    echo "$(date +'%Y-%m-%d %H:%M:%S') | $1" | tee -a "$MAIN_LOG_FILE"
}

log_debug() {
    if [ "$VERBOSE_LOGGING" = "true" ]; then
        echo "$(date +'%Y-%m-%d %H:%M:%S') | DEBUG: $1" | tee -a "$MAIN_LOG_FILE"
    fi
}

log_recovery() {
    local msg="$1"
    echo "$(date +'%Y-%m-%d %H:%M:%S') | $msg" | tee -a "$RECOVERY_LOG_PATH"
}

rotate_logs() {
    (
        find "$LOG_DIR" -maxdepth 1 -name "*.log" -type f -printf '%T@ %p\n' 2>/dev/null |
            sort -n |
            head -n "-${LOG_KEEP}" |
            cut -d' ' -f2- |
            xargs -r rm -f
    ) &
}

cleanup_and_finalize() {
    local status=$?
    set +e # Allow commands in the trap to fail without exiting immediately

    # On any exit, if a temp file exists and the final file does not, try to recover it.
    if [ -n "${VIDEO_FILE:-}" ] && [ -f "${TEMP_OUTPUT_FILE:-}" ] && [ ! -f "$FINAL_OUTPUT_FILE" ]; then
        log_debug "Cleanup: Checking leftover TMP file for promotion."
        if promote_tmp_if_valid "$VIDEO_FILE" "$TEMP_OUTPUT_FILE" "$FINAL_OUTPUT_FILE"; then
            log "Cleanup: TMP auto-promoted to final output."
            if [ "$VIDEO_FILE" != "$FINAL_OUTPUT_FILE" ]; then
                 rm "$VIDEO_FILE"
            fi
            log_recovery "Auto-promoted TMP on script exit: $FINAL_OUTPUT_FILE"
            # Since we recovered, ensure notifications are sent.
            NEEDS_NOTIFICATION=1
            TRANSCODE_SUCCESS=true
        else
            log "Cleanup: TMP was not valid and could not be promoted. Removing."
            rm -f "$TEMP_OUTPUT_FILE"
        fi
    fi

    # Final status logging and notification sending
    if [ "${TRANSCODE_SUCCESS:-false}" = true ]; then
        log "--- SCRIPT END (SUCCESS) ---"
        if [ "${NEEDS_NOTIFICATION:-0}" -eq 1 ]; then
            send_notification
        fi
        exit 0 # Ensure we exit cleanly after success
    else
        # This path is taken if TRANSCODE_SUCCESS was never set to true.
        log "--- SCRIPT END (FAILURE) ---"
        log "All transcoding and recovery attempts have failed. See logs for details."
        log_recovery "Script failed for: ${VIDEO_FILE:-unknown file}. No valid TMP for recovery."
        # Create a marker so other tools know this job failed.
        touch "$FAILED_MARKER"
        exit 1 # Ensure we exit with an error code
    fi
}
trap cleanup_and_finalize EXIT INT TERM

# -------------------- Disk Space Check (Warning Only) -------------------------
disk_space_warn() {
    avail=$(df -h "$SCRIPT_DIR" | awk 'NR==2 {print $4}')
    log_debug "Disk space available: $avail"
}

# -------------------- File/Duration Validation -------------------------
get_duration_seconds() {
    ffprobe -v error -select_streams v:0 -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 "$1" 2>/dev/null | awk '{print int($1)}'
}
is_mp4_playable_and_valid() {
    local src="$1"
    local tmp="$2"
    local max_diff_percent="${RECOVERY_MAX_DURATION_DIFF_PERCENT:-2}"

    # Must exist and be > min size
    [ -f "$tmp" ] || return 1
    [ "$(stat -c %s "$tmp")" -gt "$RECOVERY_MIN_SIZE" ] || return 1

    src_dur=$(get_duration_seconds "$src")
    tmp_dur=$(get_duration_seconds "$tmp")
    [ -z "$src_dur" ] && return 1
    [ -z "$tmp_dur" ] && return 1
    diff=$(awk -v a="$src_dur" -v b="$tmp_dur" 'BEGIN{print (a>b?a-b:b-a)}')
    pct=$(awk -v d="$diff" -v s="$src_dur" 'BEGIN{print (d/s)*100}')
    intpct=$(printf "%.0f" "$pct")
    if [ "$intpct" -le "$max_diff_percent" ]; then
        return 0
    else
        log_debug "TMP duration ($tmp_dur) differs from source ($src_dur) by $intpct%"
        return 1
    fi
}

promote_tmp_if_valid() {
    local src="$1"
    local tmp="$2"
    local final="$3"
    if is_mp4_playable_and_valid "$src" "$tmp"; then
        mv "$tmp" "$final"
        log "Recovery: Moved $tmp to $final (auto-promoted valid TMP)"
        log_recovery "Auto-promoted TMP: $final (source: $src)"
        TRANSCODE_SUCCESS=true
        return 0
    else
        log_debug "Recovery: TMP not valid or playable, not promoted ($tmp)"
        return 1
    fi
}

# -------------------- TMP Recovery Logic -------------------------
tmp_recovery_check() {
    [ "$ENABLE_TMP_RECOVERY" = "true" ] || return 0
    if [ -n "${VIDEO_FILE:-}" ]; then
        OUTBASE=$(basename "${VIDEO_FILE%.*}")
        FINAL_OUTPUT_FILE="${JOB_DIR}/${OUTBASE}.mp4"
        TEMP_OUTPUT_FILE="${JOB_DIR}/${OUTBASE}.tmp.mp4"
        # If TMP exists but final doesn't, and TMP is valid: promote it.
        if [ -f "$TEMP_OUTPUT_FILE" ] && [ ! -f "$FINAL_OUTPUT_FILE" ]; then
            log "TMP Recovery: Checking $TEMP_OUTPUT_FILE for promotion"
            promote_tmp_if_valid "$VIDEO_FILE" "$TEMP_OUTPUT_FILE" "$FINAL_OUTPUT_FILE"
        fi
    fi
}

# ------------- Core Script Transcode Runners + Logging ---------------

read_progress_and_log() {
    local ENCODER_LABEL=$1
    local FFMPEG_PID=$2
    local spinner="/-\\|"
    local spin_i=0
    local last_percentage=-1
    local current_speed="1"
    local etr_str="--:--"
    TOTAL_DURATION_S=$(ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 "$VIDEO_FILE" | cut -d. -f1)
    [ -z "$TOTAL_DURATION_S" ] && TOTAL_DURATION_S=1
    while kill -0 "$FFMPEG_PID" 2>/dev/null; do
        if IFS= read -r -t 5 line; then
            if echo "$line" | grep -q '='; then
                key=$(echo "$line" | cut -d'=' -f1)
                value=$(echo "$line" | cut -d'=' -f2 | tr -d '[:space:]')
                if [ "$key" = "out_time_us" ]; then
                    current_time_us=$value
                    progress_s=$((current_time_us / 1000000))
                    percent=$(( (progress_s * 100) / (TOTAL_DURATION_S > 0 ? TOTAL_DURATION_S : 1) ))
                    [ $percent -gt 100 ] && percent=100
                    last_percentage=$percent
                elif [ "$key" = "speed" ]; then
                    current_speed=$(echo "$value" | sed 's/x//' | cut -d. -f1)
                    [ -z "$current_speed" ] && current_speed=1
                fi
            else
                echo "$(date +'%Y-%m-%d %H:%M:%S') | FFMPEG: $line" >> "$MAIN_LOG_FILE"
            fi
        fi
        if [ "$current_speed" -gt "0" ] && [ "$TOTAL_DURATION_S" -gt 0 ] && [ "${progress_s:-0}" -gt 0 ]; then
            remaining_s=$(( (TOTAL_DURATION_S - progress_s) / current_speed ))
            etr_str=$(printf "%02d:%02d" $((remaining_s / 60)) $((remaining_s % 60)))
        fi
        spin_i=$(((spin_i + 1) % 4))
        spinner_char=$(echo "$spinner" | cut -c $((spin_i + 1)))
        printf "\r[%s] %s: %s%% | Speed: %sx | ETA: %s" "$spinner_char" "$ENCODER_LABEL" "$last_percentage" "$current_speed" "$etr_str"
    done
    echo
}

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

run_remote_igpu() {
    log "--- Starting Remote iGPU Transcode (QSV) ---"
    disk_space_warn
    local PROGRESS_PIPE="${LOG_DIR}/ffmpeg_progress_${RANDOM}.pipe"
    local FFMPEG_STDERR_LOG="${LOG_DIR}/ffmpeg_stderr_${RANDOM}.log"
    mkfifo "$PROGRESS_PIPE"
    
    local FFMPEG_CMD_REMOTE=""
    if [ "$GPU_ENCODE_MODE" = "cqp" ]; then
        log_debug "Using CQP (ICQ) mode for iGPU with quality level ${GPU_CQ_LEVEL}"
        FFMPEG_CMD_REMOTE="ffmpeg -hide_banner -loglevel error -y \
            -progress pipe:2 -i - \
            -map 0:v:0 -map 0:a:0? \
            -c:v h264_qsv -preset:v ${QSV_PRESET} -profile:v high -level:v 4.1 -pix_fmt yuv420p \
            -global_quality ${GPU_CQ_LEVEL} \
            -vf \"scale_qsv=w=min(iw\\,${RESOLUTION_MAX%x*}):h=min(ih\\,${RESOLUTION_MAX#*x*}):force_original_aspect_ratio=decrease\" \
            ${AUDIO_PARAMS} \
            -movflags frag_keyframe+empty_moov -f mp4 -"
    else
        log_debug "Using Bitrate mode for iGPU with target ${BITRATE_TARGET}"
        FFMPEG_CMD_REMOTE="ffmpeg -hide_banner -loglevel error -y \
            -progress pipe:2 \
            -i - \
            -map 0:v:0 -map 0:a:0? \
            -c:v h264_qsv -preset:v ${QSV_PRESET} -profile:v high -level:v 4.0 -pix_fmt yuv420p \
            -vf \"scale=w=min(iw\\,${RESOLUTION_MAX%x*}):h=min(ih\\,${RESOLUTION_MAX#*x*}):force_original_aspect_ratio=decrease\" \
            -b:v ${BITRATE_TARGET} -maxrate:v ${BITRATE_MAX} -bufsize:v ${BITRATE_BUFSIZE} \
            ${AUDIO_PARAMS} \
            -movflags frag_keyframe+empty_moov -f mp4 -"
    fi

    ssh -T -o "ConnectTimeout=15" -o "StrictHostKeyChecking=no" -p "$SSH_PORT" -i "$SSH_KEY" "$SSH_USER@$SSH_HOST" \
        "$FFMPEG_CMD_REMOTE" < "$VIDEO_FILE" > "$TEMP_OUTPUT_FILE" 2> >(tee "$PROGRESS_PIPE" > "$FFMPEG_STDERR_LOG") &
    local ssh_pid=$!
    log "--- FFMPEG Output for Remote iGPU ---"
    read_progress_and_log "Remote iGPU" "$ssh_pid" < "$PROGRESS_PIPE"
    log "--- End of FFMPEG Output for Remote iGPU ---"
    rm -f "$PROGRESS_PIPE"
    wait $ssh_pid || true
    local ssh_ec=$?
    if [ $ssh_ec -eq 0 ] && [ -s "$TEMP_OUTPUT_FILE" ]; then
        log "Remote iGPU transcode completed successfully."
        return 0
    else
        log "Remote iGPU transcode failed. Exit code: $ssh_ec."
        tail -n 40 "$FFMPEG_STDERR_LOG" | while read -r line; do log_debug "$line"; done
        if [ -s "$TEMP_OUTPUT_FILE" ]; then
            log_debug "WARN: .tmp.mp4 output exists and is non-empty. Attempting auto-promote if valid."
            promote_tmp_if_valid "$VIDEO_FILE" "$TEMP_OUTPUT_FILE" "$FINAL_OUTPUT_FILE" || rm -f "$TEMP_OUTPUT_FILE"
        else
            rm -f "$TEMP_OUTPUT_FILE"
        fi
        return 1
    fi
}

run_remote_dgpu() {
    log "--- Starting Remote dGPU Transcode (NVENC) ---"
    disk_space_warn
    local PROGRESS_PIPE="${LOG_DIR}/ffmpeg_progress_${RANDOM}.pipe"
    local FFMPEG_STDERR_LOG="${LOG_DIR}/ffmpeg_stderr_${RANDOM}.log"
    mkfifo "$PROGRESS_PIPE"

    local FFMPEG_CMD_REMOTE=""
    if [ "$GPU_ENCODE_MODE" = "cqp" ]; then
        log_debug "Using CQP mode for dGPU with quality level ${GPU_CQ_LEVEL}"
        FFMPEG_CMD_REMOTE="ffmpeg -hide_banner -loglevel error -y -i - \
            -progress pipe:2 \
            -map 0:v:0 -map 0:a:0? \
            -c:v h264_nvenc -preset:v ${NVENC_PRESET} -profile:v high -level:v 4.1 -pix_fmt yuv420p \
            -rc:v cqp -qp ${GPU_CQ_LEVEL} \
            -vf \"scale_cuda=w=min(iw\\,${RESOLUTION_MAX%x*}):h=min(ih\\,${RESOLUTION_MAX#*x*}):force_original_aspect_ratio=decrease\" \
            ${AUDIO_PARAMS} \
            -movflags frag_keyframe+empty_moov -f mp4 -"
    else
        log_debug "Using Bitrate (VBR) mode for dGPU with target ${BITRATE_TARGET}"
        FFMPEG_CMD_REMOTE="ffmpeg -hide_banner -loglevel error -y -i - \
            -progress pipe:2 \
            -map 0:v:0 -map 0:a:0? \
            -c:v h264_nvenc -preset:v ${NVENC_PRESET} -profile:v high -level:v 4.0 -pix_fmt yuv420p \
            -vf \"scale=w=min(iw\\,${RESOLUTION_MAX%x*}):h=min(ih\\,${RESOLUTION_MAX#*x*}):force_original_aspect_ratio=decrease\" \
            -rc:v vbr_hq -b:v ${BITRATE_TARGET} -maxrate:v ${BITRATE_MAX} -bufsize:v ${BITRATE_BUFSIZE} \
            ${AUDIO_PARAMS} \
            -movflags frag_keyframe+empty_moov -f mp4 -"
    fi

    ssh -T -o "ConnectTimeout=15" -o "StrictHostKeyChecking=no" -p "$SSH_PORT" -i "$SSH_KEY" "$SSH_USER@$SSH_HOST" \
        "$FFMPEG_CMD_REMOTE" < "$VIDEO_FILE" > "$TEMP_OUTPUT_FILE" 2> >(tee "$PROGRESS_PIPE" > "$FFMPEG_STDERR_LOG") &
    local ssh_pid=$!
    log "--- FFMPEG Output for Remote dGPU ---"
    read_progress_and_log "Remote dGPU" "$ssh_pid" < "$PROGRESS_PIPE"
    log "--- End of FFMPEG Output for Remote dGPU ---"
    rm -f "$PROGRESS_PIPE"
    wait $ssh_pid || true
    local ssh_ec=$?
    if [ $ssh_ec -eq 0 ] && [ -s "$TEMP_OUTPUT_FILE" ]; then
        log "Remote dGPU transcode completed successfully."
        return 0
    else
        log "Remote dGPU transcode failed. Exit code: $ssh_ec."
        tail -n 40 "$FFMPEG_STDERR_LOG" | while read -r line; do log_debug "$line"; done
        if [ -s "$TEMP_OUTPUT_FILE" ]; then
            log_debug "WARN: .tmp.mp4 output exists and is non-empty. Attempting auto-promote if valid."
            promote_tmp_if_valid "$VIDEO_FILE" "$TEMP_OUTPUT_FILE" "$FINAL_OUTPUT_FILE" || rm -f "$TEMP_OUTPUT_FILE"
        else
            rm -f "$TEMP_OUTPUT_FILE"
        fi
        return 1
    fi
}

run_local_cpu() {
    log "--- Starting Local CPU Transcode (libx264) ---"
    disk_space_warn
    local PROGRESS_PIPE="${LOG_DIR}/ffmpeg_progress_${RANDOM}.pipe"
    local FFMPEG_STDERR_LOG="${LOG_DIR}/ffmpeg_stderr_${RANDOM}.log"
    mkfifo "$PROGRESS_PIPE"
    local SCALE_FILTER="scale=w='min(iw,${RESOLUTION_MAX%x*})':h='min(ih,${RESOLUTION_MAX#*x})':force_original_aspect_ratio=decrease"
    ffmpeg -hide_banner -loglevel error -progress pipe:1 -y \
        -i "$VIDEO_FILE" \
        -map 0:v:0 -map 0:a:0? \
        -c:v libx264 -preset slow -crf 23 -pix_fmt yuv420p \
        -vf "$SCALE_FILTER" \
        ${AUDIO_PARAMS} \
        -movflags frag_keyframe+empty_moov -f mp4 "$TEMP_OUTPUT_FILE" > "$PROGRESS_PIPE" 2>"$FFMPEG_STDERR_LOG" &
    local ffmpeg_pid=$!
    log "--- FFMPEG Output for Local CPU ---"
    read_progress_and_log "Local CPU" "$ffmpeg_pid" < "$PROGRESS_PIPE"
    log "--- End of FFMPEG Output for Local CPU ---"
    rm -f "$PROGRESS_PIPE"
    wait $ffmpeg_pid || true
    local ffmpeg_ec=$?
    if [ $ffmpeg_ec -eq 0 ] && [ -s "$TEMP_OUTPUT_FILE" ]; then
        log "Local CPU transcode completed successfully."
        return 0
    else
        log "Local CPU transcode failed. Exit code: $ffmpeg_ec."
        tail -n 40 "$FFMPEG_STDERR_LOG" | while read -r line; do log_debug "$line"; done
        if [ -s "$TEMP_OUTPUT_FILE" ]; then
            log_debug "WARN: .tmp.mp4 output exists and is non-empty. Attempting auto-promote if valid."
            promote_tmp_if_valid "$VIDEO_FILE" "$TEMP_OUTPUT_FILE" "$FINAL_OUTPUT_FILE" || rm -f "$TEMP_OUTPUT_FILE"
        else
            rm -f "$TEMP_OUTPUT_FILE"
        fi
        return 1
    fi
}

# --- Service Notifications (with retry logic) ---

notify_sonarr() {
    if [ -n "$SONARR_URL" ] && [ -n "$SONARR_API_KEY" ]; then
        log "Notifying Sonarr..."
        DOWNLOAD_ID=$(basename "$JOB_PATH")
        resp=$(curl -sL -X POST "${SONARR_URL%/}/api/v3/command" \
            -H "X-Api-Key: $SONARR_API_KEY" \
            -d "{
                \"name\": \"DownloadedEpisodesScan\",
                \"path\": \"$JOB_PATH\",
                \"downloadClientId\": \"${DOWNLOAD_ID}\",
                \"importMode\": \"Move\"
            }")
        if echo "$resp" | grep -q "error"; then
            log "Sonarr notification failed, retrying in 30s..."
            sleep 30
            resp2=$(curl -sL -X POST "${SONARR_URL%/}/api/v3/command" \
                -H "X-Api-Key: $SONARR_API_KEY" \
                -d "{
                    \"name\": \"DownloadedEpisodesScan\",
                    \"path\": \"$JOB_PATH\",
                    \"downloadClientId\": \"${DOWNLOAD_ID}\",
                    \"importMode\": \"Move\"
                }")
            if echo "$resp2" | grep -q "error"; then
                log "Sonarr notification failed again. Giving up."
            fi
        fi
    fi
}

notify_radarr() {
    if [ -n "$RADARR_URL" ] && [ -n "$RADARR_API_KEY" ]; then
        log "Notifying Radarr..."
        DOWNLOAD_ID=$(basename "$JOB_PATH")
        resp=$(curl -sL -X POST "${RADARR_URL%/}/api/v3/command" \
            -H "X-Api-Key: $RADARR_API_KEY" \
            -d "{
                \"name\": \"DownloadedMoviesScan\",
                \"path\": \"$JOB_PATH\",
                \"downloadClientId\": \"${DOWNLOAD_ID}\",
                \"importMode\": \"Move\"
            }")
        if echo "$resp" | grep -q "error"; then
            log "Radarr notification failed, retrying in 30s..."
            sleep 30
            resp2=$(curl -sL -X POST "${RADARR_URL%/}/api/v3/command" \
                -H "X-Api-Key: $RADARR_API_KEY" \
                -d "{
                    \"name\": \"DownloadedMoviesScan\",
                    \"path\": \"$JOB_PATH\",
                    \"downloadClientId\": \"${DOWNLOAD_ID}\",
                    \"importMode\": \"Move\"
                }")
            if echo "$resp2" | grep -q "error"; then
                log "Radarr notification failed again. Giving up."
            fi
        fi
    fi
}

notify_plex() {
    local PLEX_SECTION=$1
    if [ -n "$PLEX_URL" ] && [ -n "$PLEX_TOKEN" ] && [ -n "$PLEX_SECTION" ]; then
        log "Notifying Plex to scan section $PLEX_SECTION..."
        curl -sL -X GET "${PLEX_URL%/}/library/sections/${PLEX_SECTION}/refresh?X-Plex-Token=${PLEX_TOKEN}" >/dev/null
    fi
}

notify_tautulli() {
    local PLEX_SECTION=$1
    if [ -n "$TAUTULLI_URL" ] && [ -n "$TAUTULLI_API_KEY" ] && [ -n "$PLEX_SECTION" ]; then
        log "Notifying Tautulli to refresh its library list from Plex..."
        # The 'update_library' command is from API v1. The v2 equivalent to poke Tautulli is 'refresh_libraries_list'.
        # This command does not take a section_id, but it will trigger a refresh.
        curl -sL -X GET "${TAUTULLI_URL%/}/api/v2?apikey=${TAUTULLI_API_KEY}&cmd=refresh_libraries_list" >/dev/null
    fi
}

send_notification() {
    log "--- Sending Notifications ---"
    case "$JOB_CATEGORY" in
        *movie* | 1)
            log "Category identified as 'Movie'."
            notify_radarr
            log "Waiting ${NOTIFICATION_DELAY_S} seconds for file to be moved before notifying Plex/Tautulli..."
            sleep "$NOTIFICATION_DELAY_S"
            notify_plex "$PLEX_SECTION_ID_MOVIES"
            notify_tautulli "$PLEX_SECTION_ID_MOVIES"
            ;;
        *tv* | *show* | 2)
            log "Category identified as 'TV Show'."
            notify_sonarr
            log "Waiting ${NOTIFICATION_DELAY_S} seconds for file to be moved before notifying Plex/Tautulli..."
            sleep "$NOTIFICATION_DELAY_S"
            notify_plex "$PLEX_SECTION_ID_TV"
            notify_tautulli "$PLEX_SECTION_ID_TV"
            ;;
        *)
            log "Unknown category: '${JOB_CATEGORY}'. Cannot send targeted notifications."
            notify_radarr
            notify_sonarr
            log "Waiting ${NOTIFICATION_DELAY_S} seconds for files to be moved before notifying Plex/Tautulli..."
            sleep "$NOTIFICATION_DELAY_S"
            if [ -n "$PLEX_SECTION_ID" ]; then
                notify_plex "$PLEX_SECTION_ID"
                notify_tautulli "$PLEX_SECTION_ID"
            fi
            ;;
    esac
    log "--- Notifications Complete ---"
}

# ==============================================================================
# --- Main Execution Flow ---
# ==============================================================================

rotate_logs
log "--- SCRIPT START (v4.1 Hardened Recovery) ---"
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
    NEEDS_NOTIFICATION=1
else
    log "File requires transcoding."
    NEEDS_TRANSCODE=1
fi

if [ "$NEEDS_TRANSCODE" -eq 1 ]; then
    JOB_DIR=$(dirname "$VIDEO_FILE")
    OUTBASE=$(basename "${VIDEO_FILE%.*}")
    FINAL_OUTPUT_FILE="${JOB_DIR}/${OUTBASE}.mp4"
    TEMP_OUTPUT_FILE="${JOB_DIR}/${OUTBASE}.tmp.mp4"
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

    # This variable will be checked by the cleanup trap on exit.
    TRANSCODE_SUCCESS=false

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
    # The script now relies on the `cleanup_and_finalize` trap to handle all outcomes.
    # We just need to ensure we exit with the correct status code.
    if [ "${TRANSCODE_SUCCESS:-false}" = true ]; then
        log "All transcoders finished. Proceeding to finalization..."
        # Set variable for notification function, which is now called by the trap
        NEEDS_NOTIFICATION=1
        exit 0 # Exit successfully, the trap will handle file operations and notifications.
    else
        log "All transcoding attempts failed. Exiting with error."
        exit 1 # Exit with failure, the trap will attempt recovery and log the failure.
    fi
fi

# This handles the case where the file was already compliant and didn't need a transcode.
if [ "${NEEDS_NOTIFICATION:-0}" -eq 1 ]; then
    send_notification
fi

# The script should have already exited via the logic above, but as a fallback:
log "Reached end of script unexpectedly. Exiting."
exit 0

