# NoBars wire protocol (v1)

How iPhones and Android phones find each other, prove they're in the same group and pass packets along. `reference.py` implements the crypto parts in plain Python and generates `vectors.json`; the Swift tests (`Tests/MeshCoreTests`) and the Kotlin tests (`android/core`) both check themselves against it. `vectors-android.json` is written by the Kotlin code and checked by the Swift tests, so each platform reads the other's output.

## Group keys

From a group code `c` (UTF-8, trimmed; empty means the open mesh):

```
d0     = SHA256("NoBars.group.v1|" + c)
d      = SHA256 applied 50,000 more times to d0
key    = HKDF-SHA256(ikm=d, salt="NoBars.v1", info="payload",   32 bytes)
tagKey = HKDF-SHA256(ikm=d, salt="NoBars.v1", info="discovery", 32 bytes)
tag    = hex(HMAC-SHA256(tagKey, "tag")[0:8])     // 16 lowercase hex chars
```

`tag` is public. The code and `key` never leave the phone.

## Packets

JSON object, the same field names Swift's `JSONEncoder` writes for `MeshRelayPacket`. Absent optionals are omitted.

| Field | Type | Notes |
|---|---|---|
| `id` | string | UUID, uppercase when signing |
| `ttl` | int | hops left, starts at 10 |
| `kind` | string | `message`, `location`, `hello`, `call`, `voice` |
| `senderName` | string | |
| `timestamp` | number | seconds since 2001-01-01 UTC (Apple reference date) |
| `text` | string? | chat text, or `invite` / `end` for `call` |
| `latitude`, `longitude` | number? | |
| `isEmergency` | bool? | SOS flag on `location` |
| `senderKey` | base64? | Ed25519 public key, 32 bytes |
| `signature` | base64? | Ed25519 signature, 64 bytes |
| `to` | string? | addressee of `call` / `voice` |
| `seq` | int? | `voice` chunk number |
| `audio` | base64? | `voice`: 8 kHz G.711 mu-law, 1280 samples |

### Signature

Ed25519 over these fields, each as UTF-8 prefixed with its byte length as a big-endian u32:

```
"NB1", id (uppercase), kind, senderName, bits(timestamp), text|"-",
bits(latitude)|"-", bits(longitude)|"-", isEmergency ("1"/"0")|"-",
senderKey (base64)|"-", to|"-", seq (decimal)|"-", audio (base64)|"-"
```

`bits(x)` is the IEEE 754 bit pattern of the double as an unsigned decimal integer. `ttl` is left out because relays change it.

### Sealing

```
sealed = "NB1" || nonce (12) || ChaCha20-Poly1305(key, nonce, json) || tag (16)
```

That's CryptoKit's `ChaChaPoly.SealedBox.combined` with a 3-byte prefix. No associated data.

## Rules every phone follows

1. A new link isn't trusted until a `hello` arrives over it: `ttl` 1, signed, sealed with the group key. Both sides send one right away. No valid hello within 10 seconds and the link is dropped.
2. Over MultipeerConnectivity the hello's `senderName` must equal the link's display name. A hello using your own name is rejected.
3. The first key seen for a name is pinned. A later packet with that name and another key is dropped (and its link, if it's a hello).
4. Packets that aren't `message` and are more than 10 minutes old are dropped.
5. Routing: drop if `id` was seen before; otherwise deliver, decrement `ttl`, and forward to every verified link except the one it came from while `ttl` > 0.
6. `call` and `voice` are only delivered to `to`, and only forwarded over Wi-Fi (MultipeerConnectivity) links. Bluetooth LE is too slow for audio.

## Bluetooth LE

Service `6E6F6261-7273-4D65-7368-000000000001`:

| Characteristic | UUID suffix | Properties | Use |
|---|---|---|---|
| INFO | `...0002` | read | `{"v":1,"g":<tag>,"t":<token>}` |
| RX | `...0003` | write, write without response | frames central to peripheral |
| TX | `...0004` | notify | frames peripheral to central |

Every phone advertises the service and scans for it. A central connects, reads INFO, disconnects (and waits 30 s) if `g` isn't its tag or the `t` token belongs to a phone it already reaches over MultipeerConnectivity, then subscribes to TX. Subscribing makes the link; then both sides send their hello.

Sealed packets are split into frames no bigger than the link allows (MTU minus 3):

```
[0x01][message seq u32 big-endian][index u8][count u8][chunk]
```

Up to 255 chunks. Partial messages are dropped after 30 s.

## MultipeerConnectivity (iPhone to iPhone)

Service type `nobars-mesh`, encryption required. Discovery info is `{"token": <token>, "g": <tag>}` and the invitation context is `"<tag>|<token>"`. Phones only invite or accept peers with their own tag, and the phone with the lower token sends the invite.
