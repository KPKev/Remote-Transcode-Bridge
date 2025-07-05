# Unified GPU & CPU Transcoding Script for Sabnzbd

This is a robust, single-file post-processing script for Sabnzbd that intelligently transcodes media files into a web-optimized MP4 format. It is designed for maximum efficiency and reliability, prioritizing a high-speed remote NVIDIA GPU for transcoding while providing a seamless, automatic fallback to local CPU processing if the GPU is unavailable.

This ensures that your media is always processed and ready for your library, regardless of the status of your remote hardware.

## 🚀 Key Features

- **Hybrid Transcoding Logic**: Prioritizes remote NVIDIA GPU (NVENC) via SSH for maximum speed.
- **Automatic CPU Fallback**: If the remote GPU host is unreachable (or disabled), the script automatically switches to the local CPU (`libx264`) to complete the job. No intervention required.
- **Live Progress Reporting**: The script provides a real-time progress bar in the Sabnzbd UI, complete with a "spinner" to show activity, percentage complete, current speed (e.g., `2.5x`), and an estimated time remaining (ETA).
- **Intelligent Transcoding**: Uses `ffprobe` to analyze files and only transcodes what is necessary, saving resources by skipping files that are already in a compliant format.
- **Media Server Integration**: After a successful transcode, it automatically sends notifications to Sonarr, Radarr, and Plex to trigger library scans and updates.
- **Detailed, Rotated Logging**: Creates separate, timestamped log files for the main script and the `ffmpeg` process, and automatically rotates them to save space.
- **Highly Configurable**: All behavior, from quality settings to server addresses, is controlled via a simple, clean `transcode.conf` file.

## 📋 Requirements

### System
- **Sabnzbd**: For post-processing integration.
- **FFmpeg**: Must be available in the Sabnzbd container's environment.
- **`stdbuf`**: Required for real-time progress updates (part of `coreutils`).
- **SSH Client**: For connecting to the remote GPU machine.

### Remote GPU Machine (Optional, for GPU acceleration)
- An NVIDIA GPU with NVENC support.
- A running SSH server (like OpenSSH).
- FFmpeg with NVENC enabled.
- Correctly configured SSH key-based authentication.

## 🛠️ Installation

1.  **Place Files**: Copy `transcode-to-mp4-with-gpu.sh` and `transcode.conf` into your Sabnzbd `scripts` directory.
2.  **Make Executable**:
    ```bash
    chmod +x transcode-to-mp4-with-gpu.sh
    ```
3.  **Configure**: Edit `transcode.conf` with your specific settings (SSH, media servers, etc.).
4.  **Setup in Sabnzbd**: In Sabnzbd's settings, point your categories to `transcode-to-mp4-with-gpu.sh`.

## 📁 File Structure

All files should be placed in your Sabnzbd `scripts` directory.

```
/your-sabnzbd-config/scripts/
├── transcode-to-mp4-with-gpu.sh  # The main, executable script.
├── transcode.conf                # All user settings go here.
└── logs/                         # All log files are created here automatically.
```

## ⚙️ Configuration (`transcode.conf`)

This file controls all aspects of the script. Any variable set here will override the script's internal defaults.

### Remote GPU Settings
These settings are for connecting to the remote machine that will perform the high-speed NVENC transcoding.

- `SSH_HOST`: The IP address or hostname of your GPU machine.
- `SSH_PORT`: The SSH port on the remote machine (default: `22`).
- `SSH_USER`: The username to log in with.
- `SSH_KEY`: The absolute path *inside the Sabnzbd container* to the SSH private key for authentication.

### Transcoding Quality
Control the output quality of the transcoded files.

- `BITRATE_TARGET`: The target average bitrate for GPU transcodes (e.g., `6M`).
- `BITRATE_MAX`: The maximum allowed peak bitrate for GPU transcodes (e.g., `8M`).
- `BITRATE_BUFSIZE`: The video buffer verifier size for GPU transcodes (e.g., `16M`).
- `RESOLUTION_MAX`: The maximum output resolution (e.g., `1920x1080`). Videos with a higher resolution will be downscaled.
- `NVENC_PRESET`: The quality preset for the NVIDIA encoder. Ranges from `p1` (fastest, lowest quality) to `p7` (slowest, highest quality). `p4` is a good balance.

### Transcoding Rules
Define which files the script should process.

- `SOURCE_CODECS`: A space-separated list of video codecs that should trigger a transcode (e.g., `"h265 hevc"`).
- `CONVERT_MKV`: Set to `true` to transcode `.mkv` files, `false` to ignore them.
- `MIN_SIZE`: The minimum file size in bytes to consider for transcoding. This is useful for ignoring sample files (default: `104857600`, i.e., 100MB).

### Media Server Integration
Settings for notifying your media servers after a transcode is complete.

- `SONARR_URL` / `SONARR_API_KEY`: Your Sonarr instance details.
- `RADARR_URL` / `RADARR_API_KEY`: Your Radarr instance details.
- `PLEX_URL` / `PLEX_TOKEN`: Your Plex server details.
- `PLEX_SECTION_ID_TV` / `PLEX_SECTION_ID_MOVIES`: The specific library section keys in Plex that should be refreshed.

### Logging
- `LOG_KEEP`: The number of old log files to keep during rotation (default: `10`).

### Advanced / Testing
- `FORCE_CPU_TRANSCODE`: Set to `true` to completely bypass the GPU check and force all transcoding to happen on the local CPU. Useful for testing.
- `ENABLE_CPU_HW_ACCEL`: **(Experimental)** Set to `true` to attempt using VAAPI hardware acceleration on the local CPU (e.g., for Intel QSV on a Synology NAS). This is currently disabled in the main script due to driver compatibility issues but can be re-enabled for testing.

## 🔄 How It Works

1.  **Analysis**: The script is triggered by Sabnzbd and finds the largest video file in the completed download. It uses `ffprobe` to check its container, video codec, and audio codec.
2.  **Decision**: The script transcodes the file if it's not already a compliant `h264/aac` MP4 file.
3.  **Transcode Path Selection**:
    - It checks the `FORCE_CPU_TRANSCODE` flag. If `true`, it skips to the CPU path.
    - It attempts to connect to the `SSH_HOST`. If the host is unreachable, it logs the failure and automatically switches to the CPU path.
    - If the connection is successful, it uses the GPU path.
4.  **Execution**:
    - **GPU Path**: Streams the video file via SSH to the remote machine, where `ffmpeg` performs a high-speed NVENC transcode.
    - **CPU Path**: Executes `ffmpeg` locally using the `libx264` software encoder, which is slower but highly compatible.
5.  **Progress Monitoring**: While `ffmpeg` runs, a progress loop reads its output in real-time, printing a status line with a spinner, percentage, speed, and ETA to the Sabnzbd UI.
6.  **Cleanup & Notification**: After a successful transcode, the original file is deleted, and the script sends API calls to Sonarr, Radarr, and Plex to trigger library scans.

## 📜 Logging System Explained

The script features a robust logging system to make troubleshooting easy.

- **Location**: All logs are created in the `logs` sub-directory.
- **File Naming**: Log files are named using the format: `YYYY-MM-DD_HH-MM-SS_Job-Name_type.log`.
  - `..._main.log`: Contains the high-level output of the script itself—what decisions it made, when it started/stopped, and any major errors.
  - `..._cpu.log` or `..._gpu.log`: Contains the raw, unfiltered output from the `ffmpeg` process. If an encode fails, the specific error will be in this file.
- **Log Rotation**: To prevent logs from filling up your disk, the script automatically deletes the oldest log files, keeping only the number specified by `LOG_KEEP` in `transcode.conf`.

## 📊 Progress Reporting

To provide real-time feedback, the script reports progress directly to the Sabnzbd UI.

- **Live Spinner**: A spinning character `[|]`, `[/]`, `[-]`, `[\]` updates continuously, providing a "heartbeat" to show that the script is alive and receiving data, even if the percentage hasn't changed.
- **Real-time Updates**: The script uses `stdbuf` to force line-buffering on `ffmpeg`'s output. This ensures that progress updates are displayed the instant they are available, rather than waiting for a buffer to fill, which results in a much smoother and more responsive ETA calculation.

## 🐛 Troubleshooting

1.  **Transcode Fails or Stalls**:
    - **Check the `ffmpeg` log first (`..._cpu.log` or `..._gpu.log`)**. This is the most important step. It contains the raw error message from `ffmpeg` (e.g., "Error creating a MFX session," "No such file or directory," "Permission denied").
    - **Check the `main` log (`..._main.log`)**. This will tell you which decisions the script made and if it encountered a script-level error (like being unable to find a video file).

2.  **Progress Bar Freezes**:
    - The script's progress reader has a long timeout (300 seconds). If it freezes, it's very likely that the `ffmpeg` process itself has stalled or crashed. Check the `ffmpeg` log for errors.

3.  **Permission Denied Errors**:
    - Ensure the script has execute permissions: `chmod +x transcode-to-mp4-with-gpu.sh`.
    - Ensure the user running Sabnzbd has read/write permissions for the download directory and the `scripts/logs` directory.

4.  **SSH Connection Issues**:
    - From inside your Sabnzbd container, run a manual SSH command to test the connection: `ssh -v -p [PORT] -i [KEY_PATH] [USER]@[HOST]`. The `-v` (verbose) flag will give you detailed output to diagnose authentication or connectivity problems.

5.  **File Is Skipped (Not Transcoded)**:
    - Check the `main` log. It will explicitly state why a file was skipped.
    - Verify your rules in `transcode.conf`. Is the file's codec in `SOURCE_CODECS`? Is the file larger than `MIN_SIZE`? Is `CONVERT_MKV` set to `true`?

---
**Author**: Gemini & KPKev
**Version**: 3.0 (Unified)

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

**Author**: Gemini  
**Version**: 6.0 (Robust)  
**Last Updated**: 2024 