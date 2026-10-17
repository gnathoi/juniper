# Download the latest Juniper image and reboot into it now
update:
    sudo /usr/libexec/juniper/bootc-run upgrade
    sudo /usr/libexec/juniper/apply-update

# Show the schedule, or set the reboot window: `tue 04:00`, `daily 03:30`, `05:00` (keep day), `off`
update-schedule day_or_time="" time="":
    sudo /usr/libexec/juniper/update-schedule {{ if day_or_time == "" { "" } else { quote(day_or_time) } }} {{ if time == "" { "" } else { quote(time) } }}

# Switch to another image (e.g. ghcr.io/you/sensor-box:latest) and reboot into it now (--force: skip the encrypted-root check)
switch image *flags:
    /usr/libexec/juniper/switch-image {{ quote(image) }} {{ flags }}

# List images that need a signature, or require one for NAMESPACE (ghcr.io/you ~/cosign.pub)
trust-images namespace="" pubkey="":
    {{ if namespace == "" { "" } else { "sudo" } }} /usr/libexec/juniper/trust-images {{ if namespace == "" { "" } else { quote(namespace) } }} {{ if pubkey == "" { "" } else { quote(pubkey) } }}

# Stop requiring a signature for NAMESPACE (not Juniper's own)
untrust-images namespace:
    sudo /usr/libexec/juniper/trust-images --remove {{ quote(namespace) }}

# Forget failed update attempts, so a held update is tried again (it may fail again)
update-unhold:
    sudo /usr/libexec/juniper/update-unhold
