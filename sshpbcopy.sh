sshpbcopy() {
    (
        #set -euo pipefail
        # export this as "1" for
        #local SSHPBCOPY_DEBUG="1"
        export SSHPBCOPY_DEBUG="${SSHPBCOPY_DEBUG:-0}"
        # --- Config ---
        : "${XDG_DATA_HOME:=$HOME/.local/share}"
        local data_dir="$XDG_DATA_HOME/sshpbcopy"
        mkdir -p "$data_dir"
        local history_index="$data_dir/index"
        local last_clip="$data_dir/last_clip"
        local KEEP_HISTORY="${SSHPBCOPY_KEEP_HISTORY:-50}"
        
        export SSHPBCOPY_KEEP_HISTORY="$KEEP_HISTORY"
        export SSHPBCOPY_HISTORY_INDEX="$history_index"
        export SSHPBCOPY_DATA_DIR="$data_dir"
        export SSHPBCOPY_LAST_CLIP="$last_clip"


        # --- Logging ---
        sshpbcopy_log() {
            # Enable debug if SSHPBCOPY_DEBUG is 1, true, or yes (case-insensitive).
            local debug_lc
            debug_lc="$(printf '%s' "${SSHPBCOPY_DEBUG:-}" | tr '[:upper:]' '[:lower:]')"

            case "$debug_lc" in
                1|true|yes)
                    local ts src
                    ts="$(date +"%Y-%m-%d %H:%M:%S")"

                    # Detect source line and file name, fallback if unavailable
                    if [ -n "${BASH_SOURCE:-}" ]; then
                        src="${BASH_SOURCE[1]##*/}:${BASH_LINENO[0]}"
                    elif [ -n "${ZSH_VERSION:-}" ]; then
                        src="${funcfiletrace[1]:-zsh}:${funcstack[1]:-?}"
                    else
                        src="unknown:0"
                    fi

                    printf '[%s][sshpbcopy][%d][%s] %s\n' "$ts" "$$" "$src" "$*" >&2
                    ;;
            esac
        }



        # --- Cleanup ---
        cleanup() {
            sshpbcopy_log "Cleaning up background processes"
            kill 0 >/dev/null 2>&1 || true
            exit 0
        }


        # --- Helpers ---
        sshpbcopy_sha1() { printf "%s" "$1" | sha1sum 2>/dev/null | awk '{print $1}'; }

        sshpbcopy_trim_history() {
            [ -f "$history_index" ] || return 0
            local lines
            lines=$(wc -l <"$history_index" || echo 0)
            if [ "$lines" -gt "$KEEP_HISTORY" ]; then
                tail -n "$KEEP_HISTORY" "$history_index" >"$history_index.tmp"
                mv "$history_index.tmp" "$history_index"
                sshpbcopy_log "History trimmed to $KEEP_HISTORY entries"
            fi
        }

        sshpbcopy_save_history() {
            local payload="$1" sel="$2" name="$3" binflag="$4"
            local ts id filemeta
            ts=$(date --iso-8601=seconds 2>/dev/null || date +"%Y-%m-%dT%H:%M:%S%z")
            id=$(sshpbcopy_sha1 "$payload$ts")
            filemeta="$data_dir/$id"
            printf '%s' "$payload" >"$filemeta"
            printf '%s\t%s\t%s\t%s\n' "$ts" "$id" "$sel" "${name:--}" >>"$history_index"
            printf '%s' "$payload" >"$last_clip"
            sshpbcopy_trim_history
            sshpbcopy_log "Saved history entry $id"
        }

        # --- OSC52 backend ---
        sshpbcopy_supports_osc52() {
            case "${TERM:-}" in
                xterm*|tmux*|screen*|wezterm*|alacritty*|iTerm2*|foot*|kitty*) return 0 ;;
                *) return 1 ;;
            esac
        }

        sshpbcopy_copy_osc52() {
            local data encoded
            data=$(cat)
            encoded=$(printf "%s" "$data" | base64 | tr -d '\n')
            printf '\033]52;c;%s\a' "$encoded"
            sshpbcopy_log "Copied via OSC52"
        }

        # --- stderr-smuggled frames backend ---
        sshpbcopy_copy_stderr_smuggled_frames() {
            local selection="${1:-clipboard}" name="${2:-}" binflag="${3:-0}"
            local tmp flags
            tmp=$(mktemp)
            cat >"$tmp"

            flags=""
            [ "$binflag" = "1" ] && flags="BIN"

            # Clean frame boundaries so shells/prompts don't collide with markers
            sshpbcopy_log "Emitting stderr-smuggled frame (flags=$flags selection=$selection name=$name)"
            printf '\nSSH-PBCOPY:%s:%s:%s\n' "${flags:-}" "${selection:-clipboard}" "${name:--}" >&2
            # Stream base64 as lines; avoid CR and keep lines short for noisy PTYs
            base64 <"$tmp" | tr -d '\r' | fold -w 76 >&2
            printf '\nSSH-PBCOPY-END\n' >&2

            rm -f "$tmp"
        }


        # --- stderr listener (restored) ---
        sshpbpaste_stderr_listener() {
            # Must run in a subshell that already has sshpbcopy_* funcs defined.
            set -euo pipefail

            # Prepare local storage and also set the variable names that
            # sshpbcopy_copy_local/sshpbcopy_save_history expect to see.
            local _xdg="${XDG_DATA_HOME:-$HOME/.local/share}"
            local data_dir="$_xdg/sshpbcopy"        # <- names as expected by copy_local/sshpbcopy_save_history
            local history_index="$data_dir/index"
            local last_clip="$data_dir/last_clip"
            mkdir -p "$data_dir"

            # Frame state
            local flags="" selection="" name="" collecting=0
            local tmp_b64 tmp_dec
            tmp_b64=$(mktemp)
            tmp_dec=$(mktemp)

            # Helper: reset frame buffers
            _reset_frame() {
                : >"$tmp_b64"
                : >"$tmp_dec"
                flags=""; selection=""; name=""
                collecting=0
            }

            # Start clean
            _reset_frame

            # Read stderr line-by-line; multiple frames per stream are supported.
            # Non-frame lines are forwarded to stderr verbatim.
            while IFS= read -r line; do
                case "$line" in
                    SSH-PBCOPY:*)
                        # Begin new frame
                        _reset_frame
                        # Header format: SSH-PBCOPY:FLAGS:SELECTION:NAME
                        # NAME may contain colons; split first three fields then recombine the rest.
                        local hdr rest
                        hdr=${line#SSH-PBCOPY:}
                        IFS=':' read -r flags selection rest <<<"$hdr"
                        name=${rest:-"-"}
                        collecting=1
                        echo "[stderr-listener] Detected frame (flags=${flags:-}- sel=${selection:-clipboard} name=${name})" >&2
                        ;;
                    SSH-PBCOPY-END)
                        if [ "$collecting" = "1" ]; then
                            echo "[stderr-listener] Frame complete, decoding…" >&2
                            # Decode; if decoding fails, keep raw bytes
                            if echo "$flags" | grep -q "BIN"; then
                                base64 --decode <"$tmp_b64" >"$tmp_dec" 2>/dev/null || cp "$tmp_b64" "$tmp_dec"
                            else
                                base64 --decode <"$tmp_b64" >"$tmp_dec" 2>/dev/null || cp "$tmp_b64" "$tmp_dec"
                            fi

                            # Hand off to the unified local handler so history/index/last_clip and GUI/headless
                            # behavior all live in one place. Ensure the expected variables are in scope.
                            cat "$tmp_dec" | sshpbcopy_copy_local "${selection:-clipboard}" "$name" 0 \
                                >>"/tmp/sshpbcopy_stderr_listener.log" 2>&1 || \
                                echo "[stderr-listener] Local copy failed (nonfatal)" >&2

                            _reset_frame
                        fi
                        ;;
                    *)
                        if [ "$collecting" = "1" ]; then
                            # Collect base64 body; strip CRs to be resilient to PTY line endings
                            printf '%s\n' "$line" | tr -d '\r' >>"$tmp_b64"
                        else
                            # Pass unrelated stderr through verbatim
                            echo "$line" >&2
                        fi
                        ;;
                esac
            done

            rm -f "$tmp_b64" "$tmp_dec"
        }


        # --- Local copy handler ---
        sshpbcopy_copy_local() {
            local selection="${1:-clipboard}" name="${2:-}" binflag="${3:-0}"
            local tmp payload
            tmp=$(mktemp)
            cat >"$tmp"
            payload=$(cat "$tmp")

            if [ "$binflag" = "1" ]; then
                base64 --decode <"$tmp" >"$tmp.dec" 2>/dev/null || mv "$tmp" "$tmp.dec"
                mv "$tmp.dec" "$tmp"
            fi

            if command -v tmux >/dev/null 2>&1 && [ -n "${TMUX:-}" ]; then
                tmux load-buffer - <"$tmp" && sshpbcopy_log "Loaded into tmux buffer"
            fi

            local copied_backend=false

            # macOS native clipboard
            if command -v pbcopy >/dev/null 2>&1; then
                pbcopy <"$tmp" && sshpbcopy_log "Copied via pbcopy" && copied_backend=true

            # Wayland
            elif command -v wl-copy >/dev/null 2>&1; then
                wl-copy <"$tmp" && sshpbcopy_log "Copied via wl-copy" && copied_backend=true

            # X11
            elif command -v xclip >/dev/null 2>&1; then
                xclip -selection "$selection" <"$tmp" && sshpbcopy_log "Copied via xclip" && copied_backend=true

            elif command -v xsel >/dev/null 2>&1; then
                xsel --clipboard --input <"$tmp" && sshpbcopy_log "Copied via xsel" && copied_backend=true

            # OSC52 fallback
            elif sshpbcopy_supports_osc52; then
                sshpbcopy_copy_osc52 <"$tmp"
                sshpbcopy_log "Copied via OSC52"
                copied_backend=true
            fi

            # Final fallback
            if ! $copied_backend; then
                sshpbcopy_log "No clipboard backend found; printing to stderr"
                cat "$tmp" >&2
            fi

            sshpbcopy_save_history "$payload" "$selection" "$name" "$binflag"
            rm -f "$tmp"
        }



        # --- Tunnel plumbing ---
        sshpbcopy_choose_port() {
            local port
            while true; do
                port=$(( (RANDOM % 10000) + 40000 ))
                if ! nc -z 127.0.0.1 "$port" 2>/dev/null; then
                    echo "$port"
                    return
                fi
            done
        }

sshpbcopy_start_listener() {
    local port="$1"
    local logfile="/tmp/sshpbcopy_listener_${port}.log"

    sshpbcopy_log "Starting listener on 127.0.0.1:$port (logging to $logfile)"

    # Capture function definitions
    local func_defs
    func_defs="$(
        declare -f \
            sshpbcopy_sha1 \
            sshpbcopy_save_history \
            sshpbcopy_trim_history \
            sshpbcopy_copy_local \
            sshpbcopy_copy_osc52 \
            sshpbcopy_copy_stderr_smuggled_frames \
            sshpbcopy_log \
            sshpbcopy_supports_osc52
    )"

    # Prepare environment vars for the detached subshell
    local XDG_DATA_HOME_val="${XDG_DATA_HOME:-$HOME/.local/share}"
    local data_dir_val="$XDG_DATA_HOME_val/sshpbcopy"
    local history_index_val="$data_dir_val/index"
    local last_clip_val="$data_dir_val/last_clip"
    local keep_hist_val="${SSHPBCOPY_KEEP_HISTORY:-50}"
    local debug_val="${SSHPBCOPY_DEBUG:-1}"

    # Use nohup for macOS-safe background execution
    nohup bash -c "
        set -euo pipefail
        $func_defs

        export XDG_DATA_HOME=\"$XDG_DATA_HOME_val\"
        data_dir=\"$data_dir_val\"
        history_index=\"$history_index_val\"
        last_clip=\"$last_clip_val\"
        SSHPBCOPY_KEEP_HISTORY=\"$keep_hist_val\"
        SSHPBCOPY_DEBUG=\"$debug_val\"

        mkdir -p \"\$data_dir\"
        LOGFILE=\"$logfile\"
        PORT=${port}

        log() { echo \"[\$(date +%F\ %T)] \$*\" >>\"\$LOGFILE\"; }

        log \"Listener starting on 127.0.0.1:\$PORT\"
        log \"Environment: XDG_DATA_HOME=\$XDG_DATA_HOME, PID=\$\$, data_dir=\$data_dir\"

        trap 'log \"Received termination signal, exiting.\"; exit 0' INT TERM

        while true; do
            log \"Waiting on 127.0.0.1:\$PORT\"
            tmpfile=\$(mktemp)
            
            
            
            
            if nc -h 2>&1 | grep -q -- '-N'; then
                log \"Using netcat -N (modern) mode\"
                nc -l -N 127.0.0.1 \"\$PORT\" >\"\$tmpfile\"
            else
                log \"Using netcat -w 1 (BSD/macOS mode)\"
                nc -l 127.0.0.1 \"\$PORT\" -w 1 >\"\$tmpfile\"
            fi
            
            
            
            rc=\$?
            if [ -s \"\$tmpfile\" ]; then
                preview=\$(head -c 200 \"\$tmpfile\" | tr -cd '[:print:]\n' | sed 's/\n/\\\\n/g')
                log \"Received \$(wc -c <\"\$tmpfile\") bytes: '\${preview}'...\"
            else
                log \"Received empty input\"
            fi

            # Always use unified local handler (which updates history + fallback)
            cat \"\$tmpfile\" | sshpbcopy_copy_local >>\"\$LOGFILE\" 2>&1 \
                || log \"Error: copy handler failed\"

            log \"Copy complete (rc=\$rc)\"
            rm -f \"\$tmpfile\"
            sleep 0.1
        done
    " >/dev/null 2>&1 < /dev/null &

    local listener_pid=$!

    # Attempt to disown safely (Linux only), ignore failures (macOS-safe)
    if command -v disown >/dev/null 2>&1; then
        disown "$listener_pid" 2>/dev/null || true
    fi

    echo "$listener_pid"
}




        

        # --- History CLI ---
        history_list() { [ -f "$history_index" ] && cat -n "$history_index" || echo "No history"; }
        history_get() { cat "$data_dir/$1" 2>/dev/null || echo "No such ID"; }
        history_clear() { rm -rf "$data_dir"; mkdir -p "$data_dir"; echo "history cleared"; }

        # --- SSH mode with host detection + self-connection logic ---
        sshpbcopy_ssh_mode() {
            local listener_pid keepalive=${SSHPBCOPY_KEEPALIVE:-0}
            local self_install=${SSHPBCOPY_SELF_INSTALL:-1}
            local alias_pbcopy=${SSHPBCOPY_ALIAS_PBCOPY:-0}
            local ssh_args=()
            for a in "$@"; do
                case "$a" in
                    --use-*|--alias-pbcopy|--binary|--debug|--selection=*|--name=*|--keep-alive|--no-self-install|--self-install|--history*|--history-clear) ;;
                    *) ssh_args+=("$a") ;;
                esac
            done

            # Extract target host
            local target_host
            target_host=$(for a in "${ssh_args[@]}"; do
                case "$a" in
                    *@*) echo "${a#*@}" && break ;;
                    -*) ;;
                    *) echo "$a" && break ;;
                esac
            done)
            target_host="${target_host:-localhost}"

            # Port setup (handles localhost case)
            local port_local port_remote
            if [[ "$target_host" =~ ^(localhost|127\.0\.0\.1|::1)$ ]] || [ "$target_host" = "$(hostname)" ]; then
                sshpbcopy_log "Self-connection detected: using distinct local/remote ports"
                port_local=$(sshpbcopy_choose_port)
                while :; do
                    port_remote=$(sshpbcopy_choose_port)
                    [ "$port_remote" != "$port_local" ] && break
                done
            else
                port_local="${SSHPBCOPY_PORT_OVERRIDE:-$(sshpbcopy_choose_port)}"
                port_remote="$port_local"
            fi

            local remote_tmp="/tmp/sshpbcopy.$$.$RANDOM"
            local ctrl_sock="/tmp/sshpbcopy_ctrl_${USER:-$(whoami)}.$$.$RANDOM"
            local ctrl_opts=(-o ControlMaster=yes -o ControlPath="$ctrl_sock" -o ControlPersist=60)
            local master_started=0

            sshpbcopy_log "Starting SSH ControlMaster for ${ssh_args[*]} (local=$port_local, remote=$port_remote)"
            if ssh "${ctrl_opts[@]}" -N -f \
                  -o SendEnv=SSH_PBCOPY_PORT \
                  -o SendEnv=SSHPBCOPY_DEBUG \
                  -R "127.0.0.1:$port_remote:127.0.0.1:$port_local" "${ssh_args[@]}" 2>/dev/null; then
                master_started=1
            else
                sshpbcopy_log "Warning: failed to start ControlMaster; continuing without it"
            fi


            local self_def; self_def=$(declare -f sshpbcopy)
            if [ "$self_install" = "1" ] && [ "$alias_pbcopy" = "1" ]; then
                self_def="${self_def}
pbcopy() { sshpbcopy \"\$@\"; }"
            fi

            ssh -o ControlPath="$ctrl_sock" "${ssh_args[@]}" "cat > '$remote_tmp'" <<-EOF
$self_def
export SSH_PBCOPY_PORT="$port_remote"
export SSHPBCOPY_DEBUG="${SSHPBCOPY_DEBUG:-0}"
echo "[sshpbcopy rcfile] loaded: SSH_PBCOPY_PORT=$port_remote"
trap 'rm -f "$remote_tmp" 2>/dev/null || true' EXIT
shopt -s expand_aliases 2>/dev/null || true
EOF

            listener_pid=$(sshpbcopy_start_listener "$port_local")
            sshpbcopy_log "Detached listener PID=$listener_pid"
            echo "[sshpbcopy] Tunnel active (remote $port_remote → local $port_local) — run 'echo text | sshpbcopy' remotely to copy back." >&2

            SSH_PBCOPY_PORT="$port_remote" ssh -tt -o ControlPath="$ctrl_sock" \
                -R "127.0.0.1:$port_remote:127.0.0.1:$port_local" \
                -o SendEnv=SSH_PBCOPY_PORT \
                -o SendEnv=SSHPBCOPY_DEBUG \
                "${ssh_args[@]}" "bash --rcfile '$remote_tmp' --noprofile -i"


            if [ "$master_started" -eq 1 ]; then
                ssh -o ControlPath="$ctrl_sock" -O exit "${ssh_args[@]}" 2>/dev/null || true
                rm -f "$ctrl_sock" 2>/dev/null || true
            fi
        }

        # --- Flag parsing ---
        local FORCE_TRANSPORT="auto" SELECTION="clipboard" NAME="" BINFLAG=0
        for arg in "$@"; do
            case "$arg" in
                --use-osc52) FORCE_TRANSPORT="osc52" ;;
                --use-localcopy) FORCE_TRANSPORT="local" ;;
                --use-tunnel|--force-tunnel) FORCE_TRANSPORT="tunnel" ;;
                --use-stderr-smuggled-frames) FORCE_TRANSPORT="stderr-smuggled-frames" ;;
                --tunnel-port=*) SSHPBCOPY_PORT_OVERRIDE="${arg#*=}" ;;
                --binary) BINFLAG=1 ;;
                --selection=*) SELECTION="${arg#*=}" ;;
                --name=*) NAME="${arg#*=}" ;;
                --history) history_list; return ;;
                --history-get=*) history_get "${arg#*=}"; return ;;
                --history-clear) history_clear; return ;;
                -h|--help)
                    cat <<EOF
Usage:
  echo "text" | sshpbcopy [options]
  or: sshpbcopy user@host
Options:
  --use-osc52 | --use-tunnel | --use-localcopy | --use-stderr-smuggled-frames
  --selection=<clipboard|primary>
  --binary | --name=<label>
  --history | --history-get=<id> | --history-clear
EOF
                    return ;;
            esac
        done

        # --- Entry logic ---
        if [ ! -t 0 ]; then
            sshpbcopy_log "ENTRY: stdin is not a TTY — reading piped input"
            sshpbcopy_log "CONFIG: FORCE_TRANSPORT=$FORCE_TRANSPORT, SELECTION=$SELECTION, NAME=${NAME:-<none>}, BINFLAG=$BINFLAG"

            case "$FORCE_TRANSPORT" in
                osc52)
                    sshpbcopy_log "TRANSPORT: Using OSC52 escape sequence backend"
                    sshpbcopy_copy_osc52
                    sshpbcopy_log "RESULT: Data copied via OSC52"
                    ;;

                local)
                    sshpbcopy_log "TRANSPORT: Using local clipboard backend"
                    sshpbcopy_copy_local "$SELECTION" "$NAME" "$BINFLAG"
                    sshpbcopy_log "RESULT: Data copied via local tool"
                    ;;

                stderr-smuggled-frames)
                    sshpbcopy_log "TRANSPORT: Using stderr-smuggled-frames backend"
                    sshpbcopy_copy_stderr_smuggled_frames "$SELECTION" "$NAME" "$BINFLAG"
                    sshpbcopy_log "RESULT: Data emitted as base64-encoded frame to stderr"
                    ;;

                tunnel|auto)
                    if [ -n "${SSH_PBCOPY_PORT:-}" ]; then
                        sshpbcopy_log "TRANSPORT: Using active tunnel to 127.0.0.1:$SSH_PBCOPY_PORT"
                        nc 127.0.0.1 "$SSH_PBCOPY_PORT"
                        sshpbcopy_log "RESULT: Data sent via tunnel"
                    elif sshpbcopy_supports_osc52; then
                        sshpbcopy_log "TRANSPORT: Terminal supports OSC52 — using OSC52 copy"
                        sshpbcopy_copy_osc52
                        sshpbcopy_log "RESULT: Data copied via OSC52"
                    else
                        sshpbcopy_log "TRANSPORT: No tunnel or OSC52 support — falling back to local copy"
                        sshpbcopy_copy_local "$SELECTION" "$NAME" "$BINFLAG"
                        sshpbcopy_log "RESULT: Data copied via local clipboard tool"
                    fi
                    ;;
            esac

        else
            sshpbcopy_log "ENTRY: Interactive TTY detected — starting SSH interactive mode"
            sshpbcopy_ssh_mode "$@"
        fi


    )
}


sshpbcopy_cleanup() {
    # Clean up leftover sshpbcopy listeners, logs, and temp files
    local pids

    echo "[sshpbcopy_cleanup] Searching for sshpbcopy-related processes..."
    pgrep -a -f sshpbcopy || echo "[sshpbcopy_cleanup] None found."

    # Find matching PIDs
    pids=$(pgrep -f sshpbcopy)

    if [ -n "$pids" ]; then
        echo "[sshpbcopy_cleanup] Killing processes: $pids"
        # Try graceful kill first
        kill $pids 2>/dev/null
        sleep 1

        # Force kill if any survive
        if pgrep -f sshpbcopy >/dev/null; then
            echo "[sshpbcopy_cleanup] Forcing kill (-9)..."
            kill -9 $pids 2>/dev/null
        fi
    else
        echo "[sshpbcopy_cleanup] No running processes to kill."
    fi

    # Clean up leftover files
    echo "[sshpbcopy_cleanup] Removing temp files..."
    rm -f /tmp/sshpbcopy* 2>/dev/null

    # Optionally clear clipboard history (uncomment if desired)
    # rm -rf "${XDG_DATA_HOME:-$HOME/.local/share}/sshpbcopy"

    echo "[sshpbcopy_cleanup] Done."
}

