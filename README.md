# Veydan Server

This installer sets up your own server for the Veydan messenger apps on a clean Debian 13.
It can install five parts: a relay (strfry), a media server (blossom-server with its own index), a push server (VPush), a call node and a bridge (VLink).
Nginx stands in front of them and Let's Encrypt gives the certificates.
Everything runs as systemd services. There is no docker on the server.
You can run one server, or join several into one network.

## Requirements

- A clean Debian 13, x86_64, and root.
- A domain you control, with an A record for each name: relay, media and push (for example `relay.example.org`).
- Ports 80 and 443 open.
- If you install calls, also: 8443/tcp (control), 3478 udp+tcp, 3479 udp+tcp (SFU), 49152-49999/udp (relay range).

## Install

```sh
curl -fsSL https://raw.githubusercontent.com/veydanproject/Veydan-Server/main/install.sh | sudo bash
```

The installer asks:

1. Which parts to install: `relay media vpush call bridge`.
2. Your domain, and the short name of each part (`relay`, `media`, `push` become `relay.<domain>` and so on).
3. Where media files live: this server's disk, or an S3 bucket (endpoint, bucket, region, keys).
4. An e-mail for Let's Encrypt.
5. A region, a short word such as `eu` or `us`.

Then it shows the DNS records to add and waits for you.
It checks that every name points to this server before it asks for certificates.
Then it installs, and prints a card: the relay address and its key, the media and push addresses, and the reference of the call node.
The same card is saved in `/opt/veydan/server.txt` (root only).

To use the server in the app: Settings → Servers → Own servers → add the relay with its key, as the card says.

## Without questions

Copy `server.conf.example` to `server.conf`, edit it, put it beside `install.sh`, and run:

```sh
sudo bash install.sh --yes
```

Options:

- `--yes` asks nothing; a missing answer keeps its default.
- `--config <file>` takes the answers from another file.
- `--lang ru` asks the questions in Russian (the `LANG` of the shell is also read).
- `--dry-run` prints what would be done and writes the files to a temporary folder.
- `--add call` adds a component to a server that is already installed.

Your answers are saved in `/opt/veydan/server.conf`.
A rerun reads that file and asks nothing.
The two keys are made on the first run when empty, and never change after that.

The main settings (all are described in `server.conf.example`):

| Setting | Meaning |
|---|---|
| `BASE_DOMAIN` | Your domain. Short names are completed with it. |
| `COMPONENTS` | What runs here: `relay media vpush call`. |
| `RELAY_HOST`, `MEDIA_HOST`, `VPUSH_HOST` | The names of this server's parts. |
| `SERVER`, `REGION`, `NETWORK` | Short words. Empty: taken from the names. |
| `S3_ENDPOINT`, `S3_BUCKET`, `S3_REGION`, `S3_ACCESS_KEY`, `S3_SECRET_KEY` | A shared bucket for media. Empty endpoint: files stay on the disk. |
| `TLS`, `ACME_EMAIL` | `letsencrypt` (needs an e-mail) or `selfsigned` (for tests). |
| `FIREWALL` | `ufw` opens ssh, 80 and 443 and closes the rest; `none` leaves the firewall alone. |
| `ADMIN_PUBKEY` | Your nostr key, shown in the relay's NIP-11 document. May be empty. |
| `RELAY_NAME` | NIP-11 name of the relay. |
| `SKIP_DNS_CHECK` | `1`: do not compare DNS with this server's addresses (behind NAT). |

## Several servers

A network is several servers with the same network part of `server.conf`:
`BASE_DOMAIN`, `NETWORK`, `MESH_RELAYS`, `MESH_MEDIA`, `MESH_APP_KEY`, `MESH_PEER_KEY` and the `S3_*` settings.
On a server of the network, `veydan-server join-token` prints that part as one key.
On the new server, run the installer, answer `join` and paste the key; or run it with `--join <key>`.
It then asks a short word for the new server and makes its names from it (`m2` → `m2-relay.<domain>`), and adds them to its own `MESH_RELAYS` and `MESH_MEDIA`.
The key holds the keys of the network: give it to nobody else.

The servers that were there before do not learn the new names by themselves: their relays accept the new one (it connects to them both ways), but their push servers watch only the relays they know.
To tell them, add the new names to `MESH_RELAYS` and `MESH_MEDIA` in their `/opt/veydan/server.conf` and run `veydan-server rerun`.

After the installer, `veydan-server` is on the server: `show` (the card), `join-token`, `add <component>`, `status`, `rerun`.

- Every relay connects to every other relay and syncs with it every few minutes. An event published on one relay reaches all of them.
- With an S3 bucket, every media server serves every file. A server that has not got a file asks the bucket by its hash, with a signed request.
- With files on disks, each server serves what it took. For the rest it asks the next media server of `MESH_MEDIA`.
- The app key (in the manifest of every relay) and the peer key (relay to relay, push to relay) must differ.
- `MESH_ORIGINS="name=ipv4 ..."` lets the servers talk to each other by real addresses, past a CDN.

## Push

VPush needs a Firebase service account JSON for each app it serves.
Set `FCM_APPS="<app id> ..."` in `server.conf` and put `fcm-<app id>.json` beside the installer.
With one app in `FCM_APPS`, any `*.json` of a service account is accepted.
Without a key the installer warns, and you can add the file and run again.

Push to the official Veydan apps cannot come from a self-hosted server: their push key belongs to the project.
Your server serves apps built with your own key.
Bridges (VLink) and Veydan Cloud do not work with own servers.

## A bridge

A bridge (VLink) is a door into the Veydan network for people whose direct way to it is closed.
It keeps no keys of anyone and no data: it only passes encrypted bytes on.
Anybody may run one; the more there are, the harder they are to block.
It needs a server with a public IPv4 address **inside the country whose users you want to help**, and one free TCP port (443 is best).
No domain, no certificate, nothing to configure.

One command, either way:

```sh
# as a service of the system (Debian 13; any Linux with systemd should do)
curl -fsSL https://raw.githubusercontent.com/veydanproject/Veydan-Server/main/install.sh | sudo bash -s -- --bridge

# or in docker
docker run -d --name vlink --restart=unless-stopped --network=host -v vlink:/data rookbeam/vlink
```

The installer asks two things: the port (Enter keeps 443) and whether the bridge is open to anybody or private.
It downloads the program of the pinned version from its release (x86_64 or aarch64, checked against `SHA256SUMS`), starts it, opens the port in `ufw`, and prints the bridge's reference and its link:

```
Bridge  203.0.113.7:443#300d0089…
  veydan://vlink/300d0089…?a=203.0.113.7%3A443
```

- **Open** (the default): the bridge tells the registry of the network it exists and starts carrying traffic once a hub has reached it, within minutes. There is nothing more to do.
- **Private**: the bridge is told to nobody. Give the link to the people it is for; they add it in Chat → Settings → Network → Bridges → Add bridge.

Without questions: `… | sudo bash -s -- --bridge --yes` (port 443, open), or a `server.conf` beside the installer with `BRIDGE_PORT`, `BRIDGE_PRIVATE`, `BRIDGE_PUBLIC_IP`.
The bridge's key is in `/opt/vlink/data`: it *is* the bridge, keep it when you move the server.
Log: `journalctl -u vlink`. Update: run the same command again after a new version of this kit.

A bridge beside a relay, media or push on one server cannot have 80 or 443 (they are nginx's): give it another port, or a server of its own.

## Calls

The call node is the component `call`. Add it with `COMPONENTS` or `--add call`.
It is reached at the bare IP address of the server, not through nginx.

| Setting | Default | Meaning |
|---|---|---|
| `CALL_PUBLIC_IP` | this server's address | The public IPv4 of the node. |
| `CALL_PORT` | 8443 | Control and TURN/TLS, tcp. Not 80, 443 or 3478. |
| `CALL_SFU_PORT` | 3479 | The SFU, udp and tcp. |
| `CALL_RELAY_PORTS` | 49152-49999 | Media relay range, udp. Above 1023. |

Port 3478 (udp and tcp, STUN/TURN) is fixed.
Open all of these ports in the firewall of your provider.
The node's key and TURN secret are in `/opt/vcall/data/`. The key is the node's id: keep it.

## Where things live

| Component | Path | Kept on a rerun (a changed template is put beside it as `*.new`) | Rewritten on every run |
|---|---|---|---|
| Relay | `/opt/strfry` | `etc/strfry.conf`; the database | the systemd units, the router and sync settings |
| Media | `/opt/blossom` | `etc/config.yml` | the units; `etc/blossom.env` (S3 keys) |
| Media index | `/opt/libsql` | the data in `data/` | the unit |
| Push | `/opt/vpush` | your lines outside the kit block of `etc/vpush.toml`; `etc/secrets/` | the kit block of `vpush.toml`, the unit |
| Calls | `/opt/vcall` | `etc/vcall.env`; `data/` | the unit |
| Installer | `/opt/veydan` | `server.conf` | `server.txt`, the nginx files in `nginx/` |

Media files are kept 14 days since the last download, then removed.
This is set in `/opt/blossom/etc/config.yml`.

How the programs arrive:

- strfry is compiled on the server when the kit brings no binary. This takes 5-10 minutes on a small server. A swap file is added if memory is short, and removed after the build. The commit is checked against `versions.conf`.
- Deno and sqld are downloaded from their GitHub releases and checked by sha256 from `versions.conf`.
- blossom-server is cloned at a pinned commit.
- VPush and the call node come as binaries in the kit, or from their releases on GitHub (the versions in `versions.conf`, checked by the `SHA256SUMS` of the release) when the kit brings none. x86_64 only.

## Cloudflare

You can put Cloudflare in front of the names. The installer notices it and nginx trusts `CF-Connecting-IP` only from Cloudflare addresses.
Set these in the Cloudflare panel:

| Setting | Value | Why |
|---|---|---|
| SSL/TLS mode | Full (strict) | The server has a real certificate. `Flexible` gives a redirect loop. |
| Always Use HTTPS | off | Otherwise the first certificate is not issued. Nginx redirects to https itself. |
| Network → WebSockets | on | The relay uses websocket. |
| Bot Fight Mode | off | The apps are not browsers and would be blocked. |
| Browser Integrity Check | off | The same. |

Do not turn on "Under Attack" or challenge rules for these names.
If you use `MESH_ORIGINS`, servers of your network talk to each other past Cloudflare.

## Updates

- strfry, blossom-server, Deno, sqld: change the version (and sha256) in `versions.conf`, then run `install.sh` again.
- VPush and the call node: `install -m755 <new binary> /opt/<app>/bin/<app> && systemctl restart <app>` (the app is `vpush` or `vcall`).

## Checks

```sh
K=<app key from the card>
curl -s -o /dev/null -w '%{http_code}\n' -H 'Accept: application/nostr+json' https://relay.example.org/            # 401
curl -s -H 'Accept: application/nostr+json' "https://relay.example.org/?key=$K"                                     # NIP-11
curl -s -o /dev/null -w '%{http_code}\n' https://media.example.org/                                                 # 404
curl -s https://push.example.org/healthz
systemctl status strfry blossom vpush
journalctl -u strfry-router -n 20
```

The router log shows "Connected to" for each other relay.
Sync timer: `systemctl list-timers strfry-sync.timer`.
Last test: publish an event on one relay and read it from another; upload a file through one media server and download it through another.

## Limits

- There is no uninstall. A component removed from `COMPONENTS` is not removed from the server.
- Anyone with a nostr key can upload to blossom. Nginx limits the request rate, and a request to 20 MiB.
- The app key is inside the app, so anyone who has the app can query a relay with it. Message content stays encrypted, but metadata can be read.
- The strfry router does not check the TLS certificate of the other relay and writes its URL, with the peer key, to the journal. Keep the path between your servers trusted.
- The media index is per server. Without a shared bucket, a file is lost for the network if its server is gone.

## Licence

See `LICENSE` and `LICENSE-SUMMARY.md` in this folder.

Developed by Rookbeam Technologies LLC, USA
