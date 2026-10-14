# shellcheck shell=bash
# Juniper's interactive bash: carapace completions, fzf keys (Ctrl-T, Alt-C, **<Tab>), atuin
# history search (Ctrl-R), zoxide (z) and a starship prompt. Each hooks in only once its Brewfile
# tool is installed (first login); `ujust toggle-shell` turns them all off per user.
# Never for root, or for a user whose PATH reaches someone else's Homebrew: those binaries are
# writable by their owner, and would otherwise run in your shell at every prompt.
if [ -n "${BASH_VERSION:-}" ] && [[ $- == *i* && -t 0 && ${TERM:-dumb} != dumb && $EUID -ne 0 &&
  -z ${__juniper_shell:-} && ! -e $HOME/.config/juniper/no-shell ]] &&
  [[ -z ${HOMEBREW_PREFIX:-} || -O $HOMEBREW_PREFIX ]]; then
  __juniper_shell=1
  # carapace first: fzf keeps the completions it finds and falls back to them
  if command -v carapace >/dev/null; then eval "$(carapace _carapace bash)"; fi
  # fzf before atuin, so atuin's Ctrl-R replaces fzf's
  if command -v fzf >/dev/null; then eval "$(fzf --bash)"; fi
  if command -v atuin >/dev/null; then
    # History stays on this machine: no update check, no AI binding, sync only after `atuin login`.
    # atuin brings its own bash-preexec, which starship then uses too.
    export ATUIN_UPDATE_CHECK=${ATUIN_UPDATE_CHECK:-false}
    eval "$(atuin init bash --disable-up-arrow --disable-ai)"
  fi
  if command -v zoxide >/dev/null; then eval "$(zoxide init bash)"; fi
  if command -v starship >/dev/null; then
    # An inherited default must not hide a starship.toml the user has made since
    if [[ ${STARSHIP_CONFIG:-} == /usr/share/juniper/starship.toml && -e $HOME/.config/starship.toml ]]; then
      unset STARSHIP_CONFIG
    fi
    if [[ -z ${STARSHIP_CONFIG:-} && ! -e $HOME/.config/starship.toml ]]; then
      export STARSHIP_CONFIG=/usr/share/juniper/starship.toml
    fi
    eval "$(starship init bash)"
  fi
fi
