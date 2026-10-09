# shellcheck shell=sh
# Homebrew on PATH once juniper-firstboot has extracted it.
if [ -x /home/linuxbrew/.linuxbrew/bin/brew ]; then
  eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)"
fi
