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

To use the server in the app, open the link the installer prints ("Link for the app"): the app asks "Add a server?" and adds it.
How a team uses it is in "A private server for a team", below.

### What the installer checks

`install.sh` is small: it downloads the kit of its version (`veydan-server-<version>.tar.gz`) from the release of that version and runs it.
Before it unpacks anything, it checks the kit twice: against `SHA256SUMS` of the release (a broken download), and against the signature of the Veydan Project, `veydan-server-<version>.tar.gz.sig` beside it.
The signature is made offline, with a key that never sits on GitHub or on a server, so a release changed on GitHub does not install: a kit without its `.sig`, or with one the key did not make over that very file, is refused and nothing is unpacked.
The programs it fetches later (the bridge, the call node, VPush) are checked the same way, each by its own `.sig`.
It needs `openssl` (Debian has it with `ca-certificates`).

The key is in `install.sh` and `lib/release.sh`, as `RELEASE_PUBKEY` (Ed25519, hex):

```
a809a6cf0b1ad6759ce497d75a9d1822ccc0cc68fb075e642ca95f33df2f3946
```

To check a kit by hand:

```sh
. lib/release.sh   # in a checkout of this repository
release_verify veydan-server-<version>.tar.gz server <version> veydan-server-<version>.tar.gz.sig && echo signed
```

The signature covers what the installer downloads, not the installer itself: if you do not trust the copy of `install.sh` you got, compare its `RELEASE_PUBKEY` with the one above.

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
| `RELAY_RETENTION_DAYS` | Days the relay keeps messages (gift wraps) and group events; a daily timer deletes older ones. `90` by default, `0` keeps for ever. |
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

After the installer, `veydan-server` is on the server: `show` (the card), `join-token`, `add <component>`, `status`, `rerun`, `push veydan|off`, `media-key required|open`.

- Every relay connects to every other relay and syncs with it every few minutes. An event published on one relay reaches all of them.
- With an S3 bucket, every media server serves every file. A server that has not got a file asks the bucket by its hash, with a signed request.
- With files on disks, each server serves what it took. For the rest it asks the next media server of `MESH_MEDIA`.
- A relay reaches the others through a local upstream of its own nginx (`127.0.0.1:7780`, `/opt/veydan/nginx/15-relay-peers.conf`, 0600 root): nginx checks the certificate of the peer and sends the peer key as a header, so the key is in no URL, argv or journal line of strfry. With `TLS=selfsigned` the certificate of a peer cannot be checked: the upstream does not check it and says so in its first line (tests only).
- The app key (in the manifest of every relay) and the peer key (relay to relay, push to relay) must differ.
- The peer key is also what makes a peer to the read policy of the relay (vguard, below): a connection with it reads everything, a connection with the app key only what its NIP-42 key may.
- `MESH_ORIGINS="name=ipv4 ..."` lets the servers talk to each other by real addresses, past a CDN.

## Push

VPush (the component `vpush`) watches the relay of your server and wakes the phones of its users when something arrives for them.
There are two ways to reach a phone.

**Through the push of the Veydan network** (`PUSH_GATEWAY=veydan`): for the official Veydan apps, whose push key belongs to the project.
The push server of the Veydan network acts as a gateway: a phone takes a ticket from it for its push token, and registers at your VPush with that ticket and a key of its own made for pushes alone.
Your VPush seals every push to that key, with a key of its own (`/opt/vpush/data/gateway.key`, made at its first start), and asks the gateway to wake the ticket.
The gateway learns the token of a device, the identity that took the ticket, the address and seal key of your server that wakes it, the times, the sizes and which wakes are calls (urgent): so it can tell which of its users use your server; it does not learn who wrote, in which chat, or what came.
No Firebase key is needed for this.
The installer of a server with a relay asks for it (`off`, the default, is what `--yes` keeps); answered `veydan` at the first run, it adds `vpush` to the components when it is not among them, under the name `<server>-push`.
Change it later with `veydan-server push veydan` or `veydan-server push off`, then `veydan-server rerun`; a rerun keeps the saved value.
The answer is also on the card of the server (`p=`).
With `off` your relay brings no push to the official apps, and they read it while they run.

**With a Firebase key of your own**, for apps built with your own key: VPush needs a Firebase service account JSON for each such app.
Set `FCM_APPS="<app id> ..."` in `server.conf` and put `fcm-<app id>.json` beside the installer.
With one app in `FCM_APPS`, any `*.json` of a service account is accepted.
Without a key the installer warns, and you can add the file and run again.
Both ways can be used at once.

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
It downloads the program of the pinned version from its release (x86_64 or aarch64, checked against `SHA256SUMS` and the signature of the Veydan Project), starts it, opens the port in `ufw`, and prints the bridge's reference and its link:

```
Bridge  203.0.113.7:443#300d0089…
  veydan://vlink/300d0089…?a=203.0.113.7%3A443
```

- **Open** (the default): the bridge tells the registry of the network it exists. A network may hold a new bridge until its owner approves it in the project's panel; then a hub reaches it, within minutes, and it carries traffic. There is nothing more to do.
- **Private**: the bridge is told to nobody. Give the link to the people it is for; they add it in Chat → Settings → Network → Bridges → Add bridge.

Without questions: `… | sudo bash -s -- --bridge --yes` (port 443, open), or a `server.conf` beside the installer with `BRIDGE_PORT`, `BRIDGE_PRIVATE`, `BRIDGE_PUBLIC_IP`.
The bridge's key is in `/opt/vlink/data`: it *is* the bridge, keep it when you move the server.
Log: `journalctl -u vlink`. Update: run the same command again after a new version of this kit.

A bridge beside a relay, media or push on one server cannot have 80 or 443 (they are nginx's): give it another port, or a server of its own.

## A bridge and a call node: helping the network

The project runs its servers outside the countries that close the way to them. Inside such a country it has nothing: the bridges there are volunteers', and so are the call nodes that make calls fast for people nearby.
One server with a public IPv4 address does both, by one command:

```sh
curl -fsSL https://raw.githubusercontent.com/veydanproject/Veydan-Server/main/install.sh | sudo bash -s -- --volunteer
```

It asks the port of the bridge (Enter keeps 443), whether the bridge is open or private, the public address of the server and a word for its region (`ru`, `eu`, …; Enter keeps `default`).
Then it downloads the two programs from their releases, starts them, opens their ports in `ufw` and prints both references.
Without questions: `… | sudo bash -s -- --volunteer --yes`.
A call node alone, where no bridge is needed (outside such a country): the same command with `--call`.

Both tell the registry of the Veydan network they exist. The network may hold a new bridge or node until its owner approves it; after that a hub reaches the bridge and it carries traffic, and the node carries the calls of people near it. There is nothing more to do.

Open in the firewall of your provider what the installer names at the end: the port of the bridge (443/tcp), and for calls 8443/tcp, 3478 and 3479 (udp and tcp) and 49152-49999/udp.

What each of them sees: a bridge — the address of a client and how much it sends, never who writes what to whom; a call node — addresses and volumes of a call, never the voice or the picture. Neither keeps keys or data of anyone.

The same in docker, one container each:

```sh
docker run -d --name vlink --restart=unless-stopped --network=host -v vlink:/data rookbeam/vlink
docker run -d --name vcall --restart=unless-stopped --network=host -v vcall:/data \
  -e VCALL_LISTEN=0.0.0.0:8443 -e VCALL_PUBLIC_IP=<your-ip> -e VCALL_REGISTRY=https://hub.veydan.net/vlink rookbeam/vcall
```

Their keys are in `/opt/vlink/data` and `/opt/vcall/data`: they *are* the bridge and the node, keep them when you move the server.
Logs: `journalctl -u vlink`, `journalctl -u vcall`. Update: the same command again after a new version of this kit.

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

## The card of the server

`veydan-server card` prints one link that adds this server to the app: its relay, the app key, the media server and the call node it has, the push setting and the name of the network.
The installer prints the same link at the end ("Link for the app").
The link holds the app key: give it to the people who may use the server, and to nobody else.

    veydan://server/<id>?u=<relay>&k=<app key>[&m=<media>][&c=<call node>][&pu=<push server>]&p=veydan|off&n=<network>

`<id>` is the first 16 hex digits of the sha256 of the relay address, so the app knows the server again from any card of it.
`veydan-server card --contact <npub>` prints a link to a contact that carries the server along (`veydan://contact/<npub>?srv=…`), for a person who has no server of the network yet.

## A private server for a team

A server of your own is a *private server* beside the Veydan network, not a replacement for it.
Your people keep their Veydan account and add your server to the app.
With every private server the app keeps separate chats and groups: they live on that server alone, and nothing of them goes to the servers of Veydan.
Two people may talk twice, once through Veydan and once on your server; these are two chats, each with its own messages and its own block.
A private chat is marked "Private · <name of the server>" in the list of chats.

Install the server (a relay at least; add `media` for files, `call` for calls and `vpush` for push) and take its link:

```sh
veydan-server card
```

The link holds the app key: give it to the people who may use the server and to nobody else.
Media takes an upload only with the key of the server (`MEDIA_UPLOAD_KEY=required`, the default of a new install; `open` turns it off, and a server installed before the setting stays `open`).

### You and a colleague who is in the Veydan network

1. Add the server to your own app first: open the link of `veydan-server card` and press "Add".
2. On the server, print a link to your contact that carries the server along:

   ```sh
   veydan-server card --contact <your npub>
   ```

3. Send it to the colleague by any way you have.
4. The colleague opens the link (or pastes it into "New chat").
   The app asks "Add a server?" and lists what it would add: the relay, the media, the call node, push, and whether it is a server of Veydan or not.
   Nothing is added until the colleague presses "Add".
5. After "Add" the private chat with you opens.
   The link is not an invitation, so the first message of the colleague reaches you as a request; you accept it as any other.
6. A link to a group that lives on your server brings a person who has not got the server to the same question first, and then into the group.
   The create form of the app does not offer a server yet: a group is put on a server with the command line of the messenger (`group-create --server`).

The colleague can remove the server in the settings; it goes from all of their devices, and its private chats go with it.

### You and a person you already talk to in the Veydan network

1. Add the server to your own app, as above.
2. In the chat with the person, share your contact and choose "Invite to a private chat on <the server>".
   The card of the server goes into the chat as a message.
3. The person presses "Add the server" and then "Open a private chat".
   A second, private chat with you opens at once, on both sides, with no request; the chat through Veydan stays as it was.

### Push

Without push the apps read your server while they run; a sleeping Android app learns of a message when it is opened.
To wake phones, answer `veydan` at the install, or later:

```sh
veydan-server push veydan   # or: veydan-server push off
veydan-server rerun
```

The push server of the Veydan network then acts as a gateway: it learns the token of a device, the identity that took the ticket, the address and seal key of your server, the times, the sizes and which wakes are calls; it does not learn who wrote, in which chat, or what came.
The VPush of your server does the rest, and no Firebase key is needed.
The gateway needs VPush 0.5.0 or newer (older versions refuse the `[gateway]` table, so the kit stops with a message) and a `vpush` on the server: on a server that has none, `veydan-server push veydan` and `veydan-server card` say so, and `veydan-server add vpush` adds it.
The app cannot turn it on from the card in this version: the card says `p=veydan`, but the address of your push server is not on it yet.

### What is not there yet

- Everyone who has the card has the same app key: you cannot let one person in and keep another out without changing the key for everybody. A list of allowed keys is planned.
- There is no UnifiedPush.
- Bridges do not work with a private server.

## Where things live

| Component | Path | Kept on a rerun (a changed template is put beside it as `*.new`) | Rewritten on every run |
|---|---|---|---|
| Relay | `/opt/strfry` | `etc/strfry.conf`; the database | the systemd units, the router and sync settings |
| Relay: read policy | `/opt/vguard` | your lines outside the kit block of `etc/vguard.toml` | the kit block of `vguard.toml`, the unit |
| Media | `/opt/blossom` | `etc/config.yml` (its rules come from `etc/rules.yml` when there is one) | the units; `etc/blossom.env` (S3 keys) |
| Media index | `/opt/libsql` | the data in `data/` | the unit |
| Push | `/opt/vpush` | your lines outside the kit block of `etc/vpush.toml`; `etc/secrets/` | the kit block of `vpush.toml`, the unit |
| Calls | `/opt/vcall` | `etc/vcall.env`; `data/` | the unit |
| Installer | `/opt/veydan` | `server.conf` | `server.txt`, the nginx files in `nginx/` |

Media files are kept 14 days since the last download, then removed.
This is set in `/opt/blossom/etc/config.yml`, by the rules under `storage:`; the last rule is for everyone.
A server run by Veydan Cloud keeps the files of paid accounts longer: its agent lays the rules of the plans in `/opt/blossom/etc/rules.yml`, puts them into `config.yml` and restarts blossom, and a rerun of the installer renders the same rules from that file.
The file is the agent's: an edit of it, or of the rules in `config.yml`, is replaced within the hour.

How the programs arrive:

- strfry is compiled on the server when the kit brings no binary. This takes 5-10 minutes on a small server. A swap file is added if memory is short, and removed after the build. The commit is checked against `versions.conf`.
- Deno and sqld are downloaded from their GitHub releases and checked by sha256 from `versions.conf`.
- blossom-server is cloned at a pinned commit.
- VPush and the call node come as binaries in the kit, or from their releases on GitHub (the versions in `versions.conf`, checked by the `SHA256SUMS` of the release and by the signature of the Veydan Project, `<file>.sig`) when the kit brings none. x86_64 only.
- vguard, the read policy of the relay, comes the same way: `bin/vguard` of the kit (`make build-deploy` builds it with VPush), or the release of Veydan-Push named by `VGUARD_VERSION` (`vguard-linux-<arch>` with its signature). A relay is never put up without it: when neither is there and none is installed, the installer stops before it changes anything and names `VGUARD_VERSION`.

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
- VPush, vguard and the call node: `install -m755 <new binary> /opt/<app>/bin/<app> && systemctl restart <app>` (the app is `vpush`, `vguard` or `vcall`).

## Checks

```sh
K=<app key from the card>
curl -s -o /dev/null -w '%{http_code}\n' -H 'Accept: application/nostr+json' https://relay.example.org/            # 401
curl -s -H 'Accept: application/nostr+json' "https://relay.example.org/?key=$K"                                     # NIP-11
curl -s -o /dev/null -w '%{http_code}\n' https://media.example.org/                                                 # 404
curl -s https://push.example.org/healthz
systemctl status strfry vguard blossom vpush
journalctl -u strfry-router -n 20
journalctl -u vguard -n 20          # the counters: questions passed, refused and why
```

The read policy: with the app key, a REQ for gift wraps without `#p` of the key you signed in with is answered `CLOSED` with `restricted:`, and nothing reaches strfry (`websocat "wss://relay.example.org/?key=$K"`, then `["REQ","x",{"kinds":[1059]}]`).

The router log shows "Connected to" for each other relay.
Sync timer: `systemctl list-timers strfry-sync.timer`.
Retention timer: `systemctl list-timers strfry-retention.timer`; what it deleted: `journalctl -u strfry-retention`.
Last test: publish an event on one relay and read it from another; upload a file through one media server and download it through another.

## Limits

- There is no uninstall. A component removed from `COMPONENTS` is not removed from the server.
- The database of a relay does not shrink when the retention timer deletes old events: the file keeps its size and the freed pages are used again. Watch the disk (`df -h /opt/strfry`) until the first week has passed.
- `MEDIA_UPLOAD_KEY=required` (the default of a new install) turns the check below on; `open` turns it off, and a server installed before the setting existed stays `open`. The network of Veydan keeps uploads open until the apps carry the key. A server handed out with `veydan-server card` should be `required`: while it is `open`, anyone with a nostr key can upload, and the installer and the card say so on every run (a warning on stderr). `veydan-server media-key required` sets it, then `veydan-server rerun`.
- Media takes anything but a download of a blob by its hash, the list of a key, the index and the CORS preflight (an upload, a mirror, a delete; the case of the path does not matter) only with the key of the server, as the relay does: `?key=` or the header `X-API-Key`, the app key or the peer key (the other media servers). Without it nginx answers 401. The app takes the key from the card of the server. Downloads and the list stay open. The key is inside the app, so this keeps strangers off, not people who have the app; an upload is still signed by the nostr key of its author. Nginx limits the request rate, and a request to 20 MiB.
- The app key is inside the app, so anyone who has the app can query a relay with it. Message content stays encrypted. vguard gives gift wraps (kind 1059) only to the key that signed in (NIP-42) and events of groups (kind 9) only by `#h`; what else is on a relay (profiles, follow and relay lists) is public, as on any relay. A relay without vguard would give everything to the app key, metadata included: the kit puts up no relay without it.
- The strfry router does not check the TLS certificate of the other relay and writes its URL, with the peer key, to the journal. Keep the path between your servers trusted.
- The media index is per server. Without a shared bucket, a file is lost for the network if its server is gone.

## Licence

See `LICENSE` and `LICENSE-SUMMARY.md` in this folder.

Developed by Rookbeam Technologies LLC, USA
