#!/usr/bin/env python3
"""Wi2 (Starbucks JP) in-place captive re-login.

The portal flow (reverse-engineered from js/login-1.0-min.js) is JavaScript-driven,
so a plain form submit can't finish it. The actual login is an AJAX call:

    captive redirect -> /freewifi/starbucks/index.html   (registers session, sets cookies)
    "Connect" button -> GET agreement.html
    "Accept"  button -> POST {"login_method":"onetap","login_params":{"agree":"1"}}
                        to /wi2auth/xhr/login
                        (Content-Type: application/json; success == JSON result 1 / "true")

We replay that directly with urllib + a cookie jar (no JS engine, no network installs).
The caller (wifi-watch.sh) verifies real connectivity afterwards.

Exit codes: 0 accepted; 2 bad usage; 3 portal unreachable; 5 POST failed;
            6 non-JSON response; 7 portal rejected (result falsy).
"""
import sys
import ssl
import json
import urllib.error
import urllib.parse
import urllib.request
import http.cookiejar

UA = (
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
    "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"
)
LOGIN_API_PATH = "/wi2auth/xhr/login"
ONETAP_PAYLOAD = json.dumps(
    {"login_method": "onetap", "login_params": {"agree": "1"}}
).encode("utf-8")


class RetryUnverified(Exception):
    """Raised to signal the caller to retry with SSL verification disabled."""


def log(msg):
    print("[relogin] %s" % msg, flush=True)


def make_opener(verify=True):
    cj = http.cookiejar.CookieJar()
    handlers = [urllib.request.HTTPCookieProcessor(cj)]
    if not verify:
        ctx = ssl.create_default_context()
        ctx.check_hostname = False
        ctx.verify_mode = ssl.CERT_NONE
        handlers.append(urllib.request.HTTPSHandler(context=ctx))
    return urllib.request.build_opener(*handlers), cj


def open_url(opener, url, data=None, extra_headers=None):
    headers = {"User-Agent": UA}
    if extra_headers:
        headers.update(extra_headers)
    req = urllib.request.Request(url, data=data, headers=headers)
    try:
        return opener.open(req, timeout=12)
    except urllib.error.URLError as e:
        if isinstance(e.reason, ssl.SSLCertVerificationError):
            raise RetryUnverified(str(e.reason))
        raise


def run(url, verify):
    """Execute the full Wi2 flow with the given SSL policy. Returns exit code."""
    opener, cj = make_opener(verify)

    # 1) Follow the captive redirect -> index.html (registers session, sets cookies).
    resp = open_url(opener, url)
    final = resp.geturl()
    resp.read()
    log("portal landing: %s (%d cookies)" % (final, len(cj)))

    parts = urllib.parse.urlparse(final)
    base_root = "%s://%s" % (parts.scheme, parts.netloc)
    agreement_url = final.rstrip("/").rsplit("/", 1)[0] + "/agreement.html"
    login_url = base_root + LOGIN_API_PATH

    # 2) "Connect": GET agreement.html (best effort; mirrors the button navigation).
    try:
        resp = open_url(opener, agreement_url)
        log("connect step: GET %s -> %s" % (agreement_url, resp.getcode()))
        resp.read()
    except RetryUnverified:
        raise
    except Exception as e:
        log("connect step skipped: %s" % e)

    # 3) "Accept": POST the onetap login JSON.
    headers = {
        "Content-Type": "application/json",
        "Accept": "application/json, text/javascript, */*; q=0.01",
        "X-Requested-With": "XMLHttpRequest",
        "Referer": agreement_url,
        "Origin": base_root,
    }
    resp = open_url(opener, login_url, data=ONETAP_PAYLOAD, extra_headers=headers)
    body = resp.read().decode("utf-8", "replace")
    log("login POST %s -> HTTP %s, %d bytes" % (login_url, resp.getcode(), len(body)))

    # 4) Evaluate the result.
    try:
        data = json.loads(body)
    except Exception:
        log("login response is not JSON: %s" % " ".join(body[:200].split()))
        return 6

    result = data.get("result")
    ok = result in (1, "1", True, "true", "TRUE")
    log("login result=%s accepted=%s" % (result, ok))
    if ok:
        log("RELOGIN accepted by portal")
        return 0
    log("login rejected; response: %s" % " ".join(body[:300].split()))
    return 7


def main():
    if len(sys.argv) < 2:
        log("usage: relogin_wi2.py <portal_url>")
        return 2
    url = sys.argv[1]

    # Try with SSL verification first; fall back to unverified only on cert errors
    # (some captive portals present an odd chain; transport security here is moot).
    for verify in (True, False):
        try:
            return run(url, verify)
        except RetryUnverified as e:
            log("SSL verify failed (%s); retrying without verification" % e)
            continue
        except Exception as e:
            log("flow failed: %s" % e)
            return 3
    log("flow failed even without SSL verification")
    return 3


if __name__ == "__main__":
    sys.exit(main())
