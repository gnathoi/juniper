# Download the latest Juniper image and reboot into it now
update:
    sudo bootc upgrade
    sudo /usr/libexec/juniper/apply-update

# Show the update schedule, set the reboot window (HH:MM local time) or turn it off
update-schedule time="":
    sudo /usr/libexec/juniper/update-schedule {{ quote(time) }}
