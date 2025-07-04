# GPU-Accelerated Transcoding Script for Sabnzbd

A robust post-processing script for Sabnzbd that automatically transcodes downloaded media files to MP4 format using GPU acceleration via remote SSH. Designed for seamless integration with Sonarr, Radarr, and Plex media servers.

## 🚀 Features

- **GPU Acceleration**: Utilizes NVIDIA NVENC encoder via SSH for fast transcoding
- **Automatic Format Detection**: Only transcodes files that need conversion
- **Plex Direct-Play Optimization**: Ensures compatibility with Plex streaming
- **Real-time Progress Monitoring**: Live transcoding progress with ETA
- **Automatic Library Refresh**: Triggers Plex library updates after processing
- **Sonarr/Radarr Integration**: Automatic notifications to media managers
- **Configurable Quality Settings**: Adjustable bitrates, resolution, and encoding presets
- **Comprehensive Logging**: Detailed logging with rotation and archiving

## 📋 Requirements

### System Requirements
- **Sabnzbd**: For post-processing integration
- **FFmpeg**: With NVENC support (on remote GPU machine)
- **SSH Access**: To remote Windows machine with NVIDIA GPU
- **Linux Container**: Running Sabnzbd (Docker recommended)

### Remote GPU Machine (Windows)
- NVIDIA GPU with NVENC support
- FFmpeg with NVENC enabled
- SSH server (OpenSSH or similar)
- Proper SSH key authentication

## 🛠️ Installation

1. **Clone or download** the script files to your Sabnzbd container
2. **Make the script executable**:
   ```bash
   chmod +x transcode-to-mp4-with-gpu.sh
   ```
3. **Configure SSH access** to your GPU machine
4. **Edit `transcode.conf`** with your specific settings
5. **Configure Sabnzbd** to use this script for post-processing

## ⚙️ Configuration

### SSH Configuration
```bash
SSH_HOST="192.168.7.16"    # Your GPU machine IP
SSH_PORT="22"              # SSH port
SSH_USER="your_username"   # SSH username
SSH_KEY="/config/.ssh/id_rsa"  # Private key path
```

### Encoding Settings
```bash
BITRATE_TARGET="6M"        # Average bitrate target
BITRATE_MAX="8M"           # Peak bitrate limit
RESOLUTION_MAX="1920x1080" # Maximum output resolution
NVENC_PRESET="p4"          # Quality preset (p4 = high quality)
```

### Media Server Integration
```bash
SONARR_URL="http://sonarr:8989"
SONARR_API_KEY="your_sonarr_api_key"
RADARR_URL="http://radarr:7878"
RADARR_API_KEY="your_radarr_api_key"
PLEX_URL="http://plex:32400"
PLEX_TOKEN="your_plex_token"
```

## 🔧 Sabnzbd Setup

1. **Navigate to Sabnzbd Settings** → **Categories**
2. **Add/Edit a category** (e.g., "movies", "tv")
3. **Set Script** to: `transcode-to-mp4-with-gpu.sh`
4. **Configure categories** for different content types:
   - `movies` or `radarr` for movies
   - `tv`, `sonarr`, or `series` for TV shows

## 📁 File Structure

```
transcode-to-mp4-script/
├── transcode-to-mp4-with-gpu.sh  # Main transcoding script
├── transcode.conf                # Configuration file
└── README.md                     # This documentation
```

## 🔄 How It Works

### 1. File Analysis
- Scans downloaded content for video files
- Detects container format, video codec, and audio codec
- Determines if transcoding is necessary

### 2. Transcoding Decision
**Files are transcoded if they are NOT:**
- MP4 container format
- AAC audio codec
- 2-channel stereo audio

### 3. GPU Processing
- **Connection Check**: Verifies SSH connectivity to the remote host before starting.
- Streams video file to remote GPU machine via SSH
- Uses NVIDIA NVENC encoder for hardware acceleration
- Applies quality settings for Plex Direct-Play compatibility
- Monitors progress in real-time

### 4. Post-Processing
- Optimizes container for streaming (+faststart)
- Removes original file after successful conversion
- Triggers media server library refresh
- Sends completion notifications

## 📊 Supported Formats

### Input Formats
- **Containers**: MKV, MP4, AVI, MOV
- **Video Codecs**: Any (H.264, H.265, etc.)
- **Audio Codecs**: Any (AAC, AC3, DTS, etc.)

### Output Format
- **Container**: MP4
- **Video**: H.264 High Profile Level 4.0
- **Audio**: AAC 2-channel stereo
- **Resolution**: Up to 1920x1080 (configurable)
- **Bitrate**: 6 Mbps target, 8 Mbps max

## 🐛 Troubleshooting

### Common Issues

**SSH Connection Fails**
- Verify SSH key permissions (600)
- Check network connectivity
- Ensure SSH server is running on GPU machine

**Transcoding Fails**
- Check FFmpeg installation on GPU machine
- Verify NVIDIA drivers and NVENC support
- Review log files for specific error messages

**Plex Not Refreshing**
- Verify Plex token is correct
- Check Plex section IDs match your libraries
- Ensure Plex server is accessible

### Log Files
- **Location**: `/config/logs/transcode_script.log`
- **Rotation**: Automatic after 1000 lines
- **Archives**: Keeps last 5 rotated files

## 🔧 Advanced Configuration

### Custom Quality Presets
Available NVENC presets:
- `p1` - Fastest (lower quality)
- `p2` - Faster
- `p3` - Fast
- `p4` - Medium (recommended)
- `p5` - Slow
- `p6` - Slower
- `p7` - Slowest (highest quality)

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