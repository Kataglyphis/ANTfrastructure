import re

with open('linux/scripts/03-media/gstreamer/common/setup-gstreamer.sh', 'r') as f:
    content = f.read()

content = content.replace("      csound csound-utils libcsound64 libcsound64-dev libcsound-dev pd-csound || true\n", "")

with open('linux/scripts/03-media/gstreamer/common/setup-gstreamer.sh', 'w') as f:
    f.write(content)
