
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

### **Transcoder Priority**
Define the order as a space-separated string:
```sh
TRANSCODE_PRIORITY="remote_igpu remote_dgpu local_cpu"
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

### **Encoding Settings**
- `BITRATE_TARGET`, `BITRATE_MAX`, `BITRATE_BUFSIZE`: Tune for your network/TVs
- `RESOLUTION_MAX`: e.g. `1920x1080` for 1080p output
- `QSV_PRESET`, `NVENC_PRESET`: e.g. `slow`, `p4` (see script for more)

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
- **v4.3 Enhanced Stall Detection:** Script now tracks actual progress advancement (time/frames) and kills hung processes after 2 minutes of no progress.
- Added timeout wrapper (2 hours max) and improved SSH connection handling.
- Check logs for "ERROR: FFmpeg appears to be stalled" message.
- Common causes: Network issues, SSH connection drops, GPU driver problems.

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
- **Version:** 4.3 (Enhanced Stall Detection, July 2025)
- **License:** MIT / Open

---

## 🆘 Still Stuck?

- **Step 1:** Check the `logs/` directory for details.
- **Step 2:** Verify all config values in `transcode.conf`.
- **Step 3:** Test SSH from the NAS to the remote box.
- **Step 4:** Drop an issue or pull request on GitHub, or ping [KPKev](https://github.com/yourprofile).

---

> **Enjoy hands-free, bulletproof transcoding for your entire Plex/Sonarr/Radarr workflow!**
