# Changelog

## 0.1.10

The relay has a second engine, our own relay vrelay, chosen by `RELAY_ENGINE=strfry|vrelay` in `server.conf`; `strfry` stays the default.
With `vrelay`, `vrelay serve` and `vrelay write` run as units of the machine (`/opt/vrelay`, the user `vrelay`), and Apache Cassandra 5.0.9 and NATS 2.15.3 with JetStream beside them in docker compose: the relay's own `compose.yaml`, unchanged, and the kit's layer over it (`templates/relay-compose`), the data bind-mounted in `/opt/vrelay/data`.
Docker comes from Debian 13's own packages; the images are pinned by version and digest (`CASSANDRA_IMAGE_TAG`, `NATS_IMAGE_TAG` of `versions.conf`).
vrelay needs 8 GB of memory (7 000 MB of `MemTotal`; the installer stops below), and Cassandra's heap is counted from it (`RELAY_CASSANDRA_HEAP_MB` to set it).
The units of vrelay run their allocator without transparent huge pages (`MIMALLOC_ALLOW_THP=0`): a huge page given back in part stayed charged whole to `MemoryMax` (20 000 connections: 1 589 MB with them, 1 124 MB without).
The binary comes from `bin/vrelay` of the kit (`make build-deploy`), or from the release of Veydan-Relay named by `VRELAY_VERSION` (0.1.0), signed as `vrelay`.
nginx stays in front: the relay site passes the request as it came to vrelay on `127.0.0.1:7781`, plain, with `X-Real-IP`; the access API of a team or channel server is vrelay's on `127.0.0.1:7782`.
A rerun with the other engine puts it up beside the one there, moves nginx once it answers, then stops and disables the old one, whose files and data stay: strfry, its router, its timers and vguard, or vrelay, its writer and the containers.
A fresh server of vrelay has nothing of strfry or vguard: no user, unit, timer, folder or binary of them, and no `NO_VGUARD` refusal (vrelay is its own read policy).
vrelay keeps the members and invites itself (`vrelay access`, vguard's formats): `/opt/vrelay/access/members.txt` and `invites.json` (0660 vrelay), the secret of the invites `/opt/vrelay/etc/secrets/access.key` (made once), the first invite of a team server by `vrelay access invite`; `veydan-server mode`, `members` and `invite` run `vrelay access` as the user vrelay. The denied lists of the agent are read from `/opt/vrelay/policy/`; the unit of vrelay has no group vguard and writes `/opt/vrelay/access` alone.
A server switched from strfry keeps strfry and vguard stopped and disabled for the way back; their access files and denied lists are copied to vrelay once, as they are (vguard's invites stay good), never back; its denied lists are read in `/opt/vguard/data`, where the agent lays them, while that folder is there.
`veydan-server relay-cleanup [--yes]` removes strfry and vguard for good on a server of vrelay (units and timers, `/opt/strfry` with its database, `/opt/vguard`, nginx's upstream of the peers of strfry, the users), after the word `yes` and a run of the kit that moves vrelay off `/opt/vguard`; it is refused while the engine is strfry.
The statistics of vrelay for the agent (services/relay/spec/stats.md): `VRELAY_STATS_LISTEN=127.0.0.1:7783` in `vrelay.env`, `127.0.0.1:7784` for the writer in `vrelay-write.env` (now on every server of vrelay), `VRELAY_STATS_KEY_FILE` from `MESH_STATS_KEY`, a new key of the network (64 hex, made where the network starts, carried by the join key, `/opt/vrelay/etc/secrets/stats-key` 0600 vrelay); a vrelay that does not know the settings gets none of them.
`veydan-store-health.timer` writes `/run/veydan/store-health.json` once a minute from nodetool inside the container of Cassandra, in the shape vagent reads.
The audit fails on the statistics or the page of NATS listening beyond loopback, and on another address for them in the env files.
The line of a server of the mesh (`veydan-server relay-peer`) names its public address: a private address of `MESH_ORIGINS` is no longer taken; `RELAY_MESH_WG_ENDPOINT` sets it by hand.
`veydan-server relay-engine strfry|vrelay` sets the engine; `veydan-server relay-import [--keep]` pours the history of strfry into vrelay (`strfry export`, then `vrelay import`), on its own, never in a run.
The store and the bus are locked down from the first start: published on loopback only, a second lock in docker's `DOCKER-USER` chain (`vrelay-docker-lock.service`), Cassandra with passwords and roles (the default superuser cannot log in; vrelay's role has `SELECT` and `MODIFY` on its keyspace alone), NATS with accounts (no anonymous client; vrelay's user limited to its subjects and the JetStream API), the passwords in files 0600 made at the install, every container without capabilities or new privileges, as a user of its own, on a read-only root.
Servers of vrelay in several regions form a mesh (README, "Two regions"; services/relay/spec/cluster.md and spec/security.md): one Cassandra cluster with a datacenter a region, a NATS a region with its own JetStream domain, the regions joined by a leaf link to the hub region, everything between the servers over WireGuard.
`RELAY_MESH_WG` is this server's address in the mesh (`10.77.1.1/16`; `off`, the default, installs as before), `RELAY_DC` its region (in the mesh: `REGION` in lower case), `RELAY_MESH_WG_PEERS` the other servers (`name,endpoint,public key,mesh address,region[,hub]`), `RELAY_STORE_SEEDS` the seeds (the first server of each region when empty), `RELAY_BUS_ROUTES` the other NATS servers of the region.
The kit makes the WireGuard key of the server (`/etc/wireguard/wg0.key`, 0600, never printed) and `wg0` from the peers, opens 51820/udp to the peers' addresses alone and Cassandra (7000, 9042) and NATS (4222, 6222, 7422 on the hub) on `wg0` alone (rules of ufw with the comment `veydan-mesh`, those no longer wanted deleted), runs Cassandra and NATS on the host's network bound to the mesh address (`compose/mesh.yaml` in place of the two files of one server), installs chrony, and puts the weekly repair of the node on a day of its own (`vrelay-repair.timer`).
NATS of the mesh has a user a mode (`serve`, `write`, `migrate`), each with the subjects of its region, read by the units from `vrelay-serve.env` and `vrelay-write.env`; vrelay.env names the region in every name of the queue (`VRELAY_REGION_NAME`, `VRELAY_REGION_PEERS`, `VRELAY_STORE_REPLICATION`).
The first server comes up alone; the next stops before Cassandra and prints its line. `veydan-server relay-peer add '<line>'` on a server of the mesh takes it (WireGuard, firewall, NATS; a new leaf user restarts NATS, which does not reload its leaf links) and writes the key it joins with to a file of root (`/opt/vrelay/etc/mesh-keys/<name>.key`, 0600; `--stdout` for a pipe); `veydan-server relay-join --key-file <file>` there (or the key on its input; never an argument) joins step by step, a check after each, and stops at the first that fails (WireGuard, NATS and the leaf link, the seeds, Cassandra with `auto_bootstrap: false` and the others' seeds alone, the copies of the four keyspaces in its region, which `veydan-server relay-admit <name>` adds on the first server, `nodetool rebuild`), then runs the kit; `veydan-server relay-peer`, `relay-peer remove`, `relay-peer rotate-leaf`, `relay-peer apply`, `relay-nodetool`.
The join key carries no superuser of the store: the first server alone has it; a server that joined makes the tables as the role `vrelay_migrate` (`CREATE` on the keyspaces, `ALTER`, `SELECT`, `MODIFY` on vrelay's), checks the roles and makes none. The key carries the time it was made and a mark (HMAC-SHA256 with `MESH_PEER_KEY`): one changed, or older than `RELAY_JOIN_KEY_HOURS` (24), is refused. `relay-peer add` refuses a name there already without `--replace` (which makes a new key of the pair) and a line that moves the hub without `--hub`; `relay-peer remove` ends the key of the pair and tells what else to end; `relay-peer rotate-leaf <region>` on the hub makes a new password of a leaf link; a server that has joined takes new keys by `relay-join`.
`veydan-server audit` learns the mesh: the ports of Cassandra and NATS on the mesh address alone, 7001 and 7222 nowhere, WireGuard's port allowed, every peer's handshake under 3 minutes, the keys 0600 root, the clock (50 ms a warning, 500 ms a finding), Cassandra's logins, permissions and `system_auth` in every datacenter, the leaf link, the containers on the host's network without capabilities, ufw active, the data on dm-crypt (a warning).
A store made for one server is not taken into a mesh in place, and a node of the mesh is not turned back by a rerun: both are refused with the way to do it.
The template of `vrelay.env` is `templates/vrelay-env.conf`: as `templates/vrelay.env` it matched `*.env` of `.gitignore` and was in no commit, so a kit from a checkout had none.
Root never works by a path in a folder another user may write (lib/common.sh): `put` writes there as the owner of the file, `mkdirp` makes a folder there as its owner, a link is refused or told and left, an owner is set with `chown -h`, a mode by the user; the access files of vrelay and vguard, the copies of vguard's files (read as vguard), the secrets of vpush and the revocations of upload keys (written as nginx's user) go so. The secrets of NATS of the mesh are a folder of root (0750, the file 0640, the group of NATS). The build swap of strfry is in `/opt/strfry`, not `/var/tmp`. A join token of the network that holds anything a shell would run is refused before it is read.
The local lock (`vrelay-local-lock.service`, nftables, an owner match on the loopback): Cassandra's JMX and its port between nodes for root and `vrelay-db`, CQL for root, `vrelay` and `vrelay-db`, NATS for root, `vrelay` and `vrelay-bus`, its routes and leaf links for root and `vrelay-bus`, its page for root, `vrelay`, `vrelay-bus` and `vagent`, the statistics for root, `vrelay` and `vagent`; put at boot before docker and at the end of every run; the audit checks it.
The statistics need a token: `/opt/vrelay/stats/token` (made once, 64 hex, 0640 `root:vrelay-stats`; `vrelay` and `vagent` in the group), `VRELAY_STATS_TOKEN_FILE` beside `VRELAY_STATS_LISTEN`; the audit checks its owner and mode.
NATS of a server alone has a user a mode too (`serve`, `write`, `migrate`, as the relay's compose), read from `vrelay-serve.env` and `vrelay-write.env`; `vrelay migrate` runs as `migrate`; NATS starts again once with them. The live events split by who publishes them: `vrelay.live.e` (stored, by write), `vrelay.live.x` (only live, by serve), in every config of NATS.
The relay site of nginx refuses in `location /` a path with a dot segment, a double slash or an encoded dot or slash: such a path reached vrelay past the limit of its plain paths.

The limits of the relay come from `server.conf`: `RELAY_IP_MAX_CONNECTIONS` (20), `RELAY_IP_CONNECTS_PER_SEC` (10), `RELAY_IP_CONNECT_BURST` (20), counted by nginx with strfry and by vrelay with vrelay, and `RELAY_MAX_CONNECTIONS` (vrelay; empty: what the memory of vrelay serve holds).
nginx has 32 768 connections a worker (it had Debian's 768) and twice as many files, `NGINX_WORKER_CONNECTIONS` to change it.

`veydan-server audit` lists every socket that listens on an address other than loopback and fails on one no component of the server opens (sshd, 80 and 443 for the sites, the ports of a call node and a bridge, the clients of DHCP, what ufw lets in, `AUDIT_ALLOW` of `server.conf`), on a container port published beyond loopback, and on a secret open to others; with vrelay also on a missing second lock, a default login of Cassandra that works and an anonymous client of NATS that is taken.
Every run of the installer ends with it, and fails on a finding after everything is in place.
The README has a table of what is open to the internet.

Push to iPhones: `APNS_APPS="<app id> ..."` in `server.conf`, with `APNS_KEY_ID` and `APNS_TEAM_ID` of the Apple developer account and `apns-<app id>.p8` beside the installer (or any `.p8`, when `APNS_APPS` names one app), writes `[apps."<id>".apns]` into `vpush.toml`, the topic being the app id; the key goes to `/opt/vpush/etc/secrets/apns-<app id>.p8`, and one already there stays when the kit brings none.
Without the two ids the installer warns and serves no iOS app.
VPush delivers through APNs from Veydan-Push 0.7.0 and rings an iPhone through PushKit from 0.8.0 (`VPUSH_VERSION=0.8.0`); an older one reads the section and pushes nothing.

nginx and njs come from nginx.org, not from Debian: nginx before 1.30.7 has a vulnerability, and Debian 13 ships 1.26.3.
The installer adds nginx.org's repository (its signing key checked by its fingerprint, `/etc/apt/sources.list.d/nginx.list`, pinned first by `/etc/apt/preferences.d/99nginx`) and installs the newest `nginx` it offers with the `nginx-module-njs` built for it; it stops, changing nothing, when that nginx is older than 1.30.7.
A server with Debian's nginx is switched over: `nginx-common` and `libnginx-mod-*` are removed, the sites and certificates stay.
The layout stays Debian's: `/etc/nginx/nginx.conf` is now the kit's (`user www-data`, `modules-enabled`, `conf.d`, `sites-enabled`; the one there before is kept once as `nginx.conf.before-veydan`), njs is loaded by `modules-enabled/50-official-njs.conf`, Debian's module files that would stop nginx are set aside as `*.removed`, and nginx.org's welcome site `conf.d/default.conf` goes.
nginx takes the new config only once `nginx -t` passes; when it refuses, the files are put back and the running nginx keeps the config it had.

The relay site of vrelay limits the plain paths vrelay answers before its gate (`/manifest.json`, `/_access`, the access API where no other location takes it) by the zone of the relay, `RELAY_IP_CONNECTS_PER_SEC` a second and `RELAY_IP_CONNECT_BURST` at once, as the site of strfry limits its relay; the WebSockets are counted by vrelay alone, as before.

A server of vrelay alone installs on Debian 13: `compose.kit.yaml` no longer names the lists `compose.yaml` gives its services already (`security_opt`, `cap_drop`, `tmpfs`), which docker compose 2.26.1 doubled and refused ("services.cassandra.security_opt array items must be unique"); a test of the kit reads both files for such a list, and runs `docker compose config` on both layouts where docker is.
Cassandra of a server alone is tuned as a node of the mesh is, but for the hints and the traffic between datacenters: the 5.0 formats, the memtables off the heap, a sync of the commit log a second, the file cache, the timeouts under vrelay's own, the compaction and the guardrails (`mesh/cassandra-overrides.yaml`, one text, put over the config by `kit/cassandra-entrypoint.sh`); a store made before takes them at its next start, and its new files are of the 5.0 formats, with no way back to 4.x.
The JVM of Cassandra gets the direct buffers the kit counts (half the heap) as `-XX:MaxDirectMemorySize` last on its command line, in both layouts; before, a server alone had the image's count, a quarter of the host (3 999 MB on 16 GB in a container counted for 1 536).
Cassandra's health check is a CQL `OPTIONS` on its native port, answered `SUPPORTED`, in place of `nodetool statusbinary`, which started a JVM every 10 s (a core in ten of an 8-core machine); the containers that wait for a healthy Cassandra wait as before.
Every program of the relay has a memory limit from the machine and the components of the server, adding up to it (README, "The vrelay engine", the table for 8, 16 and 32 GB): NATS a quarter above 4 GB, 1 to 6 GB, with Go's soft limit four fifths of it (3 GB and 2.3 GiB on 16 GB: at 35 000 connections NATS held 0.8-0.9 GB and its collector ran without pause in 1 GB); Cassandra's page cache in its container a twentieth of the machine; vrelay write's `MemoryMax` a sixteenth; vrelay serve's the rest beside nginx; a server alone now passes NATS's limits to its container too, and both containers have no swap and a lower OOM score, as in the mesh.
`RELAY_MAX_CONNECTIONS` empty (the default) is what serve's limit holds at 96 KB a connection, at most 50 000: 10 000 on 8 GB, 30 000 on 16 GB with the relay alone; a number of `server.conf` is kept, and the run warns when serve's limit holds fewer.
vrelay serve listens on port 7781 of several loopback addresses (one for every 20 000 connections, two at least), and nginx spreads the WebSockets over them (`upstream veydan_vrelay`): one address had the 28 232 source ports of `ip_local_port_range`, and nginx answered 502 ("Cannot assign requested address") past them; no setting of the kernel changes, and the local lock judges by the port on the loopback as before.
The relay sites of nginx (both engines) log errors at `emerg` alone: a line of any other level about a request carries the request line with the key in its query (`crit` too, as a failed connect to vrelay); their access logs add vrelay's address, status and connect time, and the default access log of nginx writes the path without the query.

## 0.1.9

A server with a relay has an access mode, `ACCESS_MODE`: `open` (anyone who has the card uses it, as before), `team` (the owner and the people invited) or `channel` (anyone reads without the key, members write).
The first run of a server of one relay asks it, with `team`, and asks the owner's nostr key (`ADMIN_PUBKEY`), who is always a member; a server of a network of several relays, one that joins a network, and a server installed before the setting stay `open`.
Membership lives in the vguard of the relay (`[access]` of `vguard.toml`: the members in `/opt/vguard/data/members.txt`, the invites in `data/invites.json`, their secret in `/opt/vguard/etc/access.key`, made once and kept); an `open` server writes no `[access]` at all.
vguard writes the two lists itself, so on a team or channel server `/opt/vguard/data` is `0770 root:vguard` (`0750` otherwise), its unit may write there (`ReadWritePaths`), and `systemctl reload vguard` makes it read them again (`veydan-server` does it after every change).
Team and channel need a vguard that takes `[access]`, 0.7.0 or later: the kit stops, naming `VGUARD_VERSION`, when the vguard at hand refuses it, so a team server never comes up open.
vguard comes from its own release, Veydan-Guard (`VGUARD_VERSION=0.7.0`, `vguard-linux-<arch>` signed as `vguard`); releases 0.4.0–0.5.1 rode with Veydan-Push.
The programs of the releases: VCall 0.1.4, VPush 0.6.0 (without vguard), vguard 0.7.0, VLink 0.4.0 for a bridge — all built on Veydan Common.
The first run of a team server makes the first invite (one person, 7 days) and prints the card that carries it.

The relay site serves the API of vguard under `/.well-known/veydan-access/` without a key (join by an invite, the members, the invites).
A channel server's relay answers without the app key, since a link to a channel carries none; vguard lets anyone read and members write.
On a team or channel server with `MEDIA_UPLOAD_KEY=required`, the app key alone no longer uploads: nginx asks vguard whether the signer of the upload is a member (`auth_request`); the peer key and an upload key pass as before, and a download by the hash stays open.
`GET /.well-known/veydan-media` says `"access":"team"` or `"channel"`.

`veydan-server mode open|team|channel` changes the mode (then `veydan-server rerun`); `veydan-server invite [--uses N] [--days D] [--label L]` prints the card with the invite, `invite list` and `invite revoke <id>` show and end them; `veydan-server members list|add|remove <npub|hex>` keeps the list; `veydan-server card --invite <code>` puts a code on the card.
The card of a team or channel server says so (`&a=team`, `&a=channel`) and carries an invite as `&inv=<code>`; the card of an open server is as it was.

## 0.1.8

Upload keys for the media of a private server (`MEDIA_UPLOAD_KEY=required`): the owner's app gives the staff of a channel a key of their own, `vu1.…`, made with the app key, that lets one person upload (`PUT`/`HEAD /upload`) and delete (`DELETE /<sha256>`) on this host and nothing else, for at most 31 days; the upload must be signed by that person's nostr key, and the key never opens the relay.
The owner's app ends the keys of a person with `POST /.well-known/veydan-media/revoke` (the app key only); on the server, `veydan-server upload-key <label> <pubkey> [days]` makes one, `veydan-server upload-key revoke <label> <pubkey>` ends them and `veydan-server upload-key list` shows the revoked.
`GET /.well-known/veydan-media` tells the app what an upload needs: `{"v":1,"upload":"key","scoped":1}` or `{"v":1,"upload":"open"}`.
The check runs in nginx (`templates/njs/upload.js`); the revocations live in `/opt/veydan/media-keys`.

The relay may use at most 60 % of the memory of the machine (`MemoryMax` of `strfry.service`): a client that asked for more than it read made strfry hold gigabytes for it, and the kernel then killed processes of the whole server; now only the relay is restarted.

The programs of the releases: VCall 0.1.3, VPush and vguard 0.5.1 (tokio 1.54.1, RUSTSEC-2026-0386), VLink 0.3.5 for a bridge (it was still 0.3.2); in their images the agent of the project's monitoring is on unless `VEYDAN_AGENT=off`.

## 0.1.7

A server with media that is still `open` says so at every run of the installer and on `veydan-server card`; `veydan-server media-key required|open` changes the setting (then `veydan-server rerun`), and the check now refuses everything but a download, the list, the index and the CORS preflight, whatever the case of the path.

The card of a server with `vpush` carries its push server as `pu=https://<VPUSH_HOST>`, so an app that adds the server can register for pushes through the gateway.

`PUSH_GATEWAY=veydan` now does what it says: VPush of the server wakes the phones of the official Veydan apps (`VEYDAN_PUSH_APPS` of `versions.conf`) through the push of the Veydan network, the gateway (`VEYDAN_PUSH_GATEWAY`, the push server the app's manifest names for the region default), with no Firebase key.
The phone registers with a ticket the gateway gave it and a key of its own for pushes; every push is sealed to that key with the key of the server (`/opt/vpush/data/gateway.key`, made by vpush at its first start), and the gateway sees the ticket, the size and the time.
Apps with Firebase keys of their own are pushed to directly, as before, and both ways can be used at once; with `off` nothing changed.
`veydan` chosen at the first run brings `vpush` along when it is not among the components (the summary says so), and the card says how phones are woken: through the push of the Veydan network, or, with `off`, the sentence of before.
`veydan-server push` says that the setting reaches vpush at the next run of the kit (`veydan-server rerun`).
It needs Veydan-Push 0.5.0 (`VPUSH_VERSION`): the kit stops with a message when `PUSH_GATEWAY=veydan` meets an older one, and a run, `veydan-server push veydan` or `veydan-server card` of a server set to the gateway without `vpush` says `veydan-server add vpush`.
With this, a team can use the server as a private server in the Veydan apps: the app adds it from its card, keeps separate chats and groups on it, and wakes phones through the gateway; "A private server for a team" in the README walks it through.

## 0.1.6

The push server of a network comes from the release of Veydan-Push 0.4.0 too (`VPUSH_VERSION`), so `vpush` can be chosen at the install.

A server with a relay has a new setting, `PUSH_GATEWAY` (`veydan` or `off`): the installer asks whether to wake phones through the push of the Veydan network, and `veydan-server push veydan|off` changes it later.
For now it is only stored and shown on the card of the server.

The media server takes an upload only with the key of the server (`?key=` or `X-API-Key`, the app key or the peer key), as the relay does; before, anyone with a nostr key could upload.
Downloads and the list stay open. The app takes the key from the card of the server.
The check is a setting, `MEDIA_UPLOAD_KEY`: `required` for a new install, `open` for a server installed before the setting existed (it keeps its old behaviour until you set it).

`veydan-server card` prints the link that adds this server to the app (`--contact <npub>`: a link to a contact that carries the server along); the installer prints it at the end of a run.
The card names this server's own relay and media server, not the first relay of the network it belongs to.

`veydan-server rerun` no longer breaks the kit: run through its own link, it made the link point to itself, and then `show`, `add`, `join-token` and `rerun` all failed.

A relay is never put up without its read policy: vguard comes from the release of Veydan-Push 0.4.0 (`VGUARD_VERSION` in `versions.conf`), checked by its signature, unless the kit brings its own.
When there is no vguard to install, the installer stops before it changes anything and says so; it no longer puts up a relay that gives every gift wrap and group event to anyone with the app key.
A bridge, a call node and a volunteer's server have no relay and are not affected.

## 0.1.5

The node of calls is VCall 0.1.1: it names the registry of the Veydan network by its own address; nothing of the node or of its protocol changed.

## 0.1.4

The installer checks the owner's signature of what it downloads: the kit (`<kit>.sig` beside its archive) and every program taken from a release (`<file>.sig`), against the release key it carries; a file without a signature or with a wrong one is not installed.
The bridge is VLink 0.3.2: it closes a client that holds a slot without a stream, and turns away a hub the root revoked.

A HEAD request for a blob this media server does not hold now reaches the bucket of the network signed as a HEAD: a missing blob answers 404 and a present one 200 with its length (it was 403 for both, since the signature was made for a GET).
The media server takes its retention rules from `/opt/blossom/etc/rules.yml` when the file is there (a server run by Veydan Cloud: the agent lays it by the plans, so the files of paid accounts are kept longer); without it, every file is kept 14 days since its last download, as before.
A server updated with this kit puts `config.yml.new` beside its `config.yml` once, since the template changed: only comments, and the rules come in the same place.

The relay keeps gift wraps (kind 1059) and group events (kind 9) for `RELAY_RETENTION_DAYS` (90 by default; 0 keeps for ever); a timer `strfry-retention.timer` runs `strfry delete` once a day.
Other kinds stay, as before. A server updated with this kit starts deleting at its next night; set `RELAY_RETENTION_DAYS=0` first to keep everything.

The relays of a network talk to each other through a local upstream of nginx that checks the certificate of the peer and holds the peer key.
The key is no longer in the address strfry connects to, nor in its journal; after updating every relay, change `MESH_PEER_KEY`.
The relay has a read policy: vguard, between nginx and strfry, gives gift wraps only to the key that signed in and events of groups only by their group, and refuses a request with no filter worth the name.
The other relays of the network and push servers come with the peer key and read everything, as before.
vguard comes as a binary of the kit or from the release named in `versions.conf`; without it the relay is put up as before, with a warning.
vguard also reads the groups the owner of a Veydan Cloud network closed on its relays (`/opt/vguard/data/denied-groups.txt`, laid by the agent): it answers no question for their events and takes no event of them.
A vguard that does not know the file yet is left without the line, with a warning, and closes no group.

## 0.1.3

`--volunteer`: a bridge and a call node for the Veydan network on one server, by one command, without a domain.
The call node of a volunteer reports to the registry of the network by itself, as a bridge does.
`--call`: the call node alone, the same way.
The same command, run again, updates a program that came from a release: it stayed as first installed before.

## 0.1.2

The bridge is VLink 0.3.0: it reports straight to the registry of its network and carries no built-in address of another bridge.
A network may hold a new bridge until its owner approves it; the card of an open bridge says so.

## 0.1.1

The first release of the kit with its archive: one installer that asks what it needs and puts up a relay, a media server, a push server, a node of calls or a bridge on Debian 13.
A server joins a network by a key printed on any server of it.
A bridge alone goes up by one command, without a domain or a certificate.
Every media server keeps its own index and serves every file of the network from the shared bucket.

## 0.1.0

The sources of the kit; its archive was not attached to this release, so the installer of this version cannot download it. Use 0.1.1.
