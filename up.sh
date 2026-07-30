#!/usr/bin/env bash
# =============================================================================
# agentbox — bring up one dev instance described by a YAML file.
#
#     ./up.sh instances/myapp.yml
#
# Safe to re-run; every step is idempotent. A second dev box is just another
# YAML file with a different name, network, and subnet.
#
# -----------------------------------------------------------------------------
# WHAT THIS SETUP IS
# -----------------------------------------------------------------------------
# One VM per instance, with two Linux users inside:
#   admin (uid 1000) — you. sudo, reads /srv/secrets, starts the servers.
#   agent (uid 2000) — Claude Code. owns /workspace, cannot read /srv/secrets.
#
# You open VS Code Remote-SSH as `agent` and run Claude Code in its terminal.
# In a separate terminal you ssh in as `admin` and start the app with the real
# env loaded. Claude Code edits files; it never sees the credentials.
#
# -----------------------------------------------------------------------------
# WHAT IT DOES AND DOES NOT PROTECT AGAINST
# -----------------------------------------------------------------------------
# Covers what actually happens by accident: the agent grepping the repo for
# keys, cat-ing an .env because a command failed, a credential landing in the
# model's context and from there into a log or a commit.
#
# Does NOT cover deliberate exfiltration. The agent writes the code that admin
# later executes, so a payload in package.json / Makefile / conftest.py /
# .git/hooks runs as admin with the secrets in its environment. Accepted by
# decision. The only real fix is to keep production credentials out of the box
# and give it dev/staging values.
#
# -----------------------------------------------------------------------------
# HOW YOU REACH THE BOX  (three different things, easy to conflate)
# -----------------------------------------------------------------------------
#   1. you -> container, ssh      no mapping. The container has its own IP and
#                                 sshd listens on 22 there:
#                                     ssh admin@<container-ip>
#   2. you -> container, app      published ports from the YAML, so that
#                                 http://localhost:5174 works on your Mac.
#   3. container -> your tunnel   no mapping. Bind the tunnel on your Mac to
#                                 this instance's gateway and the container
#                                 dials that address. See the end of this file.
#
# ssh is not published because publishing binds a port on the *host*, and host
# port 22 needs root — the daemon runs as you. Nothing is lost: the container
# IP is directly reachable.
#
# Container IPs are DHCP and move between restarts, so the script registers a
# local DNS domain (`domain:` in the YAML, default `internal`) and you use
# <name>.internal instead. That step needs `sudo` — it writes an /etc/resolver
# entry — so expect one password prompt the first time and never again. If you
# decline it, everything still works, you just get raw IPs.
#
# -----------------------------------------------------------------------------
# FACTS ABOUT `container` 1.0.0 THAT SHAPE THIS FILE (verified on this machine)
# -----------------------------------------------------------------------------
# 1. Bind mounts (-v /host/path:/x) are virtiofs and enforce NO permissions.
#    Everything appears as root:root and any user can read or write it — uid
#    2000 read a root-owned 0600 file straight through. chown/chmod on the
#    mountpoint return "Operation not permitted". That is why /workspace is a
#    named volume, not a bind mount of a host directory.
# 2. Named volumes are ext4 and DO enforce permissions. Default size is 512 GiB
#    sparse, so there is no reason to pass -s.
# 3. A fresh volume mounts as root:root 0755 and the mount hides whatever the
#    image set at that path. Hence the chown step below. It only matters on the
#    first boot — ext4 keeps the ownership — but re-running costs nothing.
# 4. Each named network gets its own bridge, and they are isolated: a container
#    on 192.168.100.0/24 reached a host listener on 192.168.100.1, while a
#    container on the default network was refused. That is what makes a
#    per-instance network worth the trouble.
# 5. Container IPs are DHCP and move between restarts (.2, .10, .11, .13 seen).
#    Gateways do not — they are pinned in the network object.
# 6. Env vars do not leak between users: agent gets Permission denied on
#    admin's /proc/<pid>/environ. Command lines DO leak via `ps`, so load
#    secrets with `set -a; . /srv/secrets/app.env; set +a` and never pass them
#    as CLI flags.
# 7. There is no restart policy. After a host reboot:  container start <name>
# 8. Build contexts under /private/tmp silently transfer as empty, an empty
#    directory in the context breaks COPY, and --build-arg values land in the
#    image history (fine here — they are public keys).
#
# -----------------------------------------------------------------------------
# DELIBERATELY NOT DONE YET
# -----------------------------------------------------------------------------
# - Copying the real app.env in. /srv/secrets is an empty volume, root:admin
#   2770. See the commented block near the bottom — one-time, the volume
#   outlives the container.
# - A fake/dev .env for the agent. Right now the agent cannot start the app, so
#   it cannot verify its own work — and an agent that cannot verify its work
#   will go hunting for why the app will not boot, which points it at the real
#   env file.
# - /opt/privileged scripts were dropped. As specced (root:admin 0750) the
#   agent could not execute them anyway. For run-but-not-read later, keep the
#   script 0700 root:root and add a narrow sudoers rule:
#       agent ALL=(root) NOPASSWD: /opt/privileged/foo
# =============================================================================

set -euo pipefail

cd "$(dirname "$0")"

CONF=${1:-}
if [ -z "$CONF" ]; then
  echo "usage: $0 instances/<name>.yml" >&2
  exit 1
fi
if [ ! -f "$CONF" ]; then
  echo "!! no such instance file: $CONF" >&2
  exit 1
fi

# ── 0. read the instance file ────────────────────────────────────────────────
# A deliberately small reader: flat `key: value` lines plus one `ports:` list.
# Neither yq nor PyYAML is installed here, and hand-rolled parsers start lying
# to you the moment you allow nesting — so the schema stays flat.
yml_scalar() {
  sed -e 's/#.*$//' "$CONF" \
    | awk -v k="$1" 'index($0, k ":") == 1 { sub(/^[^:]*:[[:space:]]*/, ""); print; exit }' \
    | tr -d "\"'" \
    | sed -e 's/[[:space:]]*$//'
}

# Reads a `key:` list of `- item` lines. Keeps internal spaces, since a service
# entry is several space-separated tokens.
yml_list() {
  sed -e 's/#.*$//' "$CONF" \
    | awk -v k="$1" '
        index($0, k ":") == 1 { inlist = 1; next }
        inlist && /^[[:space:]]*-[[:space:]]*[^[:space:]]/ {
            sub(/^[[:space:]]*-[[:space:]]*/, ""); print; next }
        inlist && /^[^[:space:]]/ { inlist = 0 }
      ' \
    | tr -d "\"'" \
    | sed -e 's/[[:space:]]*$//' \
    | grep -v '^$' || true
}

NAME=$(yml_scalar name)
NETWORK=$(yml_scalar network)
SUBNET=$(yml_scalar subnet)
CPUS=$(yml_scalar cpus); CPUS=${CPUS:-4}
MEMORY=$(yml_scalar memory); MEMORY=${MEMORY:-8g}
DOMAIN=$(yml_scalar domain); DOMAIN=${DOMAIN:-internal}
SSH_KEY=$(yml_scalar ssh_key)

for req in NAME NETWORK SUBNET SSH_KEY; do
  eval "v=\$$req"
  [ -n "$v" ] || { echo "!! $CONF is missing '$(echo $req | tr A-Z a-z):'" >&2; exit 1; }
done

# Your own public key, authorised for both users. The script generates nothing
# and touches nothing in ~/.ssh — it only reads the file named here.
PUBKEY_PATH=${SSH_KEY/#\~/$HOME}
if [ ! -f "$PUBKEY_PATH" ]; then
  echo "!! ssh_key: no such file: $PUBKEY_PATH" >&2
  exit 1
fi
case "$(cat "$PUBKEY_PATH")" in
  ssh-*|ecdsa-*|sk-*) ;;
  *) echo "!! ssh_key: $PUBKEY_PATH does not look like a public key" >&2; exit 1 ;;
esac
PUBKEY=$(cat "$PUBKEY_PATH")
IDENTITY=${PUBKEY_PATH%.pub}     # the private half, for the printed ssh config

# One image per instance, since the authorised key is baked in at build time
# and two instances may not use the same key.
IMAGE=agentbox-$NAME:latest

# Every resource is named off the instance, so instances never collide.
WORKSPACE_VOL=$NAME-workspace
AGENT_HOME_VOL=$NAME-agent-home
SECRETS_VOL=$NAME-secrets

# The gateway is always the .1 of the subnet. This is the address your ssh
# tunnel must bind to on the Mac for this instance to reach it.
GATEWAY=$(printf '%s' "$SUBNET" | awk -F'[./]' '{print $1"."$2"."$3".1"}')

# Published ports. A bare host:container pair is bound to 127.0.0.1 so nothing
# lands on your network by accident; write 0.0.0.0:5174:5174 if you want that.
PUBLISH=()
while IFS= read -r p; do
  [ -n "$p" ] || continue
  if ! printf '%s' "$p" | grep -Eq '^([0-9]{1,3}(\.[0-9]{1,3}){3}:)?[0-9]+:[0-9]+(/(tcp|udp))?$'; then
    echo "!! $CONF: cannot parse port entry '$p'" >&2
    exit 1
  fi
  case "$p" in
    *.*.*.*:*) ;;                 # already has a bind address
    *)         p="127.0.0.1:$p" ;;
  esac
  PUBLISH+=("$p")
done < <(yml_list ports | tr -d ' ')

# Sidecars: `name=image [/data/path] [KEY=VALUE ...]`, one per line. Each runs
# on this instance's network as <instance>-<name>, so the app reaches it at
# <instance>-<name>.<domain> — no ports published, nothing else can see it.
SERVICES=()
while IFS= read -r s; do
  [ -n "$s" ] && SERVICES+=("$s")
done < <(yml_list services)

echo "==> instance   $NAME"
echo "==> network    $NETWORK  $SUBNET  (gateway $GATEWAY)"
echo "==> resources  ${CPUS} cpus, ${MEMORY}"
echo "==> publishing ${PUBLISH[*]-<none>}"
echo "==> hostname   $NAME.$DOMAIN"

# ── 1. image ─────────────────────────────────────────────────────────────────
# The same public key authorises both users. Which one you land on is decided
# by the username you ssh as, not by the key. That is fine: the boundary that
# matters is between the two Unix users inside the container, and Claude Code
# has no private key in there to ssh back out with.
#
# What would break it is agent forwarding. If your agent socket reached the
# container, the `agent` user could authenticate as `admin` with your key — and
# to every other host that key opens. The image's sshd_config already refuses
# it for that user (Match User agent / AllowAgentForwarding no), which is what
# makes reusing your own key safe here.
echo "==> building $IMAGE from $PUBKEY_PATH"
container build -t "$IMAGE" \
  --build-arg ADMIN_KEY="$PUBKEY" \
  --build-arg AGENT_KEY="$PUBKEY" \
  .

# ── 3. network ───────────────────────────────────────────────────────────────
# Its own bridge, so this instance's ssh tunnel is not reachable from any other
# container you happen to be running.
if container network inspect "$NETWORK" >/dev/null 2>&1; then
  echo "==> network $NETWORK already exists"
else
  echo "==> creating network $NETWORK ($SUBNET)"
  container network create --subnet "$SUBNET" "$NETWORK"
fi

# ── 3b. dns domain ───────────────────────────────────────────────────────────
# Registers <name>.$DOMAIN so you never chase a DHCP address. Needs sudo once,
# per domain, not per instance — it writes /etc/resolver/$DOMAIN, which only
# root can do. Declining is not fatal: the script falls back to raw IPs.
#
# `.internal` is reserved by ICANN for private networks, so it cannot collide
# with a real domain. `.test` (RFC 6761) is equally safe if you prefer it.
# Do not use `.local` — that is mDNS and will fight Bonjour. Do not use `.dev`
# — it is a real TLD with HSTS preloaded, so browsers force https on it.
#
# Must happen before the container starts, so the name is registered on boot.
DNS_OK=no
if container system dns list 2>/dev/null | awk -v d="$DOMAIN" 'NR>1 && $1==d {found=1} END{exit !found}'; then
  echo "==> dns domain '$DOMAIN' already registered"
  DNS_OK=yes
else
  echo "==> registering dns domain '$DOMAIN' — sudo, once for every instance"
  if sudo container system dns create "$DOMAIN"; then
    DNS_OK=yes
  else
    echo "!! could not register '$DOMAIN'; carrying on with raw IPs" >&2
  fi
fi

# ── 4. volumes ───────────────────────────────────────────────────────────────
# These outlive the container. `container delete $NAME` does not touch them;
# only `container volume delete` does. So recreating the box keeps your code,
# Claude Code's login, and your .env files.
for v in "$WORKSPACE_VOL" "$AGENT_HOME_VOL" "$SECRETS_VOL"; do
  if container volume inspect "$v" >/dev/null 2>&1; then
    echo "==> volume $v already exists"
  else
    echo "==> creating volume $v"
    container volume create "$v"
  fi
done

# ── 4b. sidecars ─────────────────────────────────────────────────────────────
# Recreated on every run, like the main container. A bare sidecar keeps nothing
# across runs; give it a /path token and that path gets a named volume
# (<instance>-<name>-data) which survives, the same way the main volumes do.
for s in ${SERVICES[@]+"${SERVICES[@]}"}; do
  first=${s%% *}                      # name=image
  rest=${s#"$first"}                  # optional /path and KEY=VALUE tokens
  svc=${first%%=*}
  img=${first#*=}
  if [ -z "$svc" ] || [ -z "$img" ] || [ "$svc" = "$first" ]; then
    echo "!! $CONF: bad service entry '$s' (expected name=image)" >&2
    exit 1
  fi

  cname=$NAME-$svc
  svc_args=()
  for tok in $rest; do
    case "$tok" in
      /*)
        svc_vol=$NAME-$svc-data
        container volume inspect "$svc_vol" >/dev/null 2>&1 \
          || container volume create "$svc_vol" >/dev/null
        svc_args+=(-v "$svc_vol:$tok")
        ;;
      *=*) svc_args+=(-e "$tok") ;;
      *)
        echo "!! $CONF: bad token '$tok' in service '$svc' — expected /path or KEY=VALUE" >&2
        exit 1
        ;;
    esac
  done

  if container inspect "$cname" >/dev/null 2>&1; then
    container stop "$cname" >/dev/null 2>&1 || true
    container delete "$cname" >/dev/null 2>&1 || true
  fi
  echo "==> sidecar $cname ($img) -> $cname.$DOMAIN"
  container run -d --name "$cname" --network "$NETWORK" \
    ${svc_args[@]+"${svc_args[@]}"} "$img" >/dev/null
done

# ── 5. replace the container ─────────────────────────────────────────────────
if container inspect "$NAME" >/dev/null 2>&1; then
  echo "==> removing existing container $NAME (volumes are untouched)"
  container stop "$NAME" >/dev/null 2>&1 || true
  container delete "$NAME" >/dev/null 2>&1 || true
fi

publish_args=()
for p in ${PUBLISH[@]+"${PUBLISH[@]}"}; do publish_args+=(-p "$p"); done

echo "==> starting $NAME"
container run -d --name "$NAME" --init \
  --network "$NETWORK" \
  --cpus "$CPUS" --memory "$MEMORY" \
  ${publish_args[@]+"${publish_args[@]}"} \
  -v "$WORKSPACE_VOL:/workspace" \
  -v "$AGENT_HOME_VOL:/home/agent" \
  -v "$SECRETS_VOL:/srv/secrets" \
  --ulimit core=0 \
  "$IMAGE"

# Never add --ssh (forwards your host ssh-agent into the container, where the
# agent user could use your keys) or --virtualization to this container.

# ── 6. runtime permissions ───────────────────────────────────────────────────
echo "==> waiting for the container to accept exec"
for _ in $(seq 1 30); do
  container exec "$NAME" true >/dev/null 2>&1 && break
  sleep 1
done

echo "==> fixing volume ownership"
# Every volume comes up root:root 0755 the first time, and the mount hides
# whatever the image set at that path. Without this the agent cannot write to
# its own workspace or home directory, and /srv/secrets would be world-readable.
# This runs before any secret is copied in, so there is never a moment where an
# agent-readable .env exists.
container exec "$NAME" sh -c '
  set -e
  chown -R agent:devs /workspace
  chmod 2775 /workspace

  # seed the home directory the volume just covered up
  cp -rn /etc/skel/. /home/agent/ 2>/dev/null || true
  chown -R agent:agent /home/agent
  chmod 700 /home/agent

  # secrets: admin reads AND writes, agent gets Permission denied. ext4, so it
  # is enforced. 2770 rather than 0750 so admin can create files and folders in
  # here without sudo; setgid keeps new subdirectories in the admin group.
  chown -R root:admin /srv/secrets
  chmod 2770 /srv/secrets
  find /srv/secrets -type d -exec chmod 2770 {} +
  find /srv/secrets -type f -exec chmod 0660 {} +
'

# ── 7. secrets — fill this in when you are ready ─────────────────────────────
# /srv/secrets is a volume, root:admin 0750. Because it is a volume this is a
# one-time step: the files survive `container delete` and every later rebuild.
# Copying at runtime rather than baking into the image also means rotating a
# key is not a rebuild, and the secret never ends up in an image layer that
# `container image save` would carry off.
#
# Use scp, NOT `container cp` — cp cannot write through a volume mount. It
# prints the destination, exits 0, and nothing lands. Verified on 1.2.0.
#
# if [ -f "secrets/$NAME.env" ]; then
#   scp "secrets/$NAME.env" "$NAME-admin:/srv/secrets/app.env"
#   container exec "$NAME" chmod 0660 /srv/secrets/app.env
# fi
#
# Note: uncommenting makes the host copy the source of truth — every up.sh run
# overwrites what is in the volume. If you would rather edit the file inside
# the box (ssh admin@<ip>, vi /srv/secrets/app.env), leave this commented and
# run the three lines by hand once. Keep secrets/ out of git either way.

# ── done ─────────────────────────────────────────────────────────────────────
# container inspect escapes the CIDR slash, so the raw value looks like
# "192.168.101.2\/24" — strip at the backslash as well as the slash, or the
# address comes out with a trailing backslash.
IP=$(container inspect "$NAME" 2>/dev/null \
     | grep -m1 'ipv4Address' \
     | sed -e 's/.*: "//' -e 's/\\.*//' -e 's|/.*||' -e 's/".*//')

# Prefer the name over the address, but only once it actually resolves — the
# resolver entry is read by macOS's system resolver, so this checks with
# dscacheutil rather than dig, which reads /etc/resolv.conf and would miss it.
SSH_HOST=$IP
if [ "$DNS_OK" = yes ]; then
  for _ in 1 2 3 4 5; do
    if dscacheutil -q host -a name "$NAME.$DOMAIN" 2>/dev/null | grep -q '^ip_address'; then
      SSH_HOST=$NAME.$DOMAIN
      break
    fi
    sleep 1
  done
  if [ "$SSH_HOST" = "$IP" ]; then
    echo "!! $NAME.$DOMAIN is not resolving yet — using the IP for now" >&2
  fi
fi

SIDECAR_BLOCK=""
for s in ${SERVICES[@]+"${SERVICES[@]}"}; do
  first=${s%% *}
  SIDECAR_BLOCK="$SIDECAR_BLOCK
    ${NAME}-${first%%=*}.$DOMAIN   (${first#*=})"
done
if [ -n "$SIDECAR_BLOCK" ]; then
  SIDECAR_BLOCK="
Sidecars, reachable only from this instance — no ports published:
$SIDECAR_BLOCK
"
fi

cat <<DONE

==> $NAME is up at $IP  ($SSH_HOST)
$SIDECAR_BLOCK

Add to ~/.ssh/config, above any \`Host *\` block:

    Host $NAME-agent
        HostName $SSH_HOST
        User agent
        IdentityFile $IDENTITY
        IdentitiesOnly yes
        ForwardAgent no

    Host $NAME-admin
        HostName $SSH_HOST
        User admin
        IdentityFile $IDENTITY
        IdentitiesOnly yes
        ForwardAgent no

ForwardAgent is off for both. Turn it on for -admin only if you need your key
inside for a git push, and prefer \`ssh -A $NAME-admin\` for that one command
over making it permanent. sshd refuses forwarding for \`agent\` regardless.

VS Code Remote-SSH -> $NAME-agent.   Servers -> ssh $NAME-admin.

Written once and never edited again: the IP moves between restarts, the name
does not.

Your app, from the Mac:  http://localhost:5174     (the published ports)
                         http://$SSH_HOST:5174     (works with nothing published)

Staging database, tunnelled from your Mac into this instance — bind it to this
instance's gateway, not to localhost, or the container cannot reach it:

    ssh -N -L $GATEWAY:5432:db.internal:5432 staging

then inside the box the app connects to $GATEWAY:5432.

Starting a server as admin — keep secrets out of argv, \`ps\` is world-readable,
and bind to 0.0.0.0 or the published port has nothing to forward to:

    ssh $NAME-admin
    set -a; . /srv/secrets/app.env; set +a
    cd /workspace && ./run-whatever --host 0.0.0.0

Check the boundary holds:

    ssh $NAME-agent 'ls -la /srv/secrets'   # Permission denied
    ssh $NAME-agent 'ls /home/admin'        # Permission denied
    ssh $NAME-agent 'sudo -l'               # not allowed

After a host reboot:  container start $NAME
DONE
