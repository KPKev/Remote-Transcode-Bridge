
# ⚡ Sabnzbd Priority-Based Post-Processing Transcoder

> **Transcode anything, recover everything, and never lose a Sonarr import again.**

---

## ✨ Overview

This is a *powerful*, priority-driven, production-grade post-processing script for [Sabnzbd](https://sabnzbd.org/) that automatically converts any supported video into a web-optimized, Plex/Direct-Play–ready MP4 (H.264/AAC).  
**Supports multiple transcoders, automatic error recovery, and seamless Sonarr/Radarr/Plex integration.**  
No stranded `.tmp` files, no more import failures—just reliable automation.

---

## 🚀 Features

- **Priority-Based Transcoding:**  
  Flexible ordering: try iGPU (QSV), dGPU (NVENC), then fallback to local CPU (NAS), or any custom sequence.
- **Remote GPU Offload:**  
  Transcode on any Windows/Linux box with Intel or Nvidia GPU using SSH.
- **Automatic Fallback:**  
  If one method fails, script retries the next, always ensuring the job completes.
- **Orphan Recovery:**  
  If a valid `.tmp.mp4` is left behind (e.g., after a crash), script auto-recovers and promotes it.
- **Intelligent Validation:**  
  Ensures recovered files are playable and match the original's duration/codec before import.
- **Configurable Everything:**  
  All logic lives in `transcode.conf`. Edit without touching the main script.
- **Integrated Logging:**  
  Clean, timestamped, rotated logs for every job—plus an optional detailed recovery log.
- **Real-Time Progress Bar:**  
  Unified live spinner/percentage/ETA for all engines.
- **Anti-Hang Protection:**  
  Automatic stall detection and process termination prevents infinite hangs.
- **Notifications:**  
  Seamless Sonarr, Radarr, Plex, and Tautulli refreshes—now with auto-retry on failures.
- **One-Step Deployment:**  
  Drop-in for any SABnzbd install—no dependencies beyond ffmpeg/ssh.
- **Open Source & Easy to Extend!**

---

## 📦 Quick Install

1. **Copy Files**  
   Place `transcode-v4-priority.sh` and `transcode.conf` in your Sabnzbd `scripts` directory.
2. **Make Executable**
   ```bash
   chmod +x transcode-v4-priority.sh
   ```
3. **Configure**  
   Edit `transcode.conf`—set your transcoder order, enable/disable engines, and fill in SSH, API, and quality options.
4. **Assign in Sabnzbd**  
   In *Settings > Categories*, assign `transcode-v4-priority.sh` as the script for desired categories.

---

## 🗂️ File Structure

```
/your-sabnzbd-config/scripts/
├── transcode-v4-priority.sh   # Main logic script
├── transcode.conf             # Config file (your settings)
└── logs/                      # Logs and recovery logs (auto-created)
```

---

## ⚙️ Configuration: `transcode.conf`

### **Transcoder Priority & Control**
Define the order of transcoders to try. The script will attempt them in this sequence. If one fails or is disabled, it moves to the next.
Available options: `"remote_igpu"`, `"remote_dgpu"`, `"local_cpu"`
```sh
TRANSCODE_PRIORITY="remote_igpu remote_dgpu local_cpu"

# --- Individual Transcoder Settings ---
# Enable or disable each specific transcoder. Set to "true" or "false".
ENABLE_REMOTE_IGPU="true"   # Intel QSV on remote
ENABLE_REMOTE_DGPU="true"   # Nvidia NVENC on remote
ENABLE_LOCAL_CPU="true"     # Local (NAS) CPU fallback
```
> Set individual `ENABLE_...` flags to `"false"` to skip that engine.

### **Remote SSH Setup**
- `SSH_HOST`: IP/hostname of your GPU desktop (e.g. `"192.168.7.16"`)
- `SSH_USER`: Username on remote system
- `SSH_KEY`: Private key path (inside SABnzbd container—e.g. `/config/.ssh/id_rsa`)
- `SSH_PORT`: (usually `22`)

### **Encoding Quality (New Method)**

The new script offers two primary modes for controlling GPU encoding quality, set by `GPU_ENCODE_MODE`.

1.  **Constant Quality (`cqp`)** - *Recommended*
    This mode aims for a consistent visual quality level. The final file size will vary depending on the complexity of the source video.
    - `GPU_ENCODE_MODE="cqp"`
    - `GPU_CQ_LEVEL="22"`: The target quality level. Lower values mean higher quality and larger files. (Range: 1-51, Recommended: 20-30).

2.  **Variable Bitrate (`bitrate`)** - *Legacy*
    This mode aims for a predictable file size by targeting a specific bitrate.
    - `GPU_ENCODE_MODE="bitrate"`
    - `BITRATE_TARGET`, `BITRATE_MAX`, `BITRATE_BUFSIZE`: Tune for your network/TVs.

> **Note:** The `BITRATE_*` settings are only used if `GPU_ENCODE_MODE` is set to `"bitrate"`.

### **Advanced Encoder Settings**
- `RESOLUTION_MAX`: e.g. `1920x1080` for 1080p output
- `QSV_PRESET`: Preset for Intel QSV encoder (e.g. `slow`, `veryslow`). Slower means better quality.
- `NVENC_PRESET`: Preset for Nvidia NVENC encoder (e.g. `p1`-`p7`). `p1` is worst quality, `p7` is best. `p4` is a good starting point.

### **Media Server APIs**
- `SONARR_URL` / `SONARR_API_KEY`
- `RADARR_URL` / `RADARR_API_KEY`
- `PLEX_URL` / `PLEX_TOKEN` / `PLEX_SECTION_ID_TV` / `PLEX_SECTION_ID_MOVIES`
- `TAUTULLI_URL` / `TAUTULLI_API_KEY`
- `NOTIFICATION_DELAY_S`: Wait after Sonarr/Radarr before Plex scan (default: `30`)

### **Recovery & Logging**
- `ENABLE_TMP_RECOVERY="true"`: Enable auto-recovery of orphan `.tmp.mp4`
- `RECOVERY_LOG_FILE="recovery.log"`: Track every recovery event
- `VERBOSE_LOGGING="true"`: See even more details in main log (for debugging)
- `DEBUG_MODE="true"`: Ultra-verbose logging for deep troubleshooting.

---

## 🔐 SSH Key Authentication: Quick Start

1. **Generate SSH Key (on NAS/SAB host):**
   ```bash
   ssh-keygen -t ed25519 -C "sab-transcode"
   ```
   *(Accept defaults, creates `~/.ssh/id_ed25519`)*

2. **Copy Public Key to Remote:**
   ```bash
   ssh-copy-id -i ~/.ssh/id_ed25519.pub user@192.168.7.16
   ```
   *(Or manually append the key to `~/.ssh/authorized_keys` on remote)*

3. **Test SSH from NAS/SAB Container:**
   ```bash
   ssh -i /config/.ssh/id_ed25519 user@192.168.7.16 "echo success"
   ```
   - If you see `success`, it works!
   - No password prompt should appear.

4. **Set Key Path in Config:**
   ```sh
   SSH_KEY="/config/.ssh/id_ed25519"
   ```

---

## 🔄 How It Works (Step-by-Step)

1. **Script is triggered** by Sabnzbd post-processing.
2. **Largest video file** is detected, codecs probed.
3. **Transcode priority loop:**  
    - Tries engines in order: remote iGPU, then dGPU, then NAS CPU.
    - Each must be both in priority string and ENABLED.
    - If remote, SSH is tested for connectivity.
4. **Transcode runs:**  
    - Live progress bar in SAB (spinner, percent, ETA).
    - All stderr/stdout captured for diagnostics.
5. **Finalization:**
    - On success: Renames `.tmp.mp4` to `.mp4`, deletes original.
    - On error: If valid `.tmp.mp4` exists, promotes it automatically (with log entry!).
    - Validation uses `ffprobe`—file must be playable and duration within 2% of source.
6. **Notifications:**
    - Sonarr/Radarr are notified to import (with auto-retry).
    - After delay, Plex/Tautulli are notified to scan.
7. **Logs everything:**  
    - Unified logs in `logs/`, with old logs rotated and recovery events tracked.

---

## 🧰 Troubleshooting & FAQ

### **Q: Script leaves a `.tmp.mp4` and Sonarr won’t import?**
- **New logic:** Script will now *auto-promote* any valid orphan TMP file next run!
- If this still happens, check recovery log in `logs/recovery.log`.

### **Q: SSH connection fails or remote transcoder skipped?**
1. **Test manually:**
   ```bash
   ssh -v -i /config/.ssh/id_ed25519 user@192.168.7.16
   ```
2. **Common issues:**
   - Wrong SSH key path or permissions
   - User not allowed in `sshd_config`
   - SSH agent or known_hosts issue

3. **Resolution:**
   - Ensure user is in `Remote Desktop Users` or has permission to run ffmpeg
   - Check logs for “Skipping remote_xxx (disabled or host unreachable)”

### **Q: How do I check what transcoder is being used?**
- See `--- Starting Remote dGPU Transcode (NVENC) ---` or similar in the main job log.
- Task Manager on remote: Intel GPU (iGPU) or NVIDIA GPU (dGPU) usage should spike as expected.

### **Q: Progress bar isn’t updating?**
- Check logs for last “FFMPEG:” line.
- Possible ffmpeg crash, stalled pipe, or resource overload.
- **v4.4 Comprehensive Debugging:** Script now includes extensive debugging capabilities to identify root causes of hangs and command failures.

## 🔍 **Debugging Hangs and Connection Issues**

If your script is freezing or hanging during transcoding, follow these steps to identify the root cause:

### **Step 1: Enable Debug Mode**
Edit `transcode.conf` and set:
```bash
DEBUG_MODE="true"
```

**⚠️ WARNING:** Debug mode generates VERY verbose logs. Only enable when actively troubleshooting!

### **Step 2: What Debug Mode Captures**

When enabled, the script logs comprehensive information:

**Environment & Configuration:**
- Script version, shell environment, working directory
- Complete configuration variables and transcoder settings
- Priority order and enabled/disabled transcoders

**Video File Analysis:**
- File path, size, permissions, ownership details
- Complete ffprobe output with all stream information
- Container format, codecs, and audio configuration

**FFmpeg Command Construction:**
- All variables used in command building (presets, quality levels, resolution limits)
- Complete FFmpeg command string before SSH transmission
- Command length validation and parameter checking

**SSH Connection Monitoring:**
- Network diagnostics (ping, port connectivity, authentication tests)
- Remote system status (uptime, memory, load, existing GPU processes)
- Real-time connection monitoring with CPU/memory usage tracking
- Immediate error detection and early termination analysis

**Error Analysis:**
- Complete stderr capture from FFmpeg processes
- Exit codes and output file size analysis
- Stream mapping error detection and command validation

### **Step 3: Debug Log Examples**

Debug entries are clearly categorized:
```bash
2025-01-27 10:30:15 | DEBUG: === dGPU Command Construction Debug ===
2025-01-27 10:30:15 | DEBUG: GPU_ENCODE_MODE: 'cqp'
2025-01-27 10:30:15 | DEBUG: FFMPEG_CMD_REMOTE: 'ffmpeg -hide_banner...'
2025-01-27 10:30:15 | DEBUG: SSH_STATUS: Process 12345 exited quickly - checking for immediate errors
2025-01-27 10:30:15 | DEBUG: EARLY_ERROR: Stream map '' matches no streams
```

### **Step 4: Common Issues Identified by Debug Mode**

**"Stream map '' matches no streams" Error:**
- FFmpeg command construction failure
- Variable expansion issues in SSH transmission
- Solution: Check audio parameters and stream mapping logic

**SSH Connection Problems:**
- Authentication failures or network connectivity
- Remote system resource constraints
- Solution: Verify SSH keys and remote system availability

**Progress Stalls:**
- Network timeouts or SSH connection drops
- GPU driver issues or resource exhaustion
- Solution: Check connection stability and remote system resources

### **Step 2: Run a Test Job**
Process a video file and let it run (or hang). Debug mode will generate extensive logs including:
- **Network diagnostics** (ping, SSH connectivity, authentication)
- **Remote system info** (uptime, memory, load, GPU processes)
- **SSH connection monitoring** (CPU/memory usage, connection status)
- **Detailed progress tracking** (frame advancement, bitrate, timeouts)

### **Step 3: Analyze the Debug Logs**
Look for these key indicators in your logs:

**Network Issues:**
```
DEBUG: PING: 192.168.7.16 is NOT reachable
DEBUG: TCP: Port 22 on 192.168.7.16 is NOT accessible
DEBUG: SSH: Authentication failed or timeout
```

**Remote System Problems:**
```
DEBUG: REMOTE: MEMORY: Mem: 32G used, 0B available
DEBUG: REMOTE: LOAD: 15.2 8.3 4.1 (high load average)
DEBUG: REMOTE: GPU_PROCESSES: 10 (too many processes)
```

**Connection Monitoring:**
```
DEBUG: SSH_MONITOR: iGPU connection active for 300s (PID: 1234)
DEBUG: SSH_MONITOR: CPU: 0.0%, MEM: 0.1% (process not working)
```

**Progress Stalls:**
```
DEBUG: PROGRESS_TIMEOUT: No data for 5s (cycle 24, connection issues: 120)
DEBUG: STALL_DETECTED: Progress updates: 5000, Last frame: 62754, Last time: 2617s
```

### **Step 4: Identify Root Cause**
Based on the debug output:

- **Network Issues**: Check firewall, router, cable connections
- **SSH Problems**: Verify SSH key, user permissions, SSH service status
- **Remote System Overload**: Check memory usage, kill stuck processes, reboot remote machine
- **GPU Driver Issues**: Update GPU drivers, check for hardware problems
- **File System Issues**: Check disk space, file permissions, NFS/SMB mount problems

### **Step 5: Disable Debug Mode**
Once you've identified the issue, set:
```bash
DEBUG_MODE="false"
```

**Warning:** Debug mode generates very verbose logs and can impact performance. Only enable when troubleshooting.

---

### **Q: Sonarr/Radarr import fails after transcode?**
- Confirm `.mp4` exists (not just `.tmp.mp4`).
- Check that permissions are correct and SAB category matches import rule.
- Log will show API errors—retry is automatic.

### **Q: Need to force CPU/local-only mode?**
- In `transcode.conf`:
   ```sh
   ENABLE_REMOTE_IGPU="false"
   ENABLE_REMOTE_DGPU="false"
   ENABLE_LOCAL_CPU="true"
   TRANSCODE_PRIORITY="local_cpu"
   ```
- Restart SAB and requeue job.

---

## 📊 Monitoring, Dashboard, & Customization

- **All logs** are in `logs/`, rotated, timestamped, and human-readable.
- **Recovery log**: Tracks every TMP recovery event for forensic/QA.
- **For real-time dashboards:**  
  - [Tdarr](https://tdarr.io/) or [Unmanic](https://github.com/Unmanic/Unmanic) offer GUIs for transcode farms.
  - Or build your own with [Flask](https://flask.palletsprojects.com/) or [Grafana](https://grafana.com/) reading these logs.

---

## 📋 Version & Author

- **Author:** [KPKev](https://github.com/KPKev) & [Gemini] & [OpenAI 4.1 - Robust Recovery]
- **Version:** 4.4 (Comprehensive Debugging, May 2025)
- **License:** MIT / Open

---

## 🆘 Still Stuck?

- **Step 1:** Check the `logs/` directory for details.
- **Step 2:** Verify all config values in `transcode.conf`.
- **Step 3:** Test SSH from the NAS to the remote box.
- **Step 4:** Drop an issue or pull request on GitHub, or ping [KPKev](https://github.com/yourprofile).

---

> **Enjoy hands-free, bulletproof transcoding for your entire Plex/Sonarr/Radarr workflow!**
