# Third-party notices

Veydan Server is a set of shell scripts and configuration files; it is built
from no third-party package and its release holds no binary of anyone's.

What it installs on a server, it takes from the sources of each program at
install time, at the version pinned in `versions.conf`, and each program comes
under its own licence, which is in its repository:

| Program | Source |
|---|---|
| strfry | https://github.com/hoytech/strfry |
| blossom-server | https://github.com/hzrd149/blossom-server |
| Deno | https://github.com/denoland/deno |
| libsql-server (sqld) | https://github.com/tursodatabase/libsql |
| nginx, certbot, ufw and the other packages of Debian | https://www.debian.org |

VPush and VCall, the programs of the Veydan Project the kit installs, carry
their own notices in their releases.
