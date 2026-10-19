# Changelog

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
