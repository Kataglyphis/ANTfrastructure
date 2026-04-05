import re

with open('linux/scripts/03-media/gstreamer/common/setup-gstreamer.sh', 'r') as f:
    content = f.read()

# We know the dangling lines from the previous review. We can just replace them with empty string.
bad_chunks = [
    """  build-essential g++ \\
  libc++-dev libc++abi-dev \\
  flex bison \\
  libglib2.0-dev libgirepository1.0-dev gir1.2-gstreamer-1.0 \\
  libcairo2-dev \\
  libjson-glib-dev python3-gi python3-gi-cairo python-gi-dev \\
  libgsl-dev libdw-dev libnsl-dev gobject-introspection \\
  libgtk-4-dev""",
    
    """  libasound2-dev libpulse-dev libjack-dev libpipewire-0.3-dev \\
  libsndfile1-dev libsamplerate0-dev""",

    """  libv4l-dev libusb-1.0-0-dev libdc1394-dev libraw1394-dev \\
  libcdio-dev libcdparanoia-dev""",

    """  libx11-dev libxext-dev libxfixes-dev libxdamage-dev libxrandr-dev libxv-dev \\
  libwayland-dev wayland-protocols libxkbcommon-dev \\
  libgl1-mesa-dev libegl1-mesa-dev libgles2-mesa-dev libglu1-mesa-dev \\
  libdrm-dev libgbm-dev libva-dev \\
  libudev-dev""",

    """  libjpeg-dev libpng-dev libtiff-dev libwebp-dev""",

    """  libogg-dev libvorbis-dev libtheora-dev libopus-dev libflac-dev \\
  libmpg123-dev libmp3lame-dev libtwolame-dev libspeex-dev libspeexdsp-dev \\
  libwavpack-dev libgsm1-dev""",

    """  libvpx-dev libaom-dev libdav1d-dev \\
  libx264-dev libx265-dev libopenh264-dev \\
  libsvtav1-dev || true""",

    """  libavcodec-dev libavformat-dev libavfilter-dev libavutil-dev \\
  libswscale-dev libswresample-dev""",

    """  libsoup-3.0-dev libcurl4-openssl-dev libxml2-dev \\
  zlib1g-dev libbz2-dev liblzma-dev libzstd-dev \\
  libsrtp2-dev libnice-dev libssl-dev libusrsctp-dev || true"""
]

for chunk in bad_chunks:
    content = content.replace(chunk, "")

content = content.replace("if command -v \n", "if false; then\n")
content = content.replace("run_as_root \n", "")

with open('linux/scripts/03-media/gstreamer/common/setup-gstreamer.sh', 'w') as f:
    f.write(content)
