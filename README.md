# 📋 sshpbcopy — Copy from Remote Session to Local Clipboard over SSH

sshpbcopy is a fairly cross-platform UNIX clipboard bridge that can facilitate your local graphical system getting clipboard input from remote SSH sessions... over SSH.
The idea is to have the same command help you copy piping hot input to the clipboard whether it's running locally or in a remote session, making a local copy or making a remote copy.

# Copy remote output directly into your local clipboard
ssh user@remote "cat /etc/hosts" | sshpbcopy

or start a clipboard-aware SSH session:

sshpbcopy user@remote
# On the remote host:
echo "copied from remote" | sshpbcopy

Clipboard telepathy, powered entirely by mildly cursed Bash.

🚀 Features

✅ Copy from remote text streams to local clipboard more seamlessly than remembering xsel / xclip parameters, and without the benefit of X forwarding  
✅ Works with macOS (pbcopy), Linux (X11), and probably tmux & Wayland, or any OSC52-compatible terminal  
✅ No installation required on remote hosts — it uploads itself dynamically  
✅ Clipboard history stored locally (~/.local/share/sshpbcopy)  
✅ Multiple copy backends:
- Local tools (pbcopy, wl-copy, xclip, xsel)
- Terminal OSC52 escape sequences
- Reverse SSH tunnels using netcat  
✅ Debug mode, auto cleanup, and no background dependencies  

🧰 Installation

```bash
# Clone
git clone https://github.com/<yourname>/sshpbcopy.git
cd sshpbcopy

# Source it into your shell
source sshpbcopy.sh
```

Optionally, add this to your ~/.bashrc or ~/.zshrc:
```bash
source /path/to/sshpbcopy.sh
```

🧱 Requirements

| Component | Local | Remote | Notes |
|------------|--------|---------|-------|
| **Bash** | ✅ | ✅ | Required interpreter |
| **SSH client** | ✅ | ✅ | For remote/tunnel modes |
| **netcat (`nc`)** | ✅ | ⚙️ (strongly recommended, for tunnel use) | Required locally for tunnel; only needed remotely for tunnel mode |
| **base64 / sha1sum / date** | ✅ | ✅ | Core utilities |
| **pbcopy / wl-copy / xclip / xsel / tmux** | ✅ (any) | Optional | Clipboard backends |
| **OSC52 terminal support** | Optional | Optional | Enables copy via escape codes |
| **write access to ~/.local/share/sshpbcopy** | ✅ | Optional | For clipboard history |
| **No root or install privileges** | ✅ | ✅ | Fully user-space |

🧩 Transport Modes

sshpbcopy supports several “transport” modes that determine how it moves clipboard data back to your local machine (or your terminal):

| Flag | Description |
|------|--------------|
| `--use-tunnel` | Sends clipboard data through an existing SSH reverse tunnel (e.g. when `$SSH_PBCOPY_PORT` is set). |
| `--use-osc52` | Uses ANSI OSC52 escape sequences — works if your terminal supports clipboard escape codes (WezTerm, iTerm2, Kitty, etc.). |
| `--use-stderr-smuggled-frames` | Encodes clipboard data as base64 frames written to stderr (for terminals that don’t support OSC52). |
| `--use-localcopy` | Copies directly to the clipboard on that machine (using pbcopy, wl-copy, xclip, or similar). |

🧠 Typical SSH Workflow (without Wrapper)

Let’s say you’re already SSH’d into a remote server where sshpbcopy is available:

```bash
# Inside your SSH session
echo "hello from remote" | sshpbcopy --use-osc52
```

Your terminal (if it supports OSC52) will detect the special escape code and copy "hello from remote" straight to your local clipboard.

🧠 Quick Usage

```bash
# Copy from local
echo "hello world" | sshpbcopy

# Copy from remote via SSH
sshpbcopy user@remote
# Inside that session:
echo "remote data" | sshpbcopy

# View clipboard history
sshpbcopy --history

# Retrieve a specific entry
sshpbcopy --history-get=<id>

# Clear clipboard history
sshpbcopy --history-clear
```

⚙️ How It Works

### 1. Reverse SSH Tunnel Clipboard
When you SSH into a remote host, sshpbcopy:
- Sets up a localhost↔localhost reverse tunnel over SSH using `-R`.
- Starts a local netcat listener (`nc -l`) on a random port.
- Sends clipboard data through that tunnel back to your machine.

### 2. OSC52 Escape Sequence
If the terminal supports it (WezTerm, iTerm2, Kitty, etc.), it encodes clipboard data as:
```
ESC ] 52 ; c ; <base64-data> BEL
```
Terminals intercept this and copy it to the host clipboard.

### 3. “Smuggled stderr Frames” Fallback
If tunnels and OSC52 both fail, it base64-encodes clipboard data and sends it over stderr in structured frames:
```
SSH-PBCOPY:BIN:clipboard:some-name
<base64 content>
SSH-PBCOPY-END
```
The local listener decodes and restores it automatically.

📂 Clipboard History

All copies are logged in:
```
~/.local/share/sshpbcopy/
├── index        # Timestamp, ID, selection, name
├── last_clip    # Most recent copy
└── <sha1>       # Individual payloads
```
It keeps the last 50 entries by default (set `SSHPBCOPY_KEEP_HISTORY` to change this).

🧩 Supported Backends

sshpbcopy automatically detects the best available copy method:

| Environment | Backend used |
|--------------|--------------|
| macOS | `pbcopy` |
| Wayland | `wl-copy` |
| X11 | `xclip` / `xsel` |
| tmux | `tmux load-buffer` |
| Terminal supports OSC52 | ANSI clipboard escape |
| None available | stderr frame fallback |

🔍 Debugging

Enable verbose logs:
```bash
export SSHPBCOPY_DEBUG=1
```
Logs go to stderr and also `/tmp/sshpbcopy_listener_<port>.log`.

🧭 Roadmap

- [ ] **stderr Smuggled Frames (fully implemented)**  
  Finish the “smuggled frame” transport so it can transmit reliably over noisy PTYs, NAT, and multi-hop SSH sessions.

- [ ] **Automatic Paste Support (`sshpbpaste`)**  
  Add a complementary tool to retrieve clipboard contents from the local system into a remote session.

- [ ] **File Transfer Shortcuts**  
  Allow piping binary files safely via `--binary` without extra encoding steps.

- [ ] **Windows / WSL Support**  
  Experiment with `clip.exe` and WSL clipboard bridges.


🧼 Cleanup

Kill all background listeners and remove listener-related temporary files:
```bash
sshpbcopy_cleanup
```

⚠️ Note:
This is a very early proof of concept. Use at your own risk.



