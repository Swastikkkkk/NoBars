#!/usr/bin/env python3
"""Reference implementation of the NoBars wire format, used to generate
protocol/vectors.json. The Swift (iOS) and Kotlin (Android) test suites both
check themselves against those vectors, so the two apps provably agree on
keys, encryption and signatures without needing real phones.

    python3 protocol/reference.py > protocol/vectors.json
"""
import base64, hashlib, hmac, json, struct, uuid
from cryptography.hazmat.primitives.ciphers.aead import ChaCha20Poly1305
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
from cryptography.hazmat.primitives import serialization

STRETCH_ROUNDS = 50_000
MAGIC = b"NB1"


def hkdf(ikm: bytes, salt: bytes, info: bytes, n: int = 32) -> bytes:
    prk = hmac.new(salt, ikm, hashlib.sha256).digest()
    out, t, i = b"", b"", 1
    while len(out) < n:
        t = hmac.new(prk, t + info + bytes([i]), hashlib.sha256).digest()
        out += t
        i += 1
    return out[:n]


def group_keys(code: str):
    d = hashlib.sha256(f"NoBars.group.v1|{code}".encode()).digest()
    for _ in range(STRETCH_ROUNDS):
        d = hashlib.sha256(d).digest()
    salt = b"NoBars.v1"
    key = hkdf(d, salt, b"payload")
    tag_key = hkdf(d, salt, b"discovery")
    tag = hmac.new(tag_key, b"tag", hashlib.sha256).digest()[:8].hex()
    return key, tag


def bits(x):
    return "-" if x is None else str(struct.unpack(">Q", struct.pack(">d", x))[0])


def signing_bytes(p: dict) -> bytes:
    fields = [
        "NB1",
        p["id"].upper(),
        p["kind"],
        p["senderName"],
        bits(p["timestamp"]),
        p.get("text", "-") if p.get("text") is not None else "-",
        bits(p.get("latitude")),
        bits(p.get("longitude")),
        "-" if p.get("isEmergency") is None else ("1" if p["isEmergency"] else "0"),
        p.get("senderKey", "-") or "-",
        p.get("to") if p.get("to") is not None else "-",
        "-" if p.get("seq") is None else str(p["seq"]),
        p.get("audio", "-") or "-",
    ]
    out = b""
    for f in fields:
        b = f.encode()
        out += struct.pack(">I", len(b)) + b
    return out


def sign(p: dict, sk: Ed25519PrivateKey):
    pub = sk.public_key().public_bytes(serialization.Encoding.Raw, serialization.PublicFormat.Raw)
    p["senderKey"] = base64.b64encode(pub).decode()
    p["signature"] = base64.b64encode(sk.sign(signing_bytes(p))).decode()


def seal(p: dict, key: bytes, nonce: bytes) -> bytes:
    plain = json.dumps(p, separators=(",", ":")).encode()
    return MAGIC + nonce + ChaCha20Poly1305(key).encrypt(nonce, plain, None)


def main():
    seed = bytes(range(32))
    sk = Ed25519PrivateKey.from_private_bytes(seed)
    groups = []
    for code in ["", "ci", "fest24", "Gate 3 · मेला 2026 🎪"]:
        key, tag = group_keys(code)
        groups.append({"code": code, "tag": tag, "key": key.hex()})

    key, _ = group_keys("fest24")
    packets = [
        {"id": "6F1D2C3B-4A59-4687-9C1E-0B2A3C4D5E6F", "ttl": 10, "kind": "message",
         "senderName": "Arjun", "timestamp": 784555123.456, "text": "meet at gate 3"},
        {"id": "0A1B2C3D-4E5F-4061-8293-A4B5C6D7E8F9", "ttl": 7, "kind": "location",
         "senderName": "Kabir", "timestamp": 784555200.125, "latitude": 28.4744,
         "longitude": 77.504, "isEmergency": True},
        {"id": "11111111-2222-4333-8444-555555555555", "ttl": 1, "kind": "hello",
         "senderName": "Riya", "timestamp": 784555300.0},
        {"id": "22222222-3333-4444-8555-666666666666", "ttl": 10, "kind": "call",
         "senderName": "Arjun", "timestamp": 784555400.5, "text": "invite", "to": "Kabir"},
        {"id": "33333333-4444-4555-8666-777777777777", "ttl": 10, "kind": "voice",
         "senderName": "Arjun", "timestamp": 784555401.0, "to": "Kabir", "seq": 42,
         "audio": base64.b64encode(bytes(range(0, 256, 3))).decode()},
    ]
    sealed = []
    for i, p in enumerate(packets):
        sign(p, sk)
        nonce = bytes([i]) * 12
        sealed.append({
            "packet": dict(p),
            "signingBytes": signing_bytes(p).hex(),
            "sealed": seal(p, key, nonce).hex(),
        })

    tampered = dict(packets[0]); tampered["text"] = "meet at gate 4"
    print(json.dumps({
        "version": 1,
        "stretchRounds": STRETCH_ROUNDS,
        "groups": groups,
        "sealedWithGroup": "fest24",
        "signingKeySeed": seed.hex(),
        "packets": sealed,
        "badSignature": tampered,
    }, indent=2, ensure_ascii=False))


if __name__ == "__main__":
    main()
