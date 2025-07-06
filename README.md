# Sabnzbd Post-Processing Script: Priority-Based Transcoding

This is a powerful, single-file post-processing script for Sabnzbd that intelligently transcodes media files into a web-optimized MP4 format (H.264 video, AAC audio). It is designed for maximum flexibility and reliability, featuring a configurable priority system to ensure your media is always processed efficiently.

The script can use multiple transcoding engines and will attempt them in the order you specify, providing seamless, automatic fallback if one method fails or is unavailable.

## 🚀 Key Features

- **Configurable Transcoder Priority**: Define the exact order of transcoders to use (e.g., `remote_igpu remote_dgpu local_cpu`).
- **Multi-Engine Support**:
    - **Remote Intel iGPU (QSV)**: Offload transcoding to an Intel CPU with Quick Sync Video for fast, efficient hardware encoding.
    - **Remote NVIDIA dGPU (NVENC)**: Use a dedicated NVIDIA graphics card for the highest-speed hardware encoding.
    - **Local CPU (libx264)**: A highly compatible software-based fallback that runs directly on the Sabnzbd machine.
- **Independent Control**: Enable or disable each transcoder individually in the config file.
- **Automatic Fallback**: If a transcoder fails or is disabled, the script automatically moves to the next one in your priority list.
- **Unified Live Progress Reporting**: A universal progress reader provides a consistent, real-time progress bar in the Sabnzbd UI for *all* transcoding methods, including remote ones. It shows a live spinner, percentage, speed, and ETA.
- **Intelligent Analysis**: Uses `ffprobe` to analyze files and only transcodes what is necessary, copying compatible audio streams and skipping files that are already compliant.
- **Unified & Rotated Logging**: All output from the script and every `ffmpeg` process is captured in a single, timestamped log file for easy debugging. Logs are automatically rotated to save space.
- **Highly Configurable**: All behavior, from quality settings to server addresses, is controlled via a simple, clean `transcode.conf` file.
- **Media Server Integration**: Includes placeholders to automatically notify Sonarr, Radarr, and Plex after a successful transcode.

## 📋 Requirements

### System
- **Sabnzbd**: For post-processing integration.
- **FFmpeg & FFprobe**: Must be available in the Sabnzbd container's environment (for local CPU transcoding and media analysis).
- **SSH Client**: For connecting to remote transcoding machines.

### Remote Transcoder Machine(s)
- An Intel CPU with QSV support or an NVIDIA GPU with NVENC support.
- A running SSH server (like OpenSSH on Windows or Linux).
- A full installation of FFmpeg available in the system's PATH.
- Correctly configured SSH key-based authentication for passwordless login.

## 🛠️ Installation

1.  **Place Files**: Copy `transcode-v4-priority.sh` and `transcode.conf` into your Sabnzbd `scripts` directory.
2.  **Make Executable**:
    ```bash
    chmod +x transcode-v4-priority.sh
    ```
3.  **Configure**: Meticulously edit `transcode.conf` with your specific settings (SSH details, transcoder priority, etc.).
4.  **Setup in Sabnzbd**: In Sabnzbd's **Settings > Categories**, assign `transcode-v4-priority.sh` to the categories you want to process.

## 📁 File Structure

All files should be placed in your Sabnzbd `scripts` directory.

```
/your-sabnzbd-config/scripts/
├── transcode-v4-priority.sh      # The main, executable script.
├── transcode.conf                # All user settings go here.
└── logs/                         # All log files are created here automatically.
```

## ⚙️ Configuration (`transcode.conf`)

This file controls all aspects of the script.

### Transcoder Priority & Control
This is the core of the new system.

- `TRANSCODE_PRIORITY`: A space-separated string defining the order to attempt transcoding.
  - *Example*: `"remote_igpu remote_dgpu local_cpu"`
- `ENABLE_REMOTE_IGPU`: Set to `"true"` or `"false"` to enable/disable the Intel QSV transcoder.
- `ENABLE_REMOTE_DGPU`: Set to `"true"` or `"false"` to enable/disable the NVIDIA NVENC transcoder.
- `ENABLE_LOCAL_CPU`: Set to `"true"` or `"false"` to enable/disable the local CPU transcoder.

### SSH & Remote Settings
- `SSH_HOST`: The IP address or hostname of your remote transcoding machine.
- `SSH_PORT`: The SSH port (default: `22`).
- `SSH_USER`: The username for SSH login.
- `SSH_KEY`: The absolute path *inside the Sabnzbd container* to the SSH private key.

### Encoding Quality
- `BITRATE_TARGET` / `BITRATE_MAX`: The average and peak bitrate for the video stream.
- `RESOLUTION_MAX`: The maximum output resolution (e.g., `1920x1080`). Videos will be downscaled to fit.
- `QSV_PRESET`: The quality preset for the Intel QSV encoder (e.g., `slow`). Slower presets yield better quality.
- `NVENC_PRESET`: The quality preset for the NVIDIA NVENC encoder (e.g., `p4`). Lower numbers (`p1-p4`) yield better quality.

### Logging
- `LOG_KEEP`: The number of old log files to keep during rotation (default: `10`).

### Media Server Integration
- `SONARR_URL` / `SONARR_API_KEY`: Details for your Sonarr instance.
- `RADARR_URL` / `RADARR_API_KEY`: Details for your Radarr instance.
- `PLEX_URL` / `PLEX_TOKEN`: Details for your Plex Media Server.
- `PLEX_SECTION_ID_TV` / `PLEX_SECTION_ID_MOVIES`: The specific library section IDs in Plex to refresh for TV shows and movies.
- `TAUTULLI_URL` / `TAUTULLI_API_KEY`: Optional details for your Tautulli instance to trigger a library sync.
- `NOTIFICATION_DELAY_S`: How many seconds to wait after telling Sonarr/Radarr to import before telling Plex/Tautulli to scan. This prevents a race condition where Plex scans before the file is moved.

## 🔄 How It Works

1.  **Analysis**: The script is triggered by Sabnzbd and finds the largest video file in the completed download. It uses `ffprobe` to check its container, video codec, and audio streams.
2.  **Decision**: The script determines if transcoding is needed based on the file format.
3.  **Priority Loop**:
    - The script iterates through the transcoder names in your `TRANSCODE_PRIORITY` string.
    - For each transcoder, it checks if it is enabled (e.g., `ENABLE_REMOTE_DGPU="true"`).
    - For remote transcoders, it first verifies it can connect to the `SSH_HOST`.
    - It executes the first available and enabled transcoder.
4.  **Execution & Fallback**:
    - If the chosen transcoder runs and finishes successfully, the script moves on to finalizing the file. The loop is broken.
    - If the transcoder fails, the script logs the failure and automatically proceeds to the *next* transcoder in the priority list.
5.  **Progress Monitoring**: While `ffmpeg` runs (locally or remotely), a universal progress loop reads its status, providing a consistent, real-time status line in the Sabnzbd UI.
6.  **Finalization & Notification**:
    - After a successful transcode, the temporary file is renamed and the original is deleted.
    - The script then notifies the appropriate service (Sonarr for TV, Radarr for movies) to import the new file.
    - It waits for the configured delay (`NOTIFICATION_DELAY_S`).
    - Finally, it tells Plex and Tautulli to scan their libraries for the new content.
7.  **Failure**: If all enabled transcoders in the priority list fail, the script exits and leaves the original file intact.

## 🐛 Troubleshooting

The first step is **always to check the log file**. The unified log in the `logs/` directory contains the script's decisions and the full, detailed output from `ffmpeg`, including any errors.

1.  **A Transcoder Fails**: Look at the `FFMPEG:` lines in the log file. The error message from `ffmpeg` will be there (e.g., "No option name near...", "Cannot load model...", "Permission denied").
2.  **All Remote Transcoders are Skipped**: Check the "Skipping..." messages in the log.
    - If it says `(disabled)`, check the `ENABLE_...` flags in `transcode.conf`.
    - If it says `(host unreachable)`, there is an SSH connection problem. Test your connection manually from inside the Sabnzbd container: `ssh -v -p [PORT] -i [KEY_PATH] [USER]@[HOST]`.
3.  **Progress Bar Issues**: The progress bar relies on reading `ffmpeg`'s output. If it freezes, the `ffmpeg` process has likely stalled or crashed. Check the log for the last `FFMPEG:` message.

---
**Author**: Gemini & KPKev
**Version**: 4.0 (Priority)

## 📝 Version History

### v6.0 (Current)
- Complete rewrite of transcoding logic
- Fixed execution order and process management
- Improved remote command stability
- Enhanced progress monitoring
- Better error handling and cleanup

## 🤝 Contributing

1. Fork the repository
2. Create a feature branch
3. Make your changes
4. Test thoroughly
5. Submit a pull request

## 📄 License

This project is open source. Feel free to modify and distribute according to your needs.

## ⚠️ Disclaimer

This script is designed for personal use with legally obtained media content. Ensure you comply with all applicable laws and licensing requirements in your jurisdiction.

## 🆘 Support

For issues and questions:
1. Check the troubleshooting section
2. Review log files for error details
3. Verify all configuration settings
4. Test SSH connectivity manually

---

**Author**: Gemini & KPKev
**Version**: 6.0 (Robust)  
**Last Updated**: 2025 