// Upload keys of the media site (MEDIA_UPLOAD_KEY=required): a key that
// lets one person upload to this server and delete what they uploaded,
// and nothing else. The owner's app makes it with the app key, without
// asking the server:
//
//   vu1.<label>.<pubkey>.<iat>.<exp>.<mac>
//
// label: 1-64 hex (the app takes the first 32 hex of a channel id); pubkey:
// the x-only nostr key of the person, 64 hex; iat, exp: unix seconds; mac:
// the first 32 hex of HMAC-SHA256(app key, "veydan.media.upload.v1\n" host
// "\n" label "\n" pubkey "\n" iat "\n" exp), host being $host.
//
// Variables the site sets (10-keys.conf): $veydan_app_key, and
// $veydan_media_keys, the folder of the revocations: one file
// <label>.<pubkey> per pair, holding the time of its revocation; keys of
// the pair made at or before it are refused. For nginx's njs module.
var crypto = require('crypto');
var fs = require('fs');

var LIFE = 31 * 86400;   // the longest life of a key
var SKEW = 300;          // a clock ahead of ours by this much is fine
var KEEP = 32 * 86400;   // a revocation older than any key still alive goes
var KEY = /^vu1\.([0-9a-f]{1,64})\.([0-9a-f]{64})\.([0-9]{1,10})\.([0-9]{1,10})\.([0-9a-f]{32})$/;
var HEX = /^[0-9a-f]{64}$/;
var LABEL = /^[0-9a-f]{1,64}$/;
var BLOB = /^\/[0-9a-f]{64}(\.[a-z0-9]+)?$/;
var PAIR = /^[0-9a-f]{1,64}\.[0-9a-f]{64}$/;

function now() {
    return Math.floor(Date.now() / 1000);
}

// Without a timing hint of where the strings differ.
function same(a, b) {
    if (typeof a !== 'string' || typeof b !== 'string' || a.length !== b.length) return false;
    var d = 0;
    for (var i = 0; i < a.length; i++) d |= a.charCodeAt(i) ^ b.charCodeAt(i);
    return d === 0;
}

function mac(appKey, host, label, pubkey, iat, exp) {
    return crypto.createHmac('sha256', appKey)
        .update(['veydan.media.upload.v1', host, label, pubkey, iat, exp].join('\n'))
        .digest('hex').substring(0, 32);
}

// The upload key of the request: in ?key= or X-Api-Key.
function given(r) {
    var q = r.args.key, h = r.headersIn['X-Api-Key'];
    if (typeof q === 'string' && q.substring(0, 4) === 'vu1.') return q;
    if (typeof h === 'string' && h.substring(0, 4) === 'vu1.') return h;
    return '';
}

// The two writes an upload key may make, by the path as sent: a path that
// nginx had to decode or tidy up is not taken (blossom would see another).
function allowed(r) {
    var path = r.variables.request_uri.split('?')[0];
    if (path !== r.uri) return false;
    if (r.method === 'PUT' || r.method === 'HEAD') return path === '/upload';
    if (r.method === 'DELETE') return BLOB.test(path);
    return false;
}

// The pubkey of the nostr event in "Authorization: Nostr <base64>". Blossom
// checks the signature of the same header afterwards; base64 of a strict
// form only, so both read the same bytes.
function signer(r) {
    var h = r.headersIn.Authorization;
    if (typeof h !== 'string' || h.substring(0, 6) !== 'Nostr ') return '';
    var b = h.substring(6).trim();
    if (!/^[A-Za-z0-9+/_-]+={0,2}$/.test(b)) return '';
    var ev = JSON.parse(Buffer.from(b.replace(/-/g, '+').replace(/_/g, '/'), 'base64').toString());
    return ev && typeof ev.pubkey === 'string' ? ev.pubkey : '';
}

// When the pair was revoked: 0 never; a file that cannot be read refuses.
function revokedAt(dir, label, pubkey) {
    var text;
    try {
        text = fs.readFileSync(dir + '/' + label + '.' + pubkey, 'utf8');
    } catch (e) {
        return e.code === 'ENOENT' ? 0 : Infinity;
    }
    var at = parseInt(text, 10);
    return isNaN(at) ? Infinity : at;
}

// js_set $veydan_upload_ok: "1" when the request carries a good upload key
// for what it does, "0" otherwise (and at once when there is none).
function ok(r) {
    try {
        var key = given(r);
        if (!key) return '0';
        var m = KEY.exec(key);
        var appKey = r.variables.veydan_app_key, dir = r.variables.veydan_media_keys;
        if (!m || !appKey || !dir || !allowed(r)) return '0';
        var label = m[1], pubkey = m[2], iat = Number(m[3]), exp = Number(m[4]), t = now();
        if (!same(mac(appKey, r.variables.host, label, pubkey, m[3], m[4]), m[5])) return '0';
        if (!(t < exp && iat < exp && exp - iat <= LIFE && iat <= t + SKEW)) return '0';
        if (signer(r) !== pubkey) return '0';
        if (iat <= revokedAt(dir, label, pubkey)) return '0';
        return '1';
    } catch (e) {
        return '0';
    }
}

// POST /.well-known/veydan-media/revoke?label=<label>&pubkey=<hex>, with the
// app key in X-Api-Key: the keys of the pair made until now are refused.
function revoke(r) {
    var appKey = r.variables.veydan_app_key, dir = r.variables.veydan_media_keys;
    if (!appKey || !dir || !same(r.headersIn['X-Api-Key'], appKey)) return r.return(401);
    if (r.method !== 'POST') return r.return(405);
    var label = r.args.label, pubkey = r.args.pubkey;
    if (typeof label !== 'string' || typeof pubkey !== 'string' || !LABEL.test(label) || !HEX.test(pubkey)) {
        return r.return(400);
    }
    var t = now();
    try {
        // A new file, then renamed over the old one: a reader sees one or the other.
        var tmp = dir + '/.' + label + '.' + pubkey + '.' + Math.random().toString(36).substring(2);
        fs.writeFileSync(tmp, String(t) + '\n', { mode: 0o600 });
        fs.renameSync(tmp, dir + '/' + label + '.' + pubkey);
    } catch (e) {
        r.error('upload keys: cannot write the revocation: ' + e.message);
        return r.return(500);
    }
    // Revocations older than any key still alive.
    fs.readdirSync(dir).forEach(function (name) {
        if (!PAIR.test(name)) return;
        try {
            var at = parseInt(fs.readFileSync(dir + '/' + name, 'utf8'), 10);
            if (at < t - KEEP) fs.unlinkSync(dir + '/' + name);
        } catch (e) { /* gone, or not ours to clean */ }
    });
    r.headersOut['Content-Type'] = 'application/json';
    return r.return(200, JSON.stringify({ v: 1, revoked_at: t }));
}

export default { ok, revoke };
