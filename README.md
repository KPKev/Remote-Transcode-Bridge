# Unified GPU & CPU Transcoding Script for Sabnzbd

A robust, single-file post-processing script for Sabnzbd that intelligently transcodes media to a web-optimized MP4 format. It prioritizes a remote NVIDIA GPU for maximum speed but automatically falls back to local CPU transcoding if the GPU is unavailable, ensuring your media always gets processed.

## 🚀 Key Features

- **Hybrid Transcoding**: Prioritizes remote NVIDIA GPU (NVENC) via SSH and seamlessly falls back to local CPU (`libx264`) if needed.
- **Intelligent Fallback**: Automatically detects if the remote GPU host is unreachable and switches to CPU mode.
- **Force CPU Option**: A flag in `transcode.conf` allows you to force CPU transcoding for testing or maintenance.
- **Real-time Progress**: A live, responsive progress bar with a "spinner" shows that transcoding is active, even during slow CPU operations.
- **Automatic Format Detection**: Only transcodes files that aren't already in a web-optimized MP4 format.
- **Media Server Integration**: Built-in, automatic library refresh notifications for Plex, Sonarr, and Radarr.
- **Highly Configurable**: A clean `transcode.conf` file controls all quality, connection, and behavior settings.
- **Comprehensive Logging**: Creates detailed, timestamped logs for both the main script and the `ffmpeg` process, with automatic rotation.

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

## ⚙️ Configuration (`transcode.conf`)

All script behavior is controlled by `transcode.conf`.

<details>
<summary><strong>SSH / Remote GPU Configuration</strong></summary>

```bash
# IP or hostname of Windows box running NVENC
SSH_HOST="192.168.7.16"
# SSH port (22 by default)
SSH_PORT="22"
# SSH login user
SSH_USER="12227"
# Private key path inside container
SSH_KEY="/config/.ssh/id_rsa"
```
</details>

<details>
<summary><strong>Encoding & Quality Settings</strong></summary>

```bash
# Average bitrate target (VBR-HQ) for GPU
BITRATE_TARGET="6M"
# Peak maxrate for GPU
BITRATE_MAX="8M"
# Rate-control buffer for GPU
BITRATE_BUFSIZE="16M"
# Max output resolution (widthxheight)
RESOLUTION_MAX="1920x1080"
# Quality preset for h264_nvenc (p1-p7, p4 is a good balance)
NVENC_PRESET="p4"
```
</details>

<details>
<summary><strong>Media Server Integration</strong></summary>

```bash
SONARR_URL="http://sonarr:8989"
SONARR_API_KEY="your_api_key"
RADARR_URL="http://radarr:7878"
RADARR_API_KEY="your_api_key"
PLEX_URL="http://plex:32400"
PLEX_TOKEN="your_plex_token"
PLEX_SECTION_ID_TV="2"
PLEX_SECTION_ID_MOVIES="1"
```
</details>

<details>
<summary><strong>Transcoding Rules & Behavior</strong></summary>

```bash
# Set to "true" to skip the GPU check and force local CPU transcoding.
# Default: false
FORCE_CPU_TRANSCODE="true"

# (Currently Ineffective) Set to "true" to attempt VAAPI hardware
# acceleration on the local CPU (e.g., on a Synology NAS).
# Requires docker access to /dev/dri.
# Default: false
ENABLE_CPU_HW_ACCEL="true"

# A space-separated list of video codecs to transcode.
SOURCE_CODECS="h265 hevc"

# Set to "true" to transcode Matroska (.mkv) files.
CONVERT_MKV="true"

# Any video file smaller than this size (in bytes) will be skipped.
# Default is 100MB (104857600).
MIN_SIZE="104857600"
```
</details>


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

## 📁 File Structure

```
/sabnzbd/scripts/
├── transcode-to-mp4-with-gpu.sh  # The main, unified script
├── transcode.conf                # All user configuration
├── logs/                         # Directory for log files
│   ├── ..._main.log              # Main script activity log
│   └── ..._cpu.log               # Log file for ffmpeg CPU process
└── .gitignore                    # Prevents logs from being committed
```

## 🐛 Troubleshooting

- **Frozen Progress Bar**: If the progress bar freezes, check the main log file (`..._main.log`) in the `logs` directory. The progress reader may have timed out (default is 5 minutes).
- **Transcoding Fails**: Check the `ffmpeg` log (`..._cpu.log` or a future `..._gpu.log`). This contains the direct, unfiltered output from the `ffmpeg` command and will show any encoding errors.
- **SSH Connection Fails**: Test your SSH connection manually from within the Sabnzbd container to ensure keys are set up correctly and the host is reachable. `ssh -v -p [PORT] [USER]@[HOST]`.
- **Permission Denied**: Ensure the script has execute permissions (`chmod +x`). Also, ensure the user running Sabnzbd has permission to write to the `logs` directory and the media output directories.

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