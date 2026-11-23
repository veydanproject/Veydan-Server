# Veydan Server

This installer sets up your own server for the Veydan messenger apps on a clean Debian 13.
It can install five parts: a relay (strfry), a media server (blossom-server with its own index), a push server (VPush), a call node and a bridge (VLink).
Nginx stands in front of them and Let's Encrypt gives the certificates.
Everything runs as systemd services. There is no docker on the server, but for the store and the bus of the relay engine vrelay (below).
You can run one server, or join several into one network.

## Requirements

- A clean Debian 13, x86_64, and root.
- A domain you control, with an A record for each name: relay, media and push (for example `relay.example.org`).
- Ports 80 and 443 open.
- For the relay engine vrelay (`RELAY_ENGINE=vrelay`): 8 GB of memory or more.
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

After the installer, `veydan-server` is on the server: `show` (the card), `join-token`, `add <component>`, `status`, `rerun`, `push veydan|off`, `media-key required|open`, `upload-key`, `relay-engine strfry|vrelay`, `relay-import`, `relay-cleanup`, `audit`.

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
For iPhones the same goes through APNs: set `APNS_APPS="<bundle id> ..."`, `APNS_KEY_ID` and `APNS_TEAM_ID` (the Key ID of the key of APNs and the Team ID of the Apple developer account) and put `apns-<bundle id>.p8` beside the installer; with one app in `APNS_APPS`, any `.p8` is accepted.
One key of APNs serves every app of the team, in production and in the sandbox.
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

    veydan://server/<id>?u=<relay>&k=<app key>[&m=<media>][&c=<call node>][&pu=<push server>]&p=veydan|off&n=<network>[&a=team|channel][&inv=<invite>]

`<id>` is the first 16 hex digits of the sha256 of the relay address, so the app knows the server again from any card of it.
`veydan-server card --contact <npub>` prints a link to a contact that carries the server along (`veydan://contact/<npub>?srv=…`), for a person who has no server of the network yet.
On a team or channel server the card says so (`a=`), and `veydan-server card --invite <code>` puts an invite on it (`inv=`); with `--contact` the invite travels inside the link.

## Access modes

Who may use the relay of your server is its access mode, `ACCESS_MODE` in `server.conf`:

| Mode | Who reads | Who writes | What the card does |
|---|---|---|---|
| `open` | anyone who has the card | anyone who has the card | adds the server |
| `team` | members | members | adds the server; with an invite on it, makes its holder a member |
| `channel` | anyone, without the key | members | the same; a link to a channel works without it |

You, the owner (`ADMIN_PUBKEY`, your npub or hex key), are always a member and the one who invites.
The first run of a server of one relay asks the mode, with `team` as the answer, and asks your key; a server of a network of several relays, one that joins a network, and a server installed before the setting stay `open`.

```sh
veydan-server mode team                     # or open, channel; then:
veydan-server rerun
veydan-server invite                        # the card with an invite for one person, valid 7 days
veydan-server invite --uses 20 --days 30 --label sales
veydan-server invite list                   # the invites, how often each was used
veydan-server invite revoke <id>            # ends an invite
veydan-server members list
veydan-server members add <npub|hex>        # a member without an invite
veydan-server members remove <npub|hex>     # no longer a member
veydan-server card --invite <code>          # the card with an invite you already have
```

`invite` prints the card with the invite on it (`&inv=`), and the code alone on the next lines of the terminal for an app that asks for a code.
The relay reads a change of the members or the invites at once.

Two ways to use it:

- **A blogger's channel.** `ACCESS_MODE=channel`: you post, and so do the people you make members (`veydan-server members add <npub>`, or an invite for your editors).
  Anyone with a link to the channel reads it, with no card and no key; nobody but the members writes to the relay or uploads files.
- **A company's team server.** `ACCESS_MODE=team`: send each colleague a card with an invite (`veydan-server invite --uses 1`, or one invite for the whole department with `--uses 30`).
  The first app that opens it becomes a member; the card without an invite only adds the server, and the relay answers a person who is not a member nothing.
  When someone leaves, `veydan-server members remove <npub>`.

What to know:

- The mode is per relay: members and invites live in this one relay (its vguard, or vrelay), and other relays of a network neither know nor ask for them. Use one relay per server; the installer warns when `MESH_RELAYS` names others.
- Media: with `MEDIA_UPLOAD_KEY=required`, only a member uploads with the app key (nginx asks vguard, or vrelay, about the signer of the upload); the other media servers (the peer key) and upload keys of the staff of a channel pass as before.
- Downloads of media by their hash stay open in every mode: whoever has the hash of a file (it is inside the encrypted message) downloads it, as before.
- An app from before the modes adds a team server from its card as an open one and is refused by the relay: whoever you invite updates the app and opens the card again.
- An app asks the server its mode; a kit of 0.1.8 or before answers 401 or 404 there, and the app takes it for an open server.
- Team and channel need vguard 0.7.0 or later with strfry. The installer stops when the vguard it has does not know the mode, so a team server never comes up open; until `VGUARD_VERSION` in `versions.conf` names that release, use a kit made by `make build-deploy`. vrelay has the modes itself.
- The owner's key comes from `ADMIN_PUBKEY`: a team or channel server is not installed without it.
- Where it lives, with strfry: `/opt/vguard/data/members.txt` (one key a line), `/opt/vguard/data/invites.json`, and the secret the invites are signed with, `/opt/vguard/etc/access.key` (made once and kept; a new one ends every invite).
  With vrelay: `/opt/vrelay/access/members.txt`, `/opt/vrelay/access/invites.json` (0660 vrelay) and `/opt/vrelay/etc/secrets/access.key` (0600 vrelay), in the same formats; `veydan-server members` and `invite` run `vrelay access` as the user vrelay.

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
The staff of a channel who have not got the card get upload keys from the owner's app: each lets one person upload and delete their own files on your media for at most 31 days, nothing else, and the app revokes it when the person loses the role.
On the server:

```sh
veydan-server upload-key <label> <pubkey hex> [days]   # a key for one person (30 days by default)
veydan-server upload-key revoke <label> <pubkey hex>   # ends every key of that person made until now
veydan-server upload-key list                          # the revoked
```

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

- On an `open` server everyone who has the card has the same app key: you cannot let one person in and keep another out without changing the key for everybody. A `team` server lets in its members alone ("Access modes" above).
- There is no UnifiedPush.
- Bridges do not work with a private server.

## The vrelay engine

The relay has two engines, chosen by `RELAY_ENGINE` in `server.conf`:

- `strfry` (the default, for now): strfry, vguard in front of it, the router and the sync timer between the relays.
- `vrelay`: our own relay (Veydan-Relay). `vrelay serve` holds the clients, `vrelay write` takes the queue into the store; both are systemd units of this machine (`/opt/vrelay`). The store is Apache Cassandra and the queue NATS with JetStream, one node each, run by docker compose (`/opt/vrelay/compose`: the relay's own `compose.yaml`, unchanged, and the kit's layer `compose.kit.yaml` over it).

vrelay needs a machine of 8 GB of memory or more: the installer stops below 7 000 MB of `MemTotal`.
Every program of the relay has a memory limit counted from the machine and the components of the server (`vrelay_memory` in `lib/common.sh`), and the limits add up to the machine with an estimate of what has none (the system, nginx, the media server, vpush, a call node):

| MB (`MemTotal`) | 8 GB (7 800) | 16 GB (15 900) | 32 GB (31 900) |
|---|---|---|---|
| Cassandra, its container | 4 102 | 7 195 | 9 787 |
| of it: the heap (a fifth, 1.5 to 4 GB; `RELAY_CASSANDRA_HEAP_MB`) | 1 536 | 3 072 | 4 096 |
| the direct buffers (half the heap, `-XX:MaxDirectMemorySize`) | 768 | 1 536 | 2 048 |
| the memtables off the heap (a quarter of the heap) | 384 | 768 | 1 024 |
| the JVM's own | 1 024 | 1 024 | 1 024 |
| page cache (a twentieth of the machine) | 390 | 795 | 1 595 |
| NATS, its container (a quarter above 4 GB, 1 to 6 GB) | 1 024 | 2 951 | 6 144 |
| of it: Go's soft limit (`GOMEMLIMIT`, four fifths) | 819 MiB | 2 360 MiB | 4 915 MiB |
| vrelay write, `MemoryMax` (a sixteenth, 512 MB to 2 GB) | 512 | 993 | 1 993 |
| vrelay serve, `MemoryMax` (the rest, shared with nginx) | 984 | 2 818 | 9 323 |
| nginx (an estimate: 40 KB a WebSocket) | 410 | 1 174 | 3 884 |
| the system (an estimate) | 768 | 768 | 768 |
| `RELAY_MAX_CONNECTIONS` when empty (96 KB of serve a connection) | 10 000 | 30 000 | 50 000 |

That is a server with the relay alone.
The media server takes 512 MB more of the estimate, vpush 256 and a call node 768, from vrelay serve and nginx: with all three, serve has 768, 1 734 and 8 239 MB, and 8 000, 18 000 and 50 000 connections.
serve never has less than 768 MB; on 8 GB with every component the estimates do not all fit, and the run says so.
The default of the connections is at most 50 000 (no load test went past 35 000, and the CPU is the other bound): a number in `RELAY_MAX_CONNECTIONS` is taken as it is, and the run warns when serve's limit holds fewer.
A machine of 32 768 MB of `MemTotal` or more is a node of the database: the heap a quarter of it (at most 16 GB), NATS an eighth (at most 8 GB), serve 4 GB, the writer 2 GB, the rest Cassandra's.
Measured at 35 000 connections: vrelay serve about 80 KB a connection, NATS 0.8 to 0.9 GB (a subscription a live key); the rest are estimates.
Docker comes from Debian 13's own packages (`docker.io`, `docker-cli`, `docker-compose`); no repository is added.
The images are pinned by version and digest in `versions.conf`.

nginx stays in front on 443 for every site.
It passes the relay's requests as they came, the key with them, to vrelay on `127.0.0.1:7781` (WebSockets, NIP-11, the access API), plain, and names the client in `X-Real-IP`, which vrelay believes from loopback only.
vrelay listens on port 7781 of several loopback addresses (`127.0.0.1`, `127.0.0.2`, ..., one for every 20 000 connections, two at least), and nginx spreads the WebSockets over them: a source port of nginx is unique for each address it connects to, so the 28 232 ports of `ip_local_port_range` cap no more than one address each (nginx answered 502, "Cannot assign requested address", at 30 000 WebSockets to one address). No setting of the kernel changes.
The key is in the query of the WebSocket, and nginx writes the request line, query and all, into every line of its error log about a request, at any level (`crit` included): the relay site logs errors at `emerg` alone (nginx's configuration), and its access log has the path without the query, the status and where nginx sent it (vrelay's address, its status and the time to connect). A site without a log of its own writes the path without the query too.
The access API alone is on `127.0.0.1:7782` (what nginx asks for the uploads of a team or channel server).
vrelay tells a peer by the peer key itself; the gate of nginx (the key) stays in front.
The limits of an address (`RELAY_IP_MAX_CONNECTIONS` 20, `RELAY_IP_CONNECTS_PER_SEC` 10, `RELAY_IP_CONNECT_BURST` 20) are counted by vrelay, not by nginx; `RELAY_MAX_CONNECTIONS` (empty: from the memory, the table above) is the whole relay, `RELAY_IP6_NET_MAX_CONNECTIONS` (2 000, vrelay only) every address of one IPv6 /48 together.
nginx has 32 768 connections a worker (`NGINX_WORKER_CONNECTIONS`; a WebSocket takes two), with either engine.

vrelay is its own read policy and keeps the members and invites of a team or channel server itself (`vrelay access`, in vguard's formats): a fresh server of this engine has nothing of strfry or vguard, no user, unit, folder or binary of them.
Its files are its own: the members and invites in `/opt/vrelay/access/` (0660 vrelay), the secret of the invites in `/opt/vrelay/etc/secrets/access.key`, the denied keys and closed groups the agent of vcloud lays in `/opt/vrelay/policy/` (0750 root:vrelay; no file, nobody denied).

Switching: set `RELAY_ENGINE=vrelay` (`veydan-server relay-engine vrelay`), then `veydan-server rerun`.
The installer puts vrelay up beside strfry, checks that it answers, moves the relay site of nginx to it, and only then stops and disables strfry, strfry-router, strfry-sync.timer, strfry-retention.timer and vguard.
Nothing of strfry is removed: its binary, configs, units and database stay in `/opt/strfry`, and vguard in `/opt/vguard`.
The access files of vguard (members, invites, the secret) and its denied lists are copied to vrelay's place once, as they are, owned by vrelay: the invites made by vguard stay good. Nothing is moved and nothing is copied back.
While `/opt/vguard/data` is there, vrelay reads the denied lists in it (the agent of vcloud lays them there on such a server), by the group vguard.
vrelay starts empty. The history of strfry comes with `veydan-server relay-import`: `strfry export` of the database here into a file, then `vrelay import` of it (what the store has is skipped, so it may run again). It is a command of its own, never part of a run.

The way back: `veydan-server relay-engine strfry`, then `veydan-server rerun`.
strfry and vguard start again with their database; vrelay, vrelay-write, the health timer of the store and the containers stop with their data in `/opt/vrelay/data`.
vguard has the members and invites it had at the switch: what vrelay's command line or its API changed meanwhile is in `/opt/vrelay/access` alone. Going to vrelay again keeps vrelay's copies (the copy is made once), so what vguard changed while strfry served is not taken; copy the files by hand when it matters.
Events written to vrelay meanwhile are not in strfry: to take them back (once vrelay has its `export`, with `import`), `vrelay export` (`VRELAY_ENV_FILE=/opt/vrelay/etc/vrelay.env /opt/vrelay/bin/vrelay export > events.jsonl`, while the containers run) and `strfry import < events.jsonl` as the user strfry, by hand.
On a fresh server of vrelay, `relay-engine strfry` installs strfry and vguard as a fresh install of them would, with an empty database and no members.

For good: `veydan-server relay-cleanup` (never part of a run). On a server whose engine is vrelay, and while vrelay runs, it lists what goes and asks for the word `yes` (`--yes` to skip it), then copies the denied lists and any access file vrelay lacks, runs the kit again (vrelay now reads its own `policy/`, without the group vguard), and only then removes the units and timers of strfry and vguard, `/opt/strfry` with its database, `/opt/vguard`, nginx's upstream of the peers of strfry (`15-relay-peers.conf`, `127.0.0.1:7780`) and the users strfry and vguard.
It is refused while the engine is strfry. After it there is no way back to strfry as it was: `relay-engine strfry` installs it anew, empty. Debian's packages strfry needed stay.

The statistics for the agent of vcloud (`services/relay/spec/stats.md`): `vrelay serve` answers on `127.0.0.1:7783`, `vrelay write` on `127.0.0.1:7784` (`VRELAY_STATS_LISTEN`, in `vrelay.env` and `vrelay-write.env`), on loopback alone; NATS's page stays on `127.0.0.1:8222`.
Each request carries `Authorization: Bearer <token>`: the token is made once (64 hex) in `/opt/vrelay/stats/token` (the folder 0750, the file 0640, `root:vrelay-stats`), named by `VRELAY_STATS_TOKEN_FILE` beside `VRELAY_STATS_LISTEN`; the users `vrelay` and `vagent` are in the group `vrelay-stats`. Without the token the endpoint answers 401.
The users of a day, 7 and 30 days need `MESH_STATS_KEY` in `server.conf`: 32 random bytes in hex, the same on every server of the network, so that the relays' sketches merge.
It is made where a network starts and comes to the other servers in the join key; a network made before it has none, and each server would make another: give them all one by hand (`openssl rand -hex 32` once, `MESH_STATS_KEY=<it>` in the network part of `server.conf` of every server, `veydan-server rerun`). Until then the relay counts the users online, without sketches, and the run says so.
vrelay reads it from `/opt/vrelay/etc/secrets/stats-key` (0600 vrelay); never vagent, vcloud or a page.
Once a minute `veydan-store-health.timer` (root) asks nodetool inside the container of Cassandra and writes `/run/veydan/store-health.json` (0644) for the agent: up or down, the state of this node, its datacenter and cluster, its load, pending compactions and hints, the nodes up, down, joining and leaving.
A vrelay that does not know `VRELAY_STATS_*` yet gets none of them (it would refuse the file), and the run warns.

vrelay connects to no other relay: on a network of several relays, the strfry routers of the others connect to it, both ways. Two relays of the vrelay engine in one network exchange nothing by themselves, unless they are servers of one mesh ("Two regions" below): then they share the store and the bus.

### Security of the store and the bus

- Nothing of Cassandra or NATS is published but on `127.0.0.1` (9042, 4222, and NATS's page 8222); Cassandra's JMX (7199) and its port between nodes (7000) stay inside the container. Docker itself publishes a port given without an address on `127.0.0.1` (`/etc/docker/daemon.json`).
- On this machine each of those ports is for its own users alone (`vrelay-local-lock.service`, `/opt/vrelay/bin/vrelay-local-lock.sh`: the nftables table `inet veydan_local` judges the owner of the socket that opens a connection on the loopback): 7199 and 7000 root and `vrelay-db`; 9042 root, `vrelay`, `vrelay-db`; 4222 root, `vrelay`, `vrelay-bus`; 6222 and 7422 root and `vrelay-bus`; 8222 root, `vrelay`, `vrelay-bus`, `vagent`; 7783 and 7784 root, `vrelay`, `vagent`. The media server, vpush, the call node and nginx's workers open none of them. It is put at boot before docker and at every run of the kit (with the users there are then); the audit checks it.
- A port docker publishes is opened before ufw's rules are read, so a second lock stands in docker's own chain: `vrelay-docker-lock.service` puts `VRELAY-LOCK` into `DOCKER-USER` every time docker starts, and it drops anything to the containers of the bridge `br-vrelay` that comes neither from that bridge nor as an answer.
- Cassandra: password authentication and authorization. The default superuser `cassandra` cannot log in after the install (no login, no superuser, a random password); our superuser `veydan` makes the tables, and vrelay logs in as `vrelay`, with `SELECT` and `MODIFY` on its keyspace and nothing else.
- NATS: no anonymous client. vrelay's account has a user a mode, as the relay's own compose (`spec/security.md` 4.2): `serve` (the queue, the events that are only live, `vrelay.live.x`, the presence), `write` (the stored events to the live bus, `vrelay.live.e`, the acks, the gone marks, the consumer of the queue) and `migrate` (the streams); the units read theirs from `vrelay-serve.env` and `vrelay-write.env`. The system account has a user of its own, used by nothing here.
- The access files and every folder a service writes: root never writes, owns or reads a file there by its path (a link put there would take it elsewhere). The kit writes them as their owner, sets a mode as the owner, an owner with `chown -h`, reads the files of vguard as vguard, and tells and leaves a link; the audit tells a link in `/opt/vrelay/access`.
- The passwords are made at the install (64 hex), never printed and never in an env file: `/opt/vrelay/etc/secrets/` (vrelay's, and the two keys of the network, 0600 vrelay) and `/opt/vrelay/compose/secrets/` (each 0600 its container's user).
- Every container: no new privileges, all capabilities dropped, a user of the host made for it (`vrelay-db` for Cassandra, `vrelay-bus` for NATS; never root), a read-only root with a tmpfs `/tmp`, a memory limit, rotated logs. No container gets the docker socket.
- vrelay serve and write: the user `vrelay`, no capability (it binds no low port behind nginx), `NoNewPrivileges`, `ProtectSystem=strict`, `PrivateTmp` and the rest of the kit's units.

### Two regions

Servers of the vrelay engine in several regions share one store and keep a queue each region, as `services/relay/spec/cluster.md` decides (and `spec/security.md` hardens):

- Cassandra is one cluster, a datacenter a region (`RELAY_DC`), every statement `LOCAL_QUORUM`: a write waits for its own region, and Cassandra copies it to the others.
- NATS is one server a region (three later), its own JetStream domain, the regions joined by a leaf link to the hub region. The queue, the presence and the deletions of a region have the region in their names (`vrelay.eu.write`, `VRELAY_WRITE_EU`); live events cross the link.
- Everything between the servers goes over WireGuard (`wg0`), the one port of it (51820/udp) open to the other servers' addresses alone. Cassandra (7000, 9042) and NATS (4222, 6222, the leaf port 7422 on the hub) listen on the mesh address alone, opened by ufw on `wg0` alone; docker runs them on the host's network and publishes nothing.
- NATS has a user a mode (`serve`, `write`, `migrate`), each with the subjects of its region; the units of vrelay read theirs from `vrelay-serve.env` and `vrelay-write.env` beside `vrelay.env`. Cassandra's users are the cluster's: our superuser `veydan`, on the first server alone (the roles, the keyspaces of a region that joins: `relay-admit`); `vrelay_migrate`, the role of the tables on the servers that joined (`CREATE` on the keyspaces, `ALTER`, `SELECT` and `MODIFY` on vrelay's, nothing of the roles); and `vrelay` (`SELECT`, `MODIFY` on its keyspace).
- chrony keeps the clock (a deletion and a late copy are decided by it); the audit warns at 50 ms of offset and fails at 500 ms.
- Each node repairs its ranges once a week (`vrelay-repair.timer`), on a day of its own: by the place of its name in the mesh, three days apart (two servers: Monday and Thursday, 03:30 UTC).

The settings, in `server.conf` of each server (nothing of them is in the join key of the network):

| Setting | What | Default |
|---|---|---|
| `RELAY_MESH_WG` | this server's address in the WireGuard of the mesh, with the prefix of the whole mesh: `10.77.1.1/16` | `off`: alone, as before |
| `RELAY_DC` | its region: the datacenter, the JetStream domain, the region in the names of the queue | `REGION` in lower case (`eu-1` → `eu`) |
| `RELAY_MESH_WG_PEERS` | the other servers, each `name,endpoint,public key,mesh address,region[,hub]` (`hub`: that region accepts the leaf links) | empty: the first server |
| `RELAY_STORE_SEEDS` | the seeds of Cassandra, the same everywhere | the first server of each region (two from three on) |
| `RELAY_BUS_ROUTES` | the other NATS servers of this region | empty: one NATS a region |
| `RELAY_MESH_WG_ENDPOINT` | this server's endpoint in its line for the others, `<IPv4>[:port]` or `[<IPv6>][:port]` | its public address: the first address of the internet among its `MESH_ORIGINS` entry, `CALL_PUBLIC_IP`, its own addresses and the DNS of its relay (not Cloudflare's); a private one only when set here |
| `RELAY_JOIN_KEY_HOURS` | how long a key of `relay-peer add` is taken here by `relay-join`, in hours from when it was made | `24` |

The copies follow: one a region (`VRELAY_STORE_REPLICATION=eu:1,us:1`), three for a region of three servers.
A server with `RELAY_MESH_WG=off` installs as before; a store made for one server alone is not taken into a mesh in place (export it, move `/opt/vrelay/data` away, install, import), and a node of the mesh is not turned back into a server alone by a rerun.

**Server 1 (`eu-1`, the hub).** In its `server.conf`, beside the rest (`RELAY_ENGINE=vrelay`, its `MESH_ORIGINS` line holding its public address):

```sh
RELAY_MESH_WG=10.77.1.1/16
RELAY_DC=eu
```

```sh
./install.sh --yes                 # or veydan-server rerun on an installed server
veydan-server relay-peer           # its line, for the others: eu-1,203.0.113.10:51820,<key>,10.77.1.1,eu,hub
```

It comes up alone: its Cassandra begins the cluster (the system keyspaces on `NetworkTopologyStrategy` with `'eu': 1`), its NATS the domain `eu`, then vrelay. Once it has a peer, its audit fails until that peer's handshake is there.

**Server 2 (`us-1`, a new region).** In its `server.conf`:

```sh
RELAY_MESH_WG=10.77.2.1/16
RELAY_DC=us
RELAY_MESH_WG_PEERS="eu-1,203.0.113.10:51820,<the key of eu-1>,10.77.1.1,eu,hub"
```

```sh
./install.sh --yes                 # sets it up and stops before Cassandra, printing its line
```

On server 1, with that line (it adds the peer to `server.conf`, makes the key of the pair, opens the firewall to it, gives NATS the leaf user of `us` and restarts it, seconds; it writes the join key to `/opt/vrelay/etc/mesh-keys/us-1.key`, 0600 root):

```sh
veydan-server relay-peer add 'us-1,198.51.100.20:51820,<the key of us-1>,10.77.2.1,us'
```

The key holds the key of the pair, the passwords of the roles `vrelay` and `vrelay_migrate` of the store (never its superuser), the password of the leaf link of `us` and, for a server of the same region, the users of NATS of the region; the time it was made, and a mark with `MESH_PEER_KEY`, which both servers have: `relay-join` refuses a key that was changed, or older than `RELAY_JOIN_KEY_HOURS` (24). It is never an argument of a command (every user of a machine reads the command lines): copy the file to server 2 by a safe way (`scp` to root), and there:

```sh
veydan-server relay-join --key-file us-1.key     # or: veydan-server relay-join < us-1.key
```

(`relay-peer add --stdout` prints it instead, for a pipe: `veydan-server relay-peer add --stdout '<line>' | ssh root@us-1 veydan-server relay-join`.) A name there already is refused: a new line for it (a server put up again) with `--replace`, which makes a new key of the pair and a new join key; a line that moves the hub of the leaf links with `--hub`. Remove the key files once taken.

It goes through the order of `services/relay/deploy/cluster/README.md`, checks each step and stops at the first that fails, saying why; run it again (without the key, once taken) and the steps done are skipped:

1. the key taken (its mark and its time checked): the key of the pair, the passwords of the roles of Cassandra, the password of the leaf link;
2. WireGuard: a handshake with every peer within a minute;
3. NATS of `us`, the leaf link to `eu` up (`/leafz`);
4. the seeds reached over the mesh (7000), and the CQL of `eu` (9042);
5. Cassandra started with `auto_bootstrap: false` and the seeds of the others alone (a node that reached none stops instead of making a cluster of its own); `nodetool status` shows `eu` and `us`, this node `UN`;
6. the keyspaces `vrelay`, `system_auth`, `system_distributed`, `system_traces` with a copy in `us`, read on `eu` as `vrelay`. They have none yet the first time: it stops and says to run, on server 1 (it has the superuser), `veydan-server relay-admit us-1` (an `ALTER KEYSPACE` of each to `'eu': 1, 'us': 1`, read back, once the node of `us-1` is `UN`); then `veydan-server relay-join` again here;
7. `nodetool rebuild -- eu`; then a login of `vrelay` here and the tables of vrelay read here at `LOCAL_ONE`;
8. the kit again (`auto_bootstrap` back to its default, the roles checked, `vrelay migrate` of `us` as `vrelay_migrate`, vrelay, nginx, the audit).

Then on server 1: `veydan-server rerun`, so that its vrelay takes the region `us` (the replication it compares, the presence and the deletions it sources).
Checks: `veydan-server relay-nodetool status` on either shows both datacenters `UN`; `veydan-server relay-peer` shows a fresh handshake; `veydan-server audit` on both.

What vrelay itself does across regions today and what waits for its changes (deletions, presence, the catch-up after a cut of the link) is `spec/cluster.md` 3.

**A region down, a link cut.** Up to 24 hours the hints bring it back by themselves; past that, before its relay takes clients, `veydan-server relay-nodetool repair --full vrelay` on each node of the returning region; past 10 days it must not come back with its data (`spec/cluster.md` 1.3).

**A region of three** (`eu-2`, `eu-3` beside `eu-1`; `spec/cluster.md` 1.8 and 2.7). Cassandra grows a node at a time; NATS does not: a standalone NATS given routes lost its streams in a trial, so the region's NATS is backed up, formed anew with three servers and restored. The relay of `eu` is out of service during step 3 (minutes; its clients go to `us`).

1. **The new servers.** Each its `server.conf`: `RELAY_MESH_WG=10.77.1.2/16` (`.3`), `RELAY_DC=eu`, every other server of the mesh in `RELAY_MESH_WG_PEERS`, and `RELAY_BUS_ROUTES` naming the other two of `eu` (`10.77.1.1,10.77.1.3` on `eu-2`). `./install.sh --yes`: it stops before Cassandra with its line. On every server already in the mesh: `veydan-server relay-peer add '<its line>'` (a key file for each). The key of `eu-1` carries the users of NATS of `eu`, the password of its routes and the leaf users of the other regions.
2. **Cassandra.** On `eu-2`, then on `eu-3` (one at a time): `veydan-server relay-join --key-file <key of eu-1> --key-file <key of us-1>`. Its node bootstraps in `eu` (it streams its ranges; no rebuild). The kit then stops at `vrelay migrate`: the streams of three copies wait for the three NATS of step 3, and nothing of the queue is made before. After each: `veydan-server relay-nodetool cleanup vrelay` on the other nodes of `eu`.
3. **NATS of `eu`**, on `eu-1`:

   ```sh
   systemctl stop vrelay                       # no new events; the writers drain the queue
   cd /opt/vrelay/compose
   export NATS_PASSWORD=$(cat secrets/nats-migrate-password)
   NATS="docker run --rm --network host -v /opt/vrelay/backup:/backup -e NATS_PASSWORD natsio/nats-box@sha256:5162fca0f56ebe6f78e612e1ded143ce978e088393476033020e6251358dba6f nats -s nats://10.77.1.1:4222 --user migrate"
   $NATS stream info VRELAY_WRITE_EU | grep Messages   # until 0
   systemctl stop vrelay-write
   install -d -m 0700 /opt/vrelay/backup
   for s in VRELAY_WRITE_EU VRELAY_OUT_EU VRELAY_IN_EU; do $NATS stream backup "$s" "/backup/$s"; done
   docker compose --env-file .env -f mesh.yaml stop nats
   mv /opt/vrelay/data/nats /opt/vrelay/data/nats.standalone
   install -d -m 0700 -o vrelay-bus -g vrelay-bus /opt/vrelay/data/nats
   # RELAY_BUS_ROUTES="10.77.1.2,10.77.1.3" in /opt/veydan/server.conf, then NATS alone with its routes:
   veydan-server relay-peer apply
   docker compose --env-file .env -f mesh.yaml up -d --wait nats
   for s in VRELAY_WRITE_EU VRELAY_OUT_EU VRELAY_IN_EU; do $NATS stream restore "/backup/$s" --replicas 3; done
   ```

   A restore that failed leaves an empty stream: `$NATS stream rm -f <stream>`, then restore it again. The presence stream is not backed up: beats come again within 30 s, and `migrate` makes it anew. Then `veydan-server rerun` on `eu-1`, `eu-2` and `eu-3` (`vrelay migrate` finds the restored streams, `VRELAY_BUS_STREAM_REPLICAS=3`; the writers, then the relay), and on every server of the other regions (their leaf link takes the three servers of `eu`). `/opt/vrelay/data/nats.standalone` and `/opt/vrelay/backup` go once the relay of `eu` serves again.
4. **Three copies in `eu`** (on any node of the mesh; the statements as our superuser):

   ```sh
   cd /opt/vrelay/compose
   printf "ALTER KEYSPACE %s WITH replication = {'class': 'NetworkTopologyStrategy', 'eu': 3, 'us': 1};\n" vrelay system_auth system_distributed system_traces \
     | docker compose --env-file .env -f mesh.yaml run --rm -T cql
   veydan-server relay-nodetool repair --full vrelay        # on each node of eu, one after another
   veydan-server relay-nodetool repair --full system_auth
   ```

   The next `veydan-server rerun` writes `VRELAY_STORE_REPLICATION=eu:3,us:1` (three servers named in `eu`), which `migrate` compares with the keyspace.

**A server leaves.** On it, while it runs: `veydan-server relay-nodetool decommission`; when it is gone, on another: `veydan-server relay-nodetool removenode <its host id of status>`. Then on every other server: `veydan-server relay-peer remove <name>`: the key of the pair goes with it, and it tells what the server knew and what ends it. The password of the leaf link of its region: on the hub, `veydan-server relay-peer rotate-leaf <region>`, then `relay-peer add --replace` there for each other server of that region and `relay-join --key-file` on each (a server that has joined takes the new keys and nothing else). The users of NATS of its own region and the passwords of the roles of the store are changed by hand. Before a region goes below its copies, lower them (`ALTER KEYSPACE`, as in step 4).

Not exercised by the kit on real servers yet: WireGuard between two machines, ufw on them, the run as root, relay-join and the procedures of a region of three; the tests of the relay's `spec/cluster.md` 4 are where they are tried.

#### Nodes (not built)

A design note: what the kit would need for a node, a server of a cluster that is not a relay of the manifest and takes clients under the cluster's name (`wss://eu-relay.example.org` served by `eu-1` and `eu-2`).
Today a server of the mesh is refused when its relay name is not in `MESH_RELAYS` ("… is not in MESH_RELAYS … add it there (on every server)"), which is right for a relay of the manifest; a node has no name of its own in the manifest.

- **What it is in server.conf.** `RELAY_HOST` is the cluster's name, already in `MESH_RELAYS`; `SERVER` is the node's own word (`eu-2`), the name of its WireGuard peer and of its NATS; a new setting, `RELAY_NODE_OF=<the cluster's relay name>`, says it serves that name without being a relay of its own, so that the check above passes, `PEERS` does not name the other nodes of the same name as peers, and the card and the manifest are not written as a new relay (the card's id comes from the relay URL: every node gives the same card).
- **The join.** `veydan-server join-token` on a server of the cluster prints the network part of its `server.conf` (`BASE_DOMAIN`, `NETWORK`, `MESH_RELAYS`, `MESH_MEDIA`, `MESH_ORIGINS`, the app, peer and statistics keys, the bucket's keys, `TLS`, `ACME_EMAIL`, `FIREWALL`, `ADMIN_PUBKEY`, `VLINK_REGISTRY_HOST`): enough for `install.sh --join`, nothing of the mesh. A node needs more, as one step: `veydan-server relay-join --node <server> --key-file <token>`, where `<token>` (a file, never an argument) is issued on `<server>` (a server of the cluster) and carries the network part, the cluster's relay name, the region, the next free mesh address, that server's line, the passwords of the store and the users of NATS of the region (what `relay-peer add` gives today, for this new peer). On the node it would write `server.conf`, run the kit (which stops before Cassandra, as a new server of a region does today), and go on with the eight steps of `relay-join`. The token is a secret like the key of `relay-peer add`, good for one node and for a short time.
- **The certificate of one name on several servers.** HTTP-01 fails with several A records: Let's Encrypt asks any of them, and the node that did not ask has no token. The ways: DNS-01 with an API token of the zone (certbot's plugin; each node gets its own certificate of the name, no server depends on another; the token is a secret of every node); one node issues and the others take its certificate over the mesh (one key on many machines, a renewal pushed to all); every node's nginx passes `/.well-known/acme-challenge/` it cannot answer to the other nodes over WireGuard (HTTP-01 works again, any node may issue); or the name behind Cloudflare with its origin certificate (no public CA at the nodes; Cloudflare is then in the path of every client). DNS-01 is the plainest where the zone has an API.
- **What the others learn by themselves.** `relay-peer add` on each server of the mesh already gives WireGuard, the firewall, NATS and the region's users; Cassandra learns the node by its seeds; vrelay of the region needs nothing (one queue and one store per region). By hand today and to be done by the kit: the A record of the name (or the DNS API, with DNS-01), `MESH_ORIGINS` (one address a name: a node has none of its own, so the other relays reach the cluster's name past a CDN at one node), the agent (vcloud sees the node as a server with a relay component under the cluster's name).

## What is open to the internet

| Component | Port | Why |
|---|---|---|
| every server | the ports of sshd | the admin |
| relay, media, push | 80/tcp | Let's Encrypt, and the redirect to https |
| relay, media, push | 443/tcp | nginx: the sites, TLS |
| call | `CALL_PORT`/tcp (8443) | the control of the node, TURN over TLS |
| call | 3478/udp+tcp | STUN and TURN |
| call | `CALL_SFU_PORT`/udp+tcp (3479) | the SFU of group calls |
| call | `CALL_RELAY_PORTS`/udp (49152-49999) | the relayed media of TURN |
| bridge | `BRIDGE_PORT`/tcp (443) | VLink |
| relay, vrelay in a mesh | 51820/udp, from the other servers of the mesh alone | WireGuard between the servers ("Two regions") |

Everything else listens on loopback: strfry (7777), vguard (7778, 7779) and nginx's upstream of the peers of strfry (7780) with the engine strfry; vrelay (7781, 7782, its statistics 7783 and 7784), Cassandra (9042) and NATS (4222, 8222) with vrelay; sqld (8080), blossom (3000), vpush (8090).
The audit fails when the statistics of vrelay or the page of NATS listen anywhere but on loopback, or when `vrelay.env` or `vrelay-write.env` names another address for them.
In a mesh of vrelay, Cassandra (7000, 9042) and NATS (4222, 6222, 7422) listen on the mesh address of the server instead, reached on `wg0` alone; JMX (7199) and the page of NATS (8222) stay on loopback.
`veydan-server audit`, run at the end of every run of the installer, lists every socket on another address and fails on one that no component of the server opens (beside sshd, the clients of DHCP, what ufw lets in, and `AUDIT_ALLOW` of `server.conf`).
With vrelay it also checks the second lock, that Cassandra refuses the default login and NATS a client without a password, and that no secret is open to others; the run fails on any finding, after everything is in place.

## Where things live

| Component | Path | Kept on a rerun (a changed template is put beside it as `*.new`) | Rewritten on every run |
|---|---|---|---|
| Relay, engine strfry | `/opt/strfry` | `etc/strfry.conf`; the database | the systemd units, the router and sync settings |
| Relay: read policy of strfry | `/opt/vguard` | your lines outside the kit block of `etc/vguard.toml`; `etc/access.key`, `data/members.txt`, `data/invites.json` (team, channel) | the kit block of `vguard.toml`, the unit |
| Relay, engine vrelay | `/opt/vrelay` | your lines outside the kit block of `etc/vrelay.env`; `etc/secrets/` and `compose/secrets/` (made once; `access.key`, `stats-key`); `access/` (members, invites); `policy/` (the denied lists of the agent); the data of Cassandra and NATS in `data/` | the kit block of `vrelay.env`, `etc/vrelay-write.env`, the units and `veydan-store-health.timer`, `bin/store-health.sh`, the compose files, `compose/.env` |
| Relay, vrelay in a mesh | `/etc/wireguard`, `/opt/vrelay` | `wg0.key` and `psk-<peer>` (made once, 0600); `etc/mesh-joined` (the first server, or relay-join done); `etc/mesh-keys/<peer>.key` (a join key of relay-peer add, 0600 root, until removed) | `wg0.conf`, `compose/secrets/nats/nats.conf`, `etc/vrelay-serve.env`, `etc/vrelay-write.env`, the repair timer, the rules of ufw marked `veydan-mesh` |
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

- nginx and njs come from the repository of nginx.org (its key checked by its fingerprint), the newest it offers and never older than 1.30.7; a Debian nginx is replaced. `/etc/nginx/nginx.conf` is the installer's, in Debian's layout (`modules-enabled`, `conf.d`, `sites-enabled`), and a change is taken only when `nginx -t` passes.

- strfry is compiled on the server when the kit brings no binary. This takes 5-10 minutes on a small server. A swap file is added if memory is short, and removed after the build. The commit is checked against `versions.conf`.
- Deno and sqld are downloaded from their GitHub releases and checked by sha256 from `versions.conf`.
- blossom-server is cloned at a pinned commit.
- VPush and the call node come as binaries in the kit, or from their releases on GitHub (the versions in `versions.conf`, checked by the `SHA256SUMS` of the release and by the signature of the Veydan Project, `<file>.sig`) when the kit brings none. x86_64 only.
- vguard, the read policy of the relay, comes the same way: `bin/vguard` of the kit (`make build-deploy` builds it), or the release of Veydan-Guard named by `VGUARD_VERSION` (`vguard-linux-<arch>` with its signature). A relay of strfry is never put up without it: when neither is there and none is installed, the installer stops before it changes anything and names `VGUARD_VERSION`. vrelay needs none: it is its own read policy.

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
- vrelay: a new `bin/vrelay` in the kit or `VRELAY_VERSION` in `versions.conf`, then `veydan-server rerun`; Cassandra and NATS: `CASSANDRA_IMAGE_TAG`, `NATS_IMAGE_TAG` (a version and its digest), then `veydan-server rerun`.

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

With the vrelay engine:

```sh
systemctl status vrelay vrelay-write vrelay-docker-lock
journalctl -u vrelay -n 20          # the counters every 5 minutes
VRELAY_ENV_FILE=/opt/vrelay/etc/vrelay.env /opt/vrelay/bin/vrelay probe && echo answers
VRELAY_ENV_FILE=/opt/vrelay/etc/vrelay.env /opt/vrelay/bin/vrelay config print --mode serve
veydan-server status                # the units and the containers
veydan-server audit
```

The router log shows "Connected to" for each other relay.
Sync timer: `systemctl list-timers strfry-sync.timer`.
Retention timer: `systemctl list-timers strfry-retention.timer`; what it deleted: `journalctl -u strfry-retention`.
Last test: publish an event on one relay and read it from another; upload a file through one media server and download it through another.

## Limits

- There is no uninstall. A component removed from `COMPONENTS` is not removed from the server.
- The database of a relay does not shrink when the retention timer deletes old events: the file keeps its size and the freed pages are used again. Watch the disk (`df -h /opt/strfry`) until the first week has passed.
- `MEDIA_UPLOAD_KEY=required` (the default of a new install) turns the check below on; `open` turns it off, and a server installed before the setting existed stays `open`. The network of Veydan keeps uploads open until the apps carry the key. A server handed out with `veydan-server card` should be `required`: while it is `open`, anyone with a nostr key can upload, and the installer and the card say so on every run (a warning on stderr). `veydan-server media-key required` sets it, then `veydan-server rerun`.
- Media takes anything but a download of a blob by its hash, the list of a key, the index and the CORS preflight (an upload, a mirror, a delete; the case of the path does not matter) only with the key of the server, as the relay does: `?key=` or the header `X-API-Key`, the app key or the peer key (the other media servers). Without it nginx answers 401. The app takes the key from the card of the server. Downloads and the list stay open. The key is inside the app, so this keeps strangers off, not people who have the app; an upload is still signed by the nostr key of its author. Nginx limits the request rate, and a request to 20 MiB.
- An upload key (`vu1.<label>.<pubkey>.<iat>.<exp>.<mac>`, made by the owner's app or `veydan-server upload-key`) is the one exception: it lets `PUT`/`HEAD /upload` and `DELETE /<sha256>` through on the host it was made for, when the upload is signed by the nostr key it names, until it expires (at most 31 days) or is revoked (`POST /.well-known/veydan-media/revoke?label=&pubkey=` with the app key, or `veydan-server upload-key revoke`). It never opens the relay, a mirror or anything else. `GET /.well-known/veydan-media` tells the app whether uploads need a key.
- The app key is inside the app, so anyone who has the app can query a relay with it. Message content stays encrypted. vguard gives gift wraps (kind 1059) only to the key that signed in (NIP-42) and events of groups (kind 9) only by `#h`; what else is on a relay (profiles, follow and relay lists) is public, as on any relay. A strfry without vguard would give everything to the app key, metadata included: the kit puts up no strfry without it. vrelay applies the same policy itself.
- The strfry router does not check the TLS certificate of the other relay and writes its URL, with the peer key, to the journal. Keep the path between your servers trusted.
- The media index is per server. Without a shared bucket, a file is lost for the network if its server is gone.

## Licence

See `LICENSE` and `LICENSE-SUMMARY.md` in this folder.

Developed by Rookbeam Technologies LLC, USA
