# shellcheck shell=bash
# nginx and njs of nginx.org, not of Debian: nginx before 1.30.7 has a
# vulnerability and Debian 13 ships 1.26.3 (the owner's decision of
# 2026-11-19). The newest nginx of nginx.org's repository, never one older
# than NGINX_MIN, with the njs built for it; a Debian nginx is replaced
# (nginx-common and libnginx-mod-* go). The layout stays Debian's, which
# components/nginx.sh and the sites expect: the kit's nginx.conf
# (templates/nginx.conf: user www-data, modules-enabled, conf.d,
# sites-enabled), njs loaded by modules-enabled/50-official-njs.conf.
# A change of the config is tested (nginx -t) before nginx takes it; a
# refused one is undone, so the running nginx keeps the config it had.
# Sourced by components/base.sh where there is a site to serve.

NGINX_MIN=1.30.7
NGINX_KEY_URL=https://nginx.org/keys/nginx_signing.key
# The signing key of nginx.org's packages, as nginx.org/en/linux_packages.html names it.
NGINX_KEY_FPR=573BFD6B3D8FBC641079A6ABABF5BD827BD9BF62
NGINX_KEYRING=/usr/share/keyrings/nginx-archive-keyring.gpg
NGINX_LIST=/etc/apt/sources.list.d/nginx.list
NGINX_PIN=/etc/apt/preferences.d/99nginx
NGINX_NJS_CONF=/etc/nginx/modules-enabled/50-official-njs.conf
# Where nginx.org's packages put their modules (and /etc/nginx/modules points).
NGINX_MODULES=/usr/lib/nginx/modules

say "base: nginx of nginx.org (at least $NGINX_MIN, with njs)"
apt_install gpg

# Does a keyring hold the signing key of nginx.org?
nginx_key_ok() { # nginx_key_ok <keyring>
    [ -s "$1" ] || return 1
    local home rc=0
    home=$(mktemp -d)
    GNUPGHOME=$home gpg --batch --quiet --with-colons --show-keys "$1" 2>/dev/null \
        | awk -F: -v f="$NGINX_KEY_FPR" '$1 == "fpr" && $10 == f { ok = 1 } END { exit !ok }' || rc=1
    rm -rf "$home"
    return "$rc"
}

# Writes a file of the repository when it is not as given; 0 when it wrote.
nginx_put_changed() { # nginx_put_changed <dest> <text>
    local real; real=$(target "$1")
    if [ -f "$real" ] && [ "$(cat "$real")" = "$2" ]; then return 1; fi
    printf '%s\n' "$2" | put "$1" 0644 root:root
}

# --- the repository of nginx.org ---------------------------------------------

nginx_repo_changed=0
if [ "$DRY" = 1 ]; then
    printf '   + %s → gpg --dearmor → %s (fingerprint %s)\n' "$NGINX_KEY_URL" "$NGINX_KEYRING" "$NGINX_KEY_FPR"
elif ! nginx_key_ok "$NGINX_KEYRING"; then
    nginx_tmp=$(mktemp -d)
    curl -fsSL -m 30 -o "$nginx_tmp/key.asc" "$NGINX_KEY_URL" || die "nginx: could not download $NGINX_KEY_URL; nginx is as it was"
    gpg --batch --yes --dearmor -o "$nginx_tmp/keyring.gpg" "$nginx_tmp/key.asc" || die "nginx: $NGINX_KEY_URL is no key; nginx is as it was"
    nginx_key_ok "$nginx_tmp/keyring.gpg" || die "nginx: $NGINX_KEY_URL does not hold the signing key of nginx.org ($NGINX_KEY_FPR); nginx is as it was"
    install -m 0644 "$nginx_tmp/keyring.gpg" "$NGINX_KEYRING"
    rm -rf "$nginx_tmp"
    nginx_repo_changed=1
fi
# Debian 13 (trixie), the one the kit is made for.
nginx_put_changed "$NGINX_LIST" "deb [signed-by=$NGINX_KEYRING] https://nginx.org/packages/debian trixie nginx" \
    && nginx_repo_changed=1
# nginx.org's packages before Debian's, whatever their versions.
nginx_put_changed "$NGINX_PIN" "$(printf '%s\n' 'Package: *' 'Pin: origin nginx.org' 'Pin: release o=nginx' 'Pin-Priority: 900')" \
    && nginx_repo_changed=1
[ "$nginx_repo_changed" = 1 ] && run apt-get update -q

# --- the packages ----------------------------------------------------------------

# The newest version of a package in nginx.org's repository that starts
# with the prefix given (apt-cache madison lists the newest first).
nginx_org_version() { # nginx_org_version <package> [prefix]
    apt-cache madison "$1" 2>/dev/null | awk -F'|' -v p="${2:-}" '
        $3 ~ /nginx\.org\/packages/ { v = $2; gsub(/[[:space:]]/, "", v); if (index(v, p) == 1) { print v; exit } }'
}
# The version of a package installed here, or nothing.
nginx_installed() { # nginx_installed <package>
    { dpkg-query -W -f='${Status} ${Version}\n' "$1" 2>/dev/null || true; } | awk '$3 == "installed" { print $4 }'
}

nginx_swapped=0
if [ "$DRY" = 1 ]; then
    printf '   + apt-get install -o Dpkg::Options::=--force-confold nginx=<the newest of nginx.org, %s or later> nginx-module-njs=<its njs>\n' "$NGINX_MIN"
else
    nginx_want=$(nginx_org_version nginx)
    [ -n "$nginx_want" ] || die "nginx: nginx.org's repository offers no nginx (apt-cache madison nginx); nginx is as it was"
    nginx_up=${nginx_want%%-*}
    dpkg --compare-versions "$nginx_up" ge "$NGINX_MIN" \
        || die "nginx: nginx.org offers $nginx_want, older than $NGINX_MIN (the vulnerability of the older ones); nginx is as it was"
    # njs is built for one version of nginx: "1.30.7+1.0.2-1~trixie" for nginx 1.30.7.
    nginx_njs=$(nginx_org_version nginx-module-njs "$nginx_up+")
    [ -n "$nginx_njs" ] || die "nginx: nginx.org offers no nginx-module-njs for nginx $nginx_up; nginx is as it was"
    # Debian's nginx and its modules: they go with the swap.
    nginx_debian=$({ dpkg-query -W -f='${Package} ${Status}\n' nginx-common nginx-core nginx-full nginx-light nginx-extras 'libnginx-mod-*' 2>/dev/null || true; } \
        | awk '$4 == "installed" { printf "%s- ", $1 }')
    nginx_have=$(nginx_installed nginx)
    if [ "$nginx_have" = "$nginx_want" ] && [ "$(nginx_installed nginx-module-njs)" = "$nginx_njs" ] && [ -z "$nginx_debian" ]; then
        say "nginx: $nginx_want of nginx.org, njs $nginx_njs"
    else
        say "nginx: $nginx_want of nginx.org, njs $nginx_njs${nginx_have:+ (was $nginx_have)}${nginx_debian:+; out: ${nginx_debian//- / }}"
        # --force-confold keeps an edited conffile; an unedited nginx.conf of
        # Debian may still become nginx.org's (seen in a test on trixie).
        # Either way the kit's is laid below.
        # shellcheck disable=SC2086  # the packages that go, one word each
        apt_install -o Dpkg::Options::=--force-confold "nginx=$nginx_want" "nginx-module-njs=$nginx_njs" $nginx_debian \
            || die "nginx: apt-get could not install nginx $nginx_want of nginx.org (above)"
        nginx_swapped=1
    fi
fi

# --- the layout ------------------------------------------------------------------
#
# Every file changed here is kept first; when nginx -t refuses the result,
# all of them come back as they were.

nginx_bak=""
[ "$DRY" = 1 ] || nginx_bak=$(mktemp -d)
nginx_saved=()
nginx_changed=0
nginx_save() { # nginx_save <path>
    local p b s
    p=$(target "$1")
    nginx_changed=1
    [ "$DRY" = 1 ] && return 0
    for s in "${nginx_saved[@]}"; do [ "$s" = "$p" ] && return 0; done
    b=$nginx_bak/$(printf '%s' "$p" | tr / _)
    if [ -e "$p" ] || [ -L "$p" ]; then cp -a "$p" "$b"; else : > "$b.absent"; fi
    nginx_saved+=("$p")
}
nginx_undo() {
    local p b
    for p in "${nginx_saved[@]}"; do
        b=$nginx_bak/$(printf '%s' "$p" | tr / _)
        rm -f "$p"
        [ -e "$b.absent" ] || cp -a "$b" "$p"
    done
}

for d in /etc/nginx/modules-enabled /etc/nginx/conf.d /etc/nginx/sites-enabled; do mkdirp "$d" 0755 root:root; done

# nginx.conf: the kit's. One that was not (Debian's, nginx.org's) is kept
# once beside it as nginx.conf.before-veydan.
# Its limits from server.conf: the template holds the defaults.
nginx_wc=${NGINX_WORKER_CONNECTIONS:-32768}
nginx_conf=$(sed -e "s/^    worker_connections 32768;\$/    worker_connections $nginx_wc;/" \
    -e "s/^worker_rlimit_nofile 65536;\$/worker_rlimit_nofile $((nginx_wc * 2));/" "$HERE/templates/nginx.conf")
nginx_real=$(target /etc/nginx/nginx.conf)
if [ ! -f "$nginx_real" ] || [ "$(cat "$nginx_real")" != "$nginx_conf" ]; then
    if [ -f "$nginx_real" ] && ! grep -q '^# Made by run.sh' "$nginx_real" && [ ! -e "$nginx_real.before-veydan" ]; then
        run cp -a /etc/nginx/nginx.conf /etc/nginx/nginx.conf.before-veydan
    fi
    nginx_save /etc/nginx/nginx.conf
    printf '%s\n' "$nginx_conf" | put /etc/nginx/nginx.conf 0644 root:root
fi

# njs of nginx.org.
nginx_njs_text="# Made by run.sh: njs of nginx.org (nginx-module-njs), for templates/njs.
load_module $NGINX_MODULES/ngx_http_js_module.so;"
if [ "$(cat "$(target "$NGINX_NJS_CONF")" 2>/dev/null)" != "$nginx_njs_text" ]; then
    nginx_save "$NGINX_NJS_CONF"
    printf '%s\n' "$nginx_njs_text" | put "$NGINX_NJS_CONF" 0644 root:root
fi

# The other files of modules-enabled go aside as <name>.removed (as Debian's
# own scripts do) when they would stop nginx: a link to a file that is gone
# (Debian's modules-available), a second load of njs, or a module that is
# not there (Debian's dynamic stream module: nginx.org's has it built in).
for f in "$(target /etc/nginx/modules-enabled)"/*.conf; do
    [ -e "$f" ] || [ -L "$f" ] || continue
    p=${f#"$DRY_ROOT"}
    [ "$p" = "$NGINX_NJS_CONF" ] && continue
    aside=""
    if [ ! -e "$f" ]; then
        aside="a link to nothing"
    else
        while read -r m; do
            case "$m" in /*) ;; *) m=/etc/nginx/$m ;; esac
            if [ "$(basename "$m")" = ngx_http_js_module.so ]; then aside="njs, loaded by $NGINX_NJS_CONF"; break; fi
            [ -e "$(target "$m")" ] || { aside="$m is not there"; break; }
        done < <(sed -n 's/^[[:space:]]*load_module[[:space:]]\{1,\}\([^;[:space:]]*\)[[:space:]]*;.*/\1/p' "$f")
    fi
    [ -n "$aside" ] || continue
    say "nginx: $p aside ($aside)"
    nginx_save "$p"
    nginx_save "$p.removed"
    run mv -f "$p" "$p.removed"
done

# nginx.org's "Welcome to nginx!" site (a conffile of its package: once
# deleted, an upgrade leaves it deleted), as components/nginx.sh takes
# Debian's off: a name this server does not serve gets no page at all.
if [ -e "$(target /etc/nginx/conf.d/default.conf)" ]; then
    nginx_save /etc/nginx/conf.d/default.conf
    run rm -f /etc/nginx/conf.d/default.conf
fi

# --- the test, then nginx takes it -------------------------------------------------

if [ "$DRY" = 1 ]; then
    run nginx -t -q
elif ! nginx_test=$(nginx -t 2>&1); then
    nginx_what="nothing of the kit changed"
    if [ "$nginx_changed" = 1 ]; then nginx_undo; nginx_what="the files of the kit are back as they were"; fi
    rm -rf "$nginx_bak"
    nginx_state="nginx runs on the config it had"
    systemctl is-active -q nginx || nginx_state="nginx is not running"
    die "nginx refuses the config (nginx -t): $nginx_what; $nginx_state:
$nginx_test"
fi
[ -z "$nginx_bak" ] || rm -rf "$nginx_bak"
run systemctl enable nginx
if [ "$nginx_swapped" = 1 ]; then
    # The binary of nginx.org, its unit and its modules: a restart, not a reload.
    run systemctl daemon-reload
    run systemctl restart nginx
elif [ "$DRY" != 1 ] && ! systemctl is-active -q nginx; then
    run systemctl start nginx
elif [ "$nginx_changed" = 1 ]; then
    run systemctl reload nginx
fi
