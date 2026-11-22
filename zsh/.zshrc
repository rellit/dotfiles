# ~/.zshrc – symlinked from ~/dotfiles/zsh/.zshrc, used on Arch and on Ubuntu/WSL.
# The differences between the systems are handled where they occur: plugin paths,
# pacman aliases, WSL aliases and where the SSH agent comes from.

###################
### Environment ###
###################
export EDITOR=vim
export VISUAL=vim

# Install Ruby gems to ~/gems
export GEM_HOME="$HOME/gems"

# No duplicate entries when a shell is started from a shell
typeset -U path
path=("$HOME/gems/bin" $path "$HOME/.local/bin")

####################
### Clear Screen ###
####################
# Everything that prints has to run before the instant prompt below
if [[ -t 1 ]]; then
  clear
  # Random color script
  (( $+commands[colorscript] )) && colorscript random
fi

# Enable Powerlevel10k instant prompt. Should stay close to the top of ~/.zshrc.
# Initialization code that may require console input (password prompts, [y/n]
# confirmations, etc.) must go above this block; everything else may go below.
if [[ -r "${XDG_CACHE_HOME:-$HOME/.cache}/p10k-instant-prompt-${(%):-%n}.zsh" ]]; then
  source "${XDG_CACHE_HOME:-$HOME/.cache}/p10k-instant-prompt-${(%):-%n}.zsh"
fi

###############
### History ###
###############
HISTFILE=~/.zsh_history
HISTSIZE=50000
SAVEHIST=50000
setopt hist_ignore_all_dups share_history
setopt hist_ignore_space    # a command starting with a space is not saved
setopt hist_reduce_blanks

####################
### Key bindings ###
####################
# Use emacs keybindings even if our EDITOR is set to vi
bindkey -e

# Create a zkbd compatible hash; to add other keys to this hash, see: man 5 terminfo
typeset -g -A key
key[Home]="${terminfo[khome]}"
key[End]="${terminfo[kend]}"
key[Insert]="${terminfo[kich1]}"
key[Backspace]="${terminfo[kbs]}"
key[Delete]="${terminfo[kdch1]}"
key[Up]="${terminfo[kcuu1]}"
key[Down]="${terminfo[kcud1]}"
key[Left]="${terminfo[kcub1]}"
key[Right]="${terminfo[kcuf1]}"
key[PageUp]="${terminfo[kpp]}"
key[PageDown]="${terminfo[knp]}"
key[Shift-Tab]="${terminfo[kcbt]}"

# Start typing + Up/Down: search the history for lines beginning like that
autoload -Uz up-line-or-beginning-search down-line-or-beginning-search
zle -N up-line-or-beginning-search
zle -N down-line-or-beginning-search

[[ -n "${key[Home]}"      ]] && bindkey -- "${key[Home]}"       beginning-of-line
[[ -n "${key[End]}"       ]] && bindkey -- "${key[End]}"        end-of-line
[[ -n "${key[Insert]}"    ]] && bindkey -- "${key[Insert]}"     overwrite-mode
[[ -n "${key[Backspace]}" ]] && bindkey -- "${key[Backspace]}"  backward-delete-char
[[ -n "${key[Delete]}"    ]] && bindkey -- "${key[Delete]}"     delete-char
[[ -n "${key[Up]}"        ]] && bindkey -- "${key[Up]}"         up-line-or-beginning-search
[[ -n "${key[Down]}"      ]] && bindkey -- "${key[Down]}"       down-line-or-beginning-search
[[ -n "${key[Left]}"      ]] && bindkey -- "${key[Left]}"       backward-char
[[ -n "${key[Right]}"     ]] && bindkey -- "${key[Right]}"      forward-char
[[ -n "${key[PageUp]}"    ]] && bindkey -- "${key[PageUp]}"     beginning-of-buffer-or-history
[[ -n "${key[PageDown]}"  ]] && bindkey -- "${key[PageDown]}"   end-of-buffer-or-history
[[ -n "${key[Shift-Tab]}" ]] && bindkey -- "${key[Shift-Tab]}"  reverse-menu-complete

# Finally, make sure the terminal is in application mode, when zle is
# active. Only then are the values from $terminfo valid.
if (( ${+terminfo[smkx]} && ${+terminfo[rmkx]} )); then
  autoload -Uz add-zle-hook-widget
  function zle_application_mode_start { echoti smkx }
  function zle_application_mode_stop { echoti rmkx }
  add-zle-hook-widget -Uz zle-line-init zle_application_mode_start
  add-zle-hook-widget -Uz zle-line-finish zle_application_mode_stop
fi

##################
### Completion ###
##################
autoload -Uz compinit
compinit

eval "$(dircolors -b)"
zstyle ':completion:*' auto-description 'specify: %d'
zstyle ':completion:*' completer _expand _complete _correct _approximate
zstyle ':completion:*' format 'Completing %d'
zstyle ':completion:*' group-name ''
zstyle ':completion:*:default' list-colors ${(s.:.)LS_COLORS}
zstyle ':completion:*' list-colors ''
zstyle ':completion:*' list-prompt %SAt %p: Hit TAB for more, or the character to insert%s
zstyle ':completion:*' matcher-list '' 'm:{a-z}={A-Z}' 'm:{a-zA-Z}={A-Za-z}' 'r:|[._-]=* r:|=* l:|=*'
zstyle ':completion:*' menu select=long
zstyle ':completion:*' select-prompt %SScrolling active: current selection at %p%s
zstyle ':completion:*' use-compctl false
zstyle ':completion:*' verbose true

zstyle ':completion:*:*:kill:*:processes' list-colors '=(#b) #([0-9]#)*=0=01;31'
zstyle ':completion:*:kill:*' command 'ps -u $USER -o pid,%cpu,tty,cputime,cmd'

##############
### Prompt ###
##############
if [[ -r ~/dotfiles/zsh/powerlevel10k/powerlevel10k.zsh-theme ]]; then
  source ~/dotfiles/zsh/powerlevel10k/powerlevel10k.zsh-theme
  # To customize prompt, run `p10k configure` or edit ~/.p10k.zsh.
  [[ ! -f ~/.p10k.zsh ]] || source ~/.p10k.zsh
else
  # Until zsh/bootstrap has cloned powerlevel10k
  autoload -Uz promptinit && promptinit && prompt adam1
fi

#################
### SSH agent ###
#################
# No key is loaded at shell start, so there is no passphrase prompt here.
# ~/dotfiles/ssh/config sets AddKeysToAgent: the passphrase is asked on the first
# use (ssh, git push, ...) and the key then stays in the agent for every shell.
# - A working agent is kept: on Arch the GNOME agent (gcr, asks with its own
#   dialog), or an agent forwarded over SSH.
# - Otherwise (WSL, TTY, SSH without forwarding) all shells share one agent on a
#   fixed socket. The first shell starts it, after a restart it is started again.
() {
  # ssh-add -l: 0 = keys loaded, 1 = agent without keys, 2 = no agent reachable
  if [[ -n $SSH_AUTH_SOCK ]]; then
    ssh-add -l &>/dev/null
    (( $? != 2 )) && return
  fi
  (( $+commands[ssh-agent] )) || return

  local sock=$HOME/.ssh/agent.sock lock=$HOME/.ssh/agent.lock fd
  export SSH_AUTH_SOCK=$sock
  unset SSH_AGENT_PID
  [[ -d $HOME/.ssh ]] || mkdir -m 700 $HOME/.ssh
  # Shells opened at the same moment must not start several agents
  : >> $lock
  zmodload -F zsh/system b:zsystem && zsystem flock -t 5 -f fd $lock
  ssh-add -l &>/dev/null
  if (( $? == 2 )); then
    command rm -f $sock
    ssh-agent -a $sock &>/dev/null
  fi
  [[ -n $fd ]] && zsystem flock -u $fd
}

###############
### Aliases ###
###############
# Navigation & Listing
alias ls='ls --color=auto'
alias ll='ls -l'
alias la='ls -lA'
alias ..='cd ..'
alias ...='cd ../..'
alias .3='cd ../../../'
alias .4='cd ../../../../'
alias .5='cd ../../../../../'

mkcd() {
  local dir="$*"
  mkdir -p -- "$dir" && cd -- "$dir"
}

# Pacman (Arch only)
if (( $+commands[pacman] )); then
  alias pacsyu='sudo pacman -Syyu'
  alias orphan='pacman -Qtdq'
  alias cleanup='sudo pacman -Rscn $(pacman -Qtdq)'
fi
(( $+commands[yay] )) && alias yay='yay --noconfirm'

# Don't do something bad
alias rm='rm -i'
alias cp='cp -i'
alias mv='mv -i'

# Console
alias cls=clear
alias nano='nano -m'

# Dotfiles config
alias config='/usr/bin/git --git-dir=$HOME/dot/ --work-tree=$HOME'

# Sudo
alias pls='sudo $(fc -ln -1)'

# Git
alias gaa='git add .'
alias gcm='git commit -m'
alias gs='git status'
alias gl='git log --oneline --graph'
alias gpl='git pull'
alias gp='git push'
alias grs='git restore --staged'
alias gfs='git fetch && git switch'

# EIS OTP
if [[ -f ~/.eisOTPSecret ]]; then
  alias otp='oathtool --totp $(cat ~/.eisOTPSecret)'
else
  alias otp='echo To use save hex-secret in ~/.eisOTPSecret'
fi

alias eisvpn='echo $(cat ~/.eisPassword)$(otp) | nmcli con up id Tim@vpn.eiskonzept.com --ask'

# WSL only (WSL 2 writes "microsoft", WSL 1 "Microsoft" into /proc/version)
if [[ -n $WSL_DISTRO_NAME || $(</proc/version) == *[Mm]icrosoft* ]]; then
  alias cmd='cmd.exe /C'
fi

# Tools
alias grep='grep --color=auto'
alias df='df -h'
(( $+commands[htop] )) && alias top='htop'

#############
### Tools ###
#############
# zoxide replaces cd
(( $+commands[zoxide] )) && eval "$(zoxide init zsh --cmd cd)"

# Angular CLI autocompletion. Generating it starts node (~200 ms per shell),
# so the script is cached and generated again once a week.
if (( $+commands[ng] )); then
  () {
    local cache=${XDG_CACHE_HOME:-$HOME/.cache}/zsh/ng-completion.zsh
    local -a fresh=($cache(N.L+0md-7))
    if (( ! $#fresh )); then
      mkdir -p ${cache:h}
      ng completion script >| $cache.tmp 2>/dev/null && [[ -s $cache.tmp ]] &&
        command mv -f $cache.tmp $cache
    fi
    [[ -r $cache ]] && source $cache
  }
fi

###############
### Plugins ###
###############
# Path of a distribution plugin: Arch /usr/share/zsh/plugins/<name>/,
# Ubuntu /usr/share/<name>/
_zsh_plugin() {
  local f
  for f in /usr/share/zsh/plugins/$1/$1.zsh /usr/share/$1/$1.zsh; do
    [[ -r $f ]] && REPLY=$f && return 0
  done
  return 1
}

# Auto suggestion
if _zsh_plugin zsh-autosuggestions; then
  source $REPLY
  ZSH_AUTOSUGGEST_STRATEGY=(history completion)
fi

# Syntax highlighting – has to be sourced last, the theme right before it
if _zsh_plugin zsh-syntax-highlighting; then
  source ~/dotfiles/zsh/catppuccin_mocha-zsh-syntax-highlighting.zsh
  source $REPLY
fi

unfunction _zsh_plugin
