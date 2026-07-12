"""End-to-end test for the admin session-auth layer in cloud_function/main.py.

Drives the real api_handler against real Firestore + Secret Manager (no deploy).
Requires GCP auth (service_account.json in this dir, or ADC) and the
`arboryx-admin-users` secret to contain at least one user.

    python3 dev-utils/test_admin_auth.py

Exit code 0 = all pass, 1 = a failure.
"""
import os
import sys
import json

svc = os.path.join(os.path.dirname(__file__), "service_account.json")
if os.path.exists(svc):
    os.environ["GOOGLE_APPLICATION_CREDENTIALS"] = svc

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "cloud_function"))
import main  # noqa: E402

PASS = 0
FAIL = 0


class CIDict(dict):
    """Case-insensitive header dict (Flask headers are case-insensitive)."""
    def get(self, key, default=None):
        for k, v in self.items():
            if k.lower() == key.lower():
                return v
        return default


class FakeRequest:
    def __init__(self, action="findings", method="GET", headers=None, json_body=None, args=None):
        a = {"action": action}
        if args:
            a.update(args)
        self.args = a
        self.method = method
        self.headers = CIDict(headers or {})
        self._json = json_body
        self.remote_addr = "203.0.113.7"

    def get_json(self, silent=False):
        return self._json


def call(req):
    body, status, headers = main.api_handler(req)
    if isinstance(body, (bytes, bytearray)):
        import gzip as _gz
        body = _gz.decompress(body).decode("utf-8")
    try:
        data = json.loads(body) if body else {}
    except Exception:
        data = {"_raw": body}
    return status, data, headers


def check(label, cond, detail=""):
    global PASS, FAIL
    if cond:
        PASS += 1
        print(f"  \033[0;32mPASS\033[0m  {label}")
    else:
        FAIL += 1
        print(f"  \033[0;31mFAIL\033[0m  {label}  {detail}")


ORIGIN = {"Origin": "https://storage.googleapis.com"}


def main_test():
    users = main._fetch_admin_users()
    assert users, "arboryx-admin-users secret is empty — run manage_admin_users.sh create first"
    username = "kazi-admin" if "kazi-admin" in users else next(iter(users))
    password = users[username]
    print(f"\nTesting with user: {username}\n")

    # Clean slate.
    main._delete_session()
    main._login_fails.clear()

    # 1. Unauthenticated data request is rejected.
    s, d, _ = call(FakeRequest("findings", headers=ORIGIN))
    check("no-auth findings -> 401", s == 401, f"got {s}")

    # 2. Login missing fields -> 400.
    s, d, _ = call(FakeRequest("login", method="POST", headers=ORIGIN, json_body={"username": username}))
    check("login missing password -> 400", s == 400, f"got {s}")

    # 3. Login wrong password -> 401, generic message.
    s, d, _ = call(FakeRequest("login", method="POST", headers=ORIGIN, json_body={"username": username, "password": "wrong"}))
    check("login wrong password -> 401", s == 401, f"got {s}")
    check("wrong-password error is generic", "Invalid username or password" in d.get("error", ""), d)

    # 4. Login unknown user -> 401, SAME generic message (no user enumeration).
    s2, d2, _ = call(FakeRequest("login", method="POST", headers=ORIGIN, json_body={"username": "nope", "password": "x"}))
    check("unknown user error == wrong-password error (no enumeration)",
          d2.get("error") == d.get("error"), f"{d2.get('error')!r} vs {d.get('error')!r}")

    # 5. Login GET -> 405.
    s, d, _ = call(FakeRequest("login", method="GET", headers=ORIGIN))
    check("login via GET -> 405", s == 405, f"got {s}")

    # 6. Correct login -> token.
    s, d, _ = call(FakeRequest("login", method="POST", headers=ORIGIN, json_body={"username": username, "password": password}))
    check("correct login -> 200", s == 200, f"got {s} {d}")
    token = d.get("token", "")
    check("login returns a token", len(token) >= 40, f"len={len(token)}")
    check("token is NOT stored plaintext in Firestore",
          main._session_doc_ref().get().to_dict().get("token_hash") == main._hash_token(token))
    check("Firestore doc has no raw token field",
          "token" not in (main._session_doc_ref().get().to_dict() or {}))

    auth = {**ORIGIN, "X-Session-Token": token}

    # 7. Authenticated read works.
    s, d, _ = call(FakeRequest("findings", headers=auth, args={"limit": "1"}))
    check("session findings -> 200", s == 200, f"got {s}")

    # 8. session endpoint reflects the login.
    s, d, _ = call(FakeRequest("session", headers=auth))
    check("session -> 200 with username", s == 200 and d.get("username") == username, d)

    # 9. Write action allowed with session token (refresh is a write action).
    s, d, _ = call(FakeRequest("refresh", headers=auth))
    check("session can perform write action (refresh) -> 200", s == 200, f"got {s} {d}")

    # 10. Bad/garbage token -> 401 (no fall-through to key auth).
    s, d, _ = call(FakeRequest("findings", headers={**ORIGIN, "X-Session-Token": "garbage"}))
    check("garbage token -> 401", s == 401, f"got {s}")

    # 11. CORS header advertises X-Session-Token.
    s, d, h = call(FakeRequest("findings", method="OPTIONS", headers=ORIGIN))
    check("preflight allows X-Session-Token header",
          "X-Session-Token" in h.get("Access-Control-Allow-Headers", ""), h.get("Access-Control-Allow-Headers"))

    # 12. Single active session: a SECOND login invalidates the FIRST token.
    s, d2, _ = call(FakeRequest("login", method="POST", headers=ORIGIN, json_body={"username": username, "password": password}))
    token2 = d2.get("token", "")
    check("second login -> new token", token2 and token2 != token, "tokens should differ")
    s, d, _ = call(FakeRequest("findings", headers={**ORIGIN, "X-Session-Token": token}, args={"limit": "1"}))
    check("first token invalidated after second login -> 401", s == 401, f"got {s}")
    s, d, _ = call(FakeRequest("findings", headers={**ORIGIN, "X-Session-Token": token2}, args={"limit": "1"}))
    check("second token still valid -> 200", s == 200, f"got {s}")

    # 13. Logout invalidates the session.
    s, d, _ = call(FakeRequest("logout", method="POST", headers={**ORIGIN, "X-Session-Token": token2}))
    check("logout -> 200", s == 200, f"got {s}")
    s, d, _ = call(FakeRequest("findings", headers={**ORIGIN, "X-Session-Token": token2}, args={"limit": "1"}))
    check("token rejected after logout -> 401", s == 401, f"got {s}")

    # 14. Expiry: forge an already-expired session doc.
    main._session_doc_ref().set({
        "token_hash": main._hash_token("expiredtok"), "username": username,
        "ip": "x", "issued_at": 0, "expires_at": 1,
    })
    check("expired session token rejected", main._validate_session_token("expiredtok") is None)
    main._delete_session()

    # 15. Lockout after LOGIN_MAX_FAILS bad attempts.
    main._login_fails.clear()
    lock_hit = False
    for i in range(main.LOGIN_MAX_FAILS + 1):
        s, d, _ = call(FakeRequest("login", method="POST", headers=ORIGIN, json_body={"username": username, "password": "bad"}))
        if s == 429:
            lock_hit = True
            break
    check("IP locked out after repeated failures -> 429", lock_hit, f"never got 429")
    main._login_fails.clear()

    # 16. Backward compat: a valid API key still works with no session token.
    keys = list(main._WRITE_KEYS)
    if keys:
        s, d, _ = call(FakeRequest("findings", headers={**ORIGIN, "X-API-Key": keys[0]}, args={"limit": "1"}))
        check("existing admin API key still works -> 200", s == 200, f"got {s}")
    else:
        print("  (skip) no write keys configured to test key back-compat")

    # Cleanup.
    main._delete_session()
    main._login_fails.clear()


if __name__ == "__main__":
    try:
        main_test()
    except AssertionError as e:
        print(f"\nSETUP ERROR: {e}")
        sys.exit(1)
    print(f"\n{'='*44}")
    print(f"  {PASS} passed, {FAIL} failed")
    print(f"{'='*44}")
    sys.exit(1 if FAIL else 0)
