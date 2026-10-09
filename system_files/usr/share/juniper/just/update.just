# Download the latest Juniper image and reboot into it now
update:
    sudo bootc upgrade
    sudo /usr/libexec/juniper/apply-update

# Show the schedule, or set the reboot window: `tue 04:00`, `daily 03:30`, `05:00` (keep day), `off`
update-schedule day_or_time="" time="":
    sudo /usr/libexec/juniper/update-schedule {{ if day_or_time == "" { "" } else { quote(day_or_time) } }} {{ if time == "" { "" } else { quote(time) } }}

# Switch to another image (e.g. ghcr.io/you/sensor-box:latest) and reboot into it now
switch image:
    #!/usr/bin/bash
    set -euo pipefail
    [[ -n {{ quote(image) }} ]] || { echo "usage: ujust switch IMAGE" >&2; exit 2; }
    sudo bootc switch {{ quote(image) }}
    sudo /usr/libexec/juniper/apply-update
