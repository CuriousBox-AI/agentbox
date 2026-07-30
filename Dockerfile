# syntax=docker/dockerfile:1
#
# agentbox — a two-user dev container for Apple `container`.
#
#   admin (uid 1000) — you.        sudo, reads /srv/secrets, starts the servers.
#   agent (uid 2000) — Claude Code. owns /workspace, cannot read /srv/secrets.
#
# Everything runtime-specific (volumes, ports, the chown of /workspace) lives
# in up.sh, not here. See the comment block at the top of that file for why.

FROM ubuntu:24.04

ARG ADMIN_KEY
ARG AGENT_KEY
ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
      openssh-server sudo ca-certificates curl wget git tar gzip \
      python3 python3-venv python3-pip build-essential \
 && rm -rf /var/lib/apt/lists/* \
 && mkdir -p /run/sshd

# Node is not installed. Claude Code's native installer does not need it:
#   curl -fsSL https://claude.ai/install.sh | bash        (run as agent)
# If your project needs Node, add it here rather than letting the agent
# install it into its home directory.

# ── users ────────────────────────────────────────────────────────────────────
# ubuntu:24.04 ships a user 'ubuntu' at uid 1000 — remove it before claiming
# that uid for admin.
RUN userdel -r ubuntu 2>/dev/null || true \
 && groupadd -g 3000 devs \
 && useradd -m -u 1000 -s /bin/bash admin \
 && useradd -m -u 2000 -s /bin/bash agent \
 && usermod -aG devs admin \
 && usermod -aG devs agent \
 && usermod -aG sudo admin \
 && chmod 700 /home/admin /home/agent

RUN echo 'admin ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/90-admin \
 && chmod 0440 /etc/sudoers.d/90-admin

# ── shared-group umask ───────────────────────────────────────────────────────
# Both users are in `devs`. With the default umask 022 the agent's files come
# out 0644, so admin can read and execute them but not edit them. 002 makes
# them 0664 so admin can edit too. Drop these two lines if you would rather
# admin needed sudo to touch the agent's files.
RUN sed -i 's/^UMASK.*/UMASK\t\t002/' /etc/login.defs \
 && printf 'session optional pam_umask.so\n' >> /etc/pam.d/sshd

# ── secrets ──────────────────────────────────────────────────────────────────
# Mountpoint only. A named volume (box-secrets) mounts over this at runtime so
# the .env files survive `container delete`, and up.sh re-applies the ownership
# after the mount — a fresh volume always comes up root:root 0755.
#
# The .env file itself is never baked into the image: anything COPY'd here
# would live in that layer forever, survive `container image save`, and need a
# rebuild to rotate.
#
# root:admin 0750 — admin can `source` the file directly without sudo, agent
# gets Permission denied. ext4 either way, so it is enforced.
RUN mkdir -p /srv/secrets \
 && chown root:admin /srv/secrets \
 && chmod 2770 /srv/secrets

# ── workspace ────────────────────────────────────────────────────────────────
# Just the mountpoint. The named volume mounts OVER this at runtime and hides
# whatever ownership is set here, so up.sh re-applies it after start.
# setgid (2775) so new files land in the devs group.
RUN mkdir -p /workspace \
 && chown agent:devs /workspace \
 && chmod 2775 /workspace

# ── ssh keys ─────────────────────────────────────────────────────────────────
# Keys live in /etc/ssh/authorized_keys/<user>, root-owned, not in the users'
# home directories. Two reasons:
#   1. agent cannot add its own key to gain a second way in.
#   2. /home/agent is a volume mount, which would otherwise hide a key placed
#      at /home/agent/.ssh/authorized_keys and lock you out on first boot.
RUN mkdir -p /etc/ssh/authorized_keys \
 && printf '%s\n' "$ADMIN_KEY" > /etc/ssh/authorized_keys/admin \
 && printf '%s\n' "$AGENT_KEY" > /etc/ssh/authorized_keys/agent \
 && chown -R root:root /etc/ssh/authorized_keys \
 && chmod 0755 /etc/ssh/authorized_keys \
 && chmod 0644 /etc/ssh/authorized_keys/admin /etc/ssh/authorized_keys/agent

# ── sshd ─────────────────────────────────────────────────────────────────────
# Self-contained config — no Include, so a stray drop-in cannot re-enable
# password auth or leak past the Match block.
RUN rm -f /etc/ssh/sshd_config.d/*.conf
COPY <<'EOF' /etc/ssh/sshd_config
Port 22
PermitRootLogin no
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
AuthorizedKeysFile /etc/ssh/authorized_keys/%u
UsePAM yes
AllowUsers admin agent
X11Forwarding no
PrintMotd no
ClientAliveInterval 60
AcceptEnv LANG LC_*
Subsystem sftp /usr/lib/openssh/sftp-server

Match User agent
    AllowAgentForwarding no
    PermitTunnel no
    PermitUserRC no
EOF

# pam_loginuid fails without a real audit subsystem in the VM.
RUN sed -i 's@^session\s\+required\s\+pam_loginuid.so@session optional pam_loginuid.so@' /etc/pam.d/sshd \
 && ssh-keygen -A

EXPOSE 22
CMD ["/usr/sbin/sshd", "-D", "-e"]
