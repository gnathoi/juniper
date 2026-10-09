# shellcheck shell=sh
# Juniper login banner for interactive shells; `ujust toggle-motd` turns it off per user.
case $- in
  *i*)
    if [ -z "${JUNIPER_MOTD_SHOWN:-}" ] && [ ! -e "$HOME/.config/juniper/no-motd" ]; then
      export JUNIPER_MOTD_SHOWN=1
      /usr/libexec/juniper/motd
    fi
    ;;
esac
