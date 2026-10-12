// A blob this media server has not got is read from the bucket of the
// network by its hash. The bucket stays private: nginx signs each GET with
// the keys of the server (AWS Signature V4). For nginx's njs module.
//
// Variables the site sets: $s3_key, $s3_secret, $s3_region, $s3_host (the
// Host the bucket expects), $s3_path (/<bucket>/<hash>). $s3_ts is a js_var
// that keeps the timestamp, so the date header and the signature agree.
var crypto = require('crypto');

var EMPTY_SHA256 = 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855';
var SIGNED = 'host;x-amz-content-sha256;x-amz-date';

function stamp(r) {
    if (!r.variables.s3_ts) {
        r.variables.s3_ts = new Date().toISOString().replace(/[-:]/g, '').replace(/\.\d{3}/, '');
    }
    return r.variables.s3_ts;
}

function hmac(key, s) {
    return crypto.createHmac('sha256', key).update(s).digest();
}

function date(r) {
    return stamp(r);
}

function authorization(r) {
    var ts = stamp(r);
    var day = ts.substring(0, 8);
    var region = r.variables.s3_region;
    var scope = day + '/' + region + '/s3/aws4_request';
    var canonical = ['GET', r.variables.s3_path, '',
        'host:' + r.variables.s3_host,
        'x-amz-content-sha256:' + EMPTY_SHA256,
        'x-amz-date:' + ts,
        '', SIGNED, EMPTY_SHA256].join('\n');
    var toSign = ['AWS4-HMAC-SHA256', ts, scope,
        crypto.createHash('sha256').update(canonical).digest('hex')].join('\n');
    var k = hmac('AWS4' + r.variables.s3_secret, day);
    k = hmac(k, region);
    k = hmac(k, 's3');
    k = hmac(k, 'aws4_request');
    var sig = crypto.createHmac('sha256', k).update(toSign).digest('hex');
    return 'AWS4-HMAC-SHA256 Credential=' + r.variables.s3_key + '/' + scope +
        ', SignedHeaders=' + SIGNED + ', Signature=' + sig;
}

export default { date, authorization };
