# agentbox

Isolated dev containers for running a coding agent, built on [Apple `container`](https://github.com/apple/container).

Each instance is a Linux VM with two users. Claude Code runs as `agent` and edits
code. You log in separately as `admin` to start servers with the real credentials
loaded. The agent can't read them.

```
you ──ssh admin──▶ ┌──────────── myapp.internal ────────────┐
                   │  admin (1000)  sudo, reads /srv/secrets │
you ──ssh agent──▶ │  agent (2000)  owns /workspace          │
                   │                                          │
                   │  /workspace     ← code      (volume)     │
                   │  /srv/secrets   ← .env      (volume)     │
                   │  /home/agent    ← CC config (volume)     │
                   └──────────────────────────────────────────┘
```

## What this protects against

The things that actually happen by accident: the agent grepping the repo for
keys, `cat`-ing an `.env` because a command failed, a credential landing in the
model's context and from there into a log or a commit.

## What it does not

The agent writes the code that `admin` later executes. A payload in
`package.json`, `Makefile`, `conftest.py`, or `.git/hooks` runs as admin with
the secrets in its environment. This is a known, accepted trade-off. If you need
protection from that, don't put production credentials in the box — give it
dev/staging values.

## Requirements

`container` **1.2.0 or newer**. On 1.0.0 the DNS naming silently doesn't work —
containers never register with the local resolver, so `<name>.internal` returns
NXDOMAIN.

```bash
brew upgrade container
container --version
```

## Quick start

```bash
# 1. describe an instance
cp instances/example.yml instances/myapp.yml   # edit name, network, subnet

# 2. bring it up  (asks for sudo once, to register the DNS domain)
./up.sh instances/myapp.yml

# 3. paste the printed Host blocks into ~/.ssh/config, then
ssh myapp-admin
```

`up.sh` is idempotent — re-run it any time. It rebuilds the image, recreates the
container, and leaves your volumes alone.

## The instance file

```yaml
name: myapp                 # container name; volumes are myapp-workspace, etc.
network: myapp-net          # its own bridge, isolated from other instances
subnet: 192.168.101.0/24    # must not overlap; gateway is always .1
domain: internal            # reachable as myapp.internal from your Mac
ssh_key: ~/.ssh/id_ed25519.pub   # your key, authorised for both users
cpus: 8
memory: 24g
ports:                      # published to the Mac; ssh is NOT here
  - 5174:5174
  - 8080:8080
services:                   # sidecars on this instance's network
  - redis=redis:7-alpine
```

A second box is a copy of this file with a different `name`, `network`, and
`subnet`. Keep `domain` the same in all of them.

| key | notes |
|---|---|
| `name` | everything is named off this — container, volumes, hostname |
| `network` | one bridge per instance; a container on another network cannot reach this one's gateway |
| `subnet` | must be unique. `192.168.64.0/24` is the built-in default network — don't reuse it |
| `ssh_key` | a **public** key path. The script reads it and nothing else in `~/.ssh` |
| `ports` | host side must be unique across instances. A bare pair binds `127.0.0.1`; write `0.0.0.0:5174:5174` to expose to your LAN |
| `services` | sidecar containers — see below |

## Sidecars

Databases and caches run as their own containers on the instance's network,
declared in the YAML:

```yaml
services:
  - redis=redis:7-alpine
  - pg=postgres:16-alpine /var/lib/postgresql/data POSTGRES_PASSWORD=dev POSTGRES_DB=app
```

Format is `name=image [/path/to/persist] [KEY=VALUE ...]`.

Each runs as `<instance>-<name>` and answers to `<instance>-<name>.internal`, so
your app config reads:

```
REDIS_URL=redis://myapp-redis.internal:6379
DATABASE_URL=postgres://postgres:dev@myapp-pg.internal:5432/app
```

No ports are published for sidecars — nothing outside the instance can reach
them, not even your other containers, because each instance has its own bridge.

A `/path` token gets that path a named volume (`<instance>-<name>-data`) which
survives rebuilds. Without one, the sidecar keeps nothing — fine for a cache,
not for a database you care about.

Sidecars are recreated on every `up.sh` run, like the main container, and come
back with `container start <instance>-<name>` after a host reboot.

Names resolve **inside** the container, not just from your Mac. One quirk: they
resolve to IPv6 addresses. That worked with every client tested, but if a
library chokes on it, use the IP from `container ls`.

## Day to day

**Edit code** — VS Code Remote-SSH to `<name>-agent`. Claude Code runs in that
terminal, as `agent`.

**Run servers** — separate terminal, as admin:

```bash
ssh myapp-admin
set -a; . /srv/secrets/app.env; set +a
cd /workspace && ./run-whatever --host 0.0.0.0
```

Load secrets by sourcing a file, never as command-line flags — `ps` is readable
by every user in the container, including `agent`. And bind to `0.0.0.0`, or the
published port has nothing to forward to.

**Add secrets** — `/srv/secrets` is `root:admin 2770`, on its own volume. Admin
can create files and folders there directly; `agent` can't even list it.

```bash
ssh myapp-admin
vi /srv/secrets/app.env
```

Or from the Mac, with `scp` — **not** `container cp`, see the gotcha below:

```bash
scp .env.staging myapp-admin:/srv/secrets/myrepo.env
```

**Point your app at a secret without moving it** — symlink from the repo into
`/srv/secrets`, as admin:

```bash
ln -s /srv/secrets/myrepo/.env.staging \
      /workspace/repos/myrepo/.env
```

Real file first, link second. Admin can create it because `/workspace` is
`agent:devs 2775` and admin is in `devs`.

This is the whole point of the split: the link is visible to `agent` and the
framework finds `.env` exactly where it expects, but following it lands in
`/srv/secrets`, so the agent gets `Permission denied` on the contents. Your app,
started as admin, reads it fine.

Three things that bite:

- **Use an absolute target.** A relative one resolves from the *link's*
  directory, not your shell's, so it silently points at nothing.
- **`ls` shows a broken link happily; `cat` is what tells you.** A dangling link
  gives `cat: ...: No such file or directory` even though `ls` printed the name.
  `ls -l` shows where it actually points.
- **To replace an existing link**, `ln -sfn target link`. Without `-n`, if the
  old link points at a directory, you get the new link created *inside* it.

Caveat, consistent with the threat model: `agent` owns `/workspace`, so it can
delete that symlink and drop its own file there. It still can't read the
original.

**Reach a database through an ssh tunnel** — bind the forward to the instance's
gateway, not to `localhost`. The container is a separate machine; your Mac's
loopback is invisible to it.

```bash
ssh -N -L 192.168.101.1:5432:db.internal:5432 staging
```

Inside the box, connect to `192.168.101.1:5432`. Because each instance has its
own bridge, only this instance can reach that tunnel.

**Git as the agent** — agent forwarding is refused for `agent` by design
(`Match User agent / AllowAgentForwarding no`), so your key can never be used
from a Claude Code session. Either clone as admin, or give agent a deploy key
scoped to the one repo.

## What persists

Volumes outlive the container. `container delete myapp` doesn't touch them; only
`container volume delete` does.

| volume | holds |
|---|---|
| `<name>-workspace` | your code |
| `<name>-secrets` | `.env` files |
| `<name>-agent-home` | Claude Code's login and config |

`/workspace` starts **empty** — it's a volume, not a bind mount of a host
directory. Get code in with `git clone` inside, or `container cp` from the Mac.

## Why volumes instead of a host bind mount

Bind mounts under Apple `container` are virtiofs and **enforce no permissions at
all**. Everything appears as `root:root`, and any user can read or write it —
uid 2000 will happily read a root-owned `0600` file. `chown` and `chmod` on the
mountpoint fail outright. Named volumes are ext4, where permissions are real,
which is the only reason the admin/agent split means anything.

## Gotchas

- **Ports are one-way.** `-p` maps host → container. There is no reverse mapping,
  so `localhost` inside the container is the container. To reach your Mac, use
  the gateway address.
- **ssh isn't published.** The container has its own IP with sshd on 22.
  Publishing host port 22 would need root anyway.
- **Published ports are fixed at create time.** Changing `ports:` means re-running
  `up.sh`, which recreates the container. Volumes survive.
- **Container IPs move** between restarts; the gateway and the DNS name don't.
- **No restart policy.** After a host reboot: `container start myapp`.
- **Never pass `--ssh` or `--virtualization`** to these containers. `--ssh`
  forwards your Mac's agent socket in, where `agent` could use your keys.
- **`container cp` cannot write into a volume.** It prints the destination and
  exits 0, and nothing lands. It only works on the container's own filesystem
  (`/tmp` and the like), not on `/workspace` or `/srv/secrets`. Use `scp` to
  `<name>-admin`, or copy to `/tmp` and `container exec ... mv` it into place.

## Troubleshooting

**Build fails, `apt-get` can't reach the network.** Containers can reach their
gateway but nothing beyond it — macOS's vmnet NAT has stopped forwarding, which
happens after sleep or a wifi change. Restart the services:

```bash
container system stop && container system start
container run --rm ubuntu:24.04 bash -c 'timeout 5 bash -c "exec 3<>/dev/tcp/1.1.1.1/443" && echo NET-OK || echo NET-DEAD'
```

If it's still `NET-DEAD`, reboot the Mac — vmnet belongs to macOS, not to
`container`.

**`<name>.internal` doesn't resolve.** Check you're on `container` 1.2.0+. Then
`container system dns list` should show your domain, and
`dig @127.0.0.1 -p 2053 myapp.internal +short` should return the IP. `up.sh`
falls back to the raw IP automatically and tells you when it does.

**Agent forwarding not working for git.** Your key has to be in your Mac's agent
first — `ForwardAgent` forwards the agent socket, not the key file:

```bash
ssh-add -l                                       # on the Mac
ssh-add --apple-use-keychain ~/.ssh/id_ed25519   # if empty
```

Then inside: `echo $SSH_AUTH_SOCK` must be non-empty and `ssh-add -l` must list
the key. If you're running as `agent`, it will never work — that's deliberate.

## Files

```
Dockerfile              users, sudoers, sshd, /srv/secrets and /workspace mountpoints
up.sh                   build, network, volumes, run, fix permissions
instances/<name>.yml    one file per dev box
```

## License

MIT — see [LICENSE](LICENSE).
