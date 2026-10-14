# shellcheck shell=bash
# Juniper's interactive bash: fzf keys (Ctrl-T, Alt-C), atuin history search (Ctrl-R), zoxide (z),
# carapace completions and a starship prompt. Each hooks in only once its Brewfile tool is
# installed (first login); `ujust toggle-shell` turns them all off per user.
if [ -n "${BASH_VERSION:-}" ] && [[ $- == *i* && ${TERM:-dumb} != dumb && -z ${__juniper_shell:-} &&
  ! -e $HOME/.config/juniper/no-shell ]]; then
  __juniper_shell=1
  # fzf first, so atuin's Ctrl-R replaces fzf's
  if command -v fzf >/dev/null; then eval "$(fzf --bash)"; fi
  if command -v atuin >/dev/null && [[ -r ${HOMEBREW_PREFIX:-}/etc/profile.d/bash-preexec.sh ]]; then
    # History stays on this machine: no update check, no AI binding, sync only after `atuin login`
    export ATUIN_UPDATE_CHECK=${ATUIN_UPDATE_CHECK:-false}
    # shellcheck source=/dev/null # installed by brew
    . "$HOMEBREW_PREFIX/etc/profile.d/bash-preexec.sh"
    eval "$(atuin init bash --disable-up-arrow --disable-ai)"
  fi
  if command -v zoxide >/dev/null; then eval "$(zoxide init bash)"; fi
  if command -v carapace >/dev/null; then eval "$(carapace _carapace bash)"; fi
  if command -v starship >/dev/null; then
    if [[ -z ${STARSHIP_CONFIG:-} && ! -e $HOME/.config/starship.toml ]]; then
      export STARSHIP_CONFIG=/usr/share/juniper/starship.toml
    fi
    eval "$(starship init bash)"
  fi
fi
