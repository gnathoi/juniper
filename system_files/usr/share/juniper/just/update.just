# Download the latest Juniper image and reboot into it now
update:
    sudo bootc upgrade
    sudo /usr/libexec/juniper/apply-update

# Show the update schedule, set the reboot window (HH:MM local time) or turn it off
update-schedule time="":
    sudo /usr/libexec/juniper/update-schedule {{ quote(time) }}

# Switch to another image (e.g. ghcr.io/you/sensor-box:latest) and reboot into it now
switch image:
    #!/usr/bin/bash
    set -euo pipefail
    [[ -n {{ quote(image) }} ]] || { echo "usage: ujust switch IMAGE" >&2; exit 2; }
    sudo bootc switch {{ quote(image) }}
    sudo /usr/libexec/juniper/apply-update
