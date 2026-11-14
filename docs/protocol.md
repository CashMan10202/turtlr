# BuildKit protocol v1

_Generated from `lib/proto.lua` by `tools/gen_protocol_doc.lua`. Do not edit by hand._

## Channels

| Channel | Use |
|---|---|
| 4201 | devices (pockets, turtles) -> INCOMING |
| 4202 | OUTGOING -> devices |
| 4210 | internal bus between base computers |
| 4211 | heartbeats and telemetry to MONITOR |

Raw modem channels are used, not rednet, so no rednet sender information is ever trusted.

## Frames

External frame (device <-> edge):

```
ver (1 byte) | devId (varint) | counter (varint) | AEAD ciphertext + tag
```

- Key: BLAKE3-derived from X25519(device key, edge key). Nonce: the counter. The header is authenticated.
- Plaintext: the encoded message followed by an Ed25519 signature over header + message.
- INCOMING drops a frame if: too large, unknown or revoked device, counter not higher than the last one seen,
  timestamp too far from server time, decryption fails, or the message does not match the tables below.
- COMPUTE checks the signature again, so the gateway alone cannot invent requests.

Messages are packed with `lib/codec.lua` (booleans, integers, strings, lists, tables only).
Text is never executed and there are no free-text fields that reach a turtle.

## Envelope

Request: `{ v = 1, t = <type>, id = <request number>, ts = <ms since 1970>, b = <body> }`

Response: `{ v = 1, t = <type>, re = <request number>, ok = true, b = <body> }`
or `{ v = 1, t = <type>, re = <request number>, ok = false, err = <code> }`

Error codes: `bad_request`, `not_found`, `not_allowed`, `rate_limited`, `quota`, `busy`, `maintenance`, `too_big`, `expired`, `internal`

## Limits

| Name | Value |
|---|---|
| areaD | 48 |
| areaH | 64 |
| areaW | 48 |
| frameDefault | 2048 |
| frameMax | 8192 |
| jobBlocks | 20000 |
| jobsActive | 3 |
| scanRadius | 16 |
| schematicQuota | 2097152 |
| uploadBytes | 262144 |

## Turtle limits

Set by the player on the pocket; every value is capped by `turtleMax` in the COMPUTE config.

| Field | Allowed | Default |
|---|---|---|
| `chop` | true/false | false |
| `d` | integer 1..48 | 16 |
| `down` | integer 0..64 | 4 |
| `fuelReserve` | integer 0..20000 | 500 |
| `keepOut` | list (max 8) of: list (max 6) of: integer -64..64 | none |
| `machines` | true/false | false |
| `maxMinutes` | integer 1..1440 | 240 |
| `me` | true/false | false |
| `mine` | true/false | false |
| `mineMax` | integer 0..4096 | 256 |
| `take` | one of: `none`, `marked`, `all` | marked |
| `up` | integer 0..64 | 16 |
| `w` | integer 1..48 | 16 |

## Messages

### `acct.get`

Request body:

_(no fields)_

Response body:

| Field | Required | Allowed |
|---|---|---|
| `blocksMax` | yes | integer 0..10000000 |
| `devices` | yes | integer 0..100 |
| `jobsActive` | yes | integer 0..100 |
| `jobsMax` | yes | integer 0..100 |
| `name` | yes | text, max 16 |
| `quotaMax` | yes | integer 0..2147483648 |
| `quotaUsed` | yes | integer 0..2147483648 |

### `hello`

Request body:

| Field | Required | Allowed |
|---|---|---|
| `caps` | yes | integer 0..7 |
| `client` | yes | text, max 16 |

Response body:

| Field | Required | Allowed |
|---|---|---|
| `minClient` | yes | text, max 16 |
| `server` | yes | text, max 16 |
| `state` | yes | one of: `ok`, `maintenance` |
| `time` | yes | integer 0..9007199254740992 |

### `import.link`

Request body:

| Field | Required | Allowed |
|---|---|---|
| `url` | yes | text, max 256 , form `^https://[A-Za-z0-9.-]+/[A-Za-z0-9._~/%%?&=+-]*$` |

Response body:

| Field | Required | Allowed |
|---|---|---|
| `ref` | yes | text, max 24 , form `^[A-Za-z0-9]+$` |

### `import.status`

Request body:

| Field | Required | Allowed |
|---|---|---|
| `ref` | yes | text, max 24 , form `^[A-Za-z0-9]+$` |

Response body:

| Field | Required | Allowed |
|---|---|---|
| `ref` | yes | text, max 24 , form `^[A-Za-z0-9]+$` |
| `state` | yes | one of: `queued`, `fetching`, `parsing`, `ok`, `rejected` |
| `code` | no | one of: `too_big`, `bad_format`, `bad_host`, `timeout`, `blocked_blocks`, `quota` |
| `count` | no | integer 0..10000000 |
| `d` | no | integer 1..64 |
| `dropped` | no | integer 0..10000000 |
| `h` | no | integer 1..64 |
| `hand` | no | integer 0..10000000 |
| `w` | no | integer 1..64 |

### `job.approve`

Request body:

| Field | Required | Allowed |
|---|---|---|
| `job` | yes | text, max 24 , form `^[A-Za-z0-9]+$` |
| `plan` | yes | text, max 24 , form `^[A-Za-z0-9]+$` |

Response body:

| Field | Required | Allowed |
|---|---|---|
| `job` | yes | text, max 24 , form `^[A-Za-z0-9]+$` |
| `state` | yes | one of: `quoted`, `awaiting_turtle`, `survey`, `plan`, `confirm_plan`, `gather`, `process`, `stockpile`, `build`, `done`, `failed`, `cancelled` |

### `job.area`

Request body:

| Field | Required | Allowed |
|---|---|---|
| `job` | yes | text, max 24 , form `^[A-Za-z0-9]+$` |
| `limits` | yes | table { chop?, d?, down?, fuelReserve?, keepOut?, machines?, maxMinutes?, me?, mine?, mineMax?, take?, up?, w? } |

Response body:

| Field | Required | Allowed |
|---|---|---|
| `job` | yes | text, max 24 , form `^[A-Za-z0-9]+$` |
| `limits` | yes | table { chop?, d?, down?, fuelReserve?, keepOut?, machines?, maxMinutes?, me?, mine?, mineMax?, take?, up?, w? } |

### `job.cancel`

Request body:

| Field | Required | Allowed |
|---|---|---|
| `job` | yes | text, max 24 , form `^[A-Za-z0-9]+$` |

Response body:

| Field | Required | Allowed |
|---|---|---|
| `job` | yes | text, max 24 , form `^[A-Za-z0-9]+$` |
| `state` | yes | one of: `quoted`, `awaiting_turtle`, `survey`, `plan`, `confirm_plan`, `gather`, `process`, `stockpile`, `build`, `done`, `failed`, `cancelled` |

### `job.confirm`

Request body:

| Field | Required | Allowed |
|---|---|---|
| `job` | yes | text, max 24 , form `^[A-Za-z0-9]+$` |
| `quote` | yes | text, max 24 , form `^[A-Za-z0-9]+$` |

Response body:

| Field | Required | Allowed |
|---|---|---|
| `job` | yes | text, max 24 , form `^[A-Za-z0-9]+$` |
| `state` | yes | one of: `quoted`, `awaiting_turtle`, `survey`, `plan`, `confirm_plan`, `gather`, `process`, `stockpile`, `build`, `done`, `failed`, `cancelled` |

### `job.list`

Request body:

| Field | Required | Allowed |
|---|---|---|
| `page` | yes | integer 0..100 |

Response body:

| Field | Required | Allowed |
|---|---|---|
| `jobs` | yes | list (max 10) of: table { job, name, pct, state } |
| `more` | yes | true/false |

### `job.plan`

Request body:

| Field | Required | Allowed |
|---|---|---|
| `job` | yes | text, max 24 , form `^[A-Za-z0-9]+$` |
| `page` | yes | integer 0..500 |

Response body:

| Field | Required | Allowed |
|---|---|---|
| `job` | yes | text, max 24 , form `^[A-Za-z0-9]+$` |
| `more` | yes | true/false |
| `page` | yes | integer 0..500 |
| `plan` | yes | text, max 24 , form `^[A-Za-z0-9]+$` |
| `steps` | yes | list (max 24) of: table { id, k, n, x?, y?, z? } |

### `job.quote`

Request body:

| Field | Required | Allowed |
|---|---|---|
| `src` | yes | one of: `shape`, `lib`, `import` |
| `ref` | no | text, max 24 , form `^[A-Za-z0-9]+$` |
| `shape` | no | table { block, d, h, kind, w, hollow? } |

Response body:

| Field | Required | Allowed |
|---|---|---|
| `count` | yes | integer 0..10000000 |
| `eta` | yes | integer 0..10000000 |
| `expires` | yes | integer 0..9007199254740992 |
| `hand` | yes | integer 0..10000000 |
| `mats` | yes | list (max 64) of: table { id, n } |
| `queue` | yes | integer 0..10000 |
| `quote` | yes | text, max 24 , form `^[A-Za-z0-9]+$` |
| `raw` | yes | list (max 64) of: table { id, n } |
| `turtles` | yes | integer 1..8 |

### `job.status`

Request body:

| Field | Required | Allowed |
|---|---|---|
| `job` | yes | text, max 24 , form `^[A-Za-z0-9]+$` |

Response body:

| Field | Required | Allowed |
|---|---|---|
| `eta` | yes | integer 0..10000000 |
| `job` | yes | text, max 24 , form `^[A-Za-z0-9]+$` |
| `need` | yes | list (max 32) of: table { id, n } |
| `pct` | yes | integer 0..100 |
| `placed` | yes | integer 0..10000000 |
| `queue` | yes | integer 0..10000 |
| `state` | yes | one of: `quoted`, `awaiting_turtle`, `survey`, `plan`, `confirm_plan`, `gather`, `process`, `stockpile`, `build`, `done`, `failed`, `cancelled` |
| `total` | yes | integer 0..10000000 |

### `lib.get_thumb`

Request body:

| Field | Required | Allowed |
|---|---|---|
| `ref` | yes | text, max 24 , form `^[A-Za-z0-9]+$` |

Response body:

| Field | Required | Allowed |
|---|---|---|
| `data` | yes | bytes, max 1024 |
| `h` | yes | integer 1..32 |
| `ref` | yes | text, max 24 , form `^[A-Za-z0-9]+$` |
| `w` | yes | integer 1..32 |

### `lib.list`

Request body:

| Field | Required | Allowed |
|---|---|---|
| `page` | yes | integer 0..500 |

Response body:

| Field | Required | Allowed |
|---|---|---|
| `items` | yes | list (max 8) of: table { count, d, h, name, ref, tested, w } |
| `more` | yes | true/false |

### `rekey`

Request body:

| Field | Required | Allowed |
|---|---|---|
| `kx` | yes | bytes, max 32 |
| `sign` | yes | bytes, max 32 |

Response body:

_(no fields)_

### `shape.preview`

Request body:

| Field | Required | Allowed |
|---|---|---|
| `shape` | yes | table { block, d, h, kind, w, hollow? } |

Response body:

| Field | Required | Allowed |
|---|---|---|
| `count` | yes | integer 0..10000000 |
| `d` | yes | integer 1..64 |
| `h` | yes | integer 1..64 |
| `mats` | yes | list (max 64) of: table { id, n } |
| `w` | yes | integer 1..64 |

### `upload.begin`

Request body:

| Field | Required | Allowed |
|---|---|---|
| `chunks` | yes | integer 1..1024 |
| `name` | yes | text, max 48 , form `^[A-Za-z0-9_. -]+$` |
| `sha` | yes | 64 hex characters |
| `size` | yes | integer 1..262144 |

Response body:

| Field | Required | Allowed |
|---|---|---|
| `next` | yes | integer 0..1024 |
| `up` | yes | text, max 24 , form `^[A-Za-z0-9]+$` |

### `upload.chunk`

Request body:

| Field | Required | Allowed |
|---|---|---|
| `data` | yes | bytes, max 1024 |
| `seq` | yes | integer 0..1023 |
| `sum` | yes | 16 hex characters |
| `up` | yes | text, max 24 , form `^[A-Za-z0-9]+$` |

Response body:

| Field | Required | Allowed |
|---|---|---|
| `next` | yes | integer 0..1024 |
| `up` | yes | text, max 24 , form `^[A-Za-z0-9]+$` |

### `upload.end`

Request body:

| Field | Required | Allowed |
|---|---|---|
| `up` | yes | text, max 24 , form `^[A-Za-z0-9]+$` |

Response body:

| Field | Required | Allowed |
|---|---|---|
| `ref` | yes | text, max 24 , form `^[A-Za-z0-9]+$` |

### `w.claim`

Request body:

| Field | Required | Allowed |
|---|---|---|
| `fuel` | yes | integer 0..10000000 |
| `slots` | yes | integer 0..16 |

Response body:

| Field | Required | Allowed |
|---|---|---|
| `job` | yes | text, max 24 , form `^[A-Za-z0-9]+$` |
| `limits` | yes | table { chop?, d?, down?, fuelReserve?, keepOut?, machines?, maxMinutes?, me?, mine?, mineMax?, take?, up?, w? } |
| `scan` | yes | integer 1..24 |
| `stage` | yes | one of: `survey`, `gather`, `process`, `stockpile`, `build`, `idle` |

### `w.done`

Request body:

| Field | Required | Allowed |
|---|---|---|
| `job` | yes | text, max 24 , form `^[A-Za-z0-9]+$` |
| `placed` | yes | integer 0..10000000 |

Response body:

_(no fields)_

### `w.fault`

Request body:

| Field | Required | Allowed |
|---|---|---|
| `code` | yes | one of: `blocked`, `lost`, `no_fuel`, `missing`, `full`, `no_tool`, `out_of_area`, `protected` |
| `job` | yes | text, max 24 , form `^[A-Za-z0-9]+$` |
| `x` | yes | integer -64..64 |
| `y` | yes | integer -64..64 |
| `z` | yes | integer -64..64 |
| `id` | no | block/item ID (`namespace:name`) |

Response body:

| Field | Required | Allowed |
|---|---|---|
| `act` | yes | one of: `wait`, `retry`, `abort` |

### `w.inv`

Request body:

| Field | Required | Allowed |
|---|---|---|
| `items` | yes | list (max 128) of: table { id, n } |
| `job` | yes | text, max 24 , form `^[A-Za-z0-9]+$` |
| `kind` | yes | block/item ID (`namespace:name`) |
| `x` | yes | integer -64..64 |
| `y` | yes | integer -64..64 |
| `z` | yes | integer -64..64 |

Response body:

_(no fields)_

### `w.layer`

Request body:

| Field | Required | Allowed |
|---|---|---|
| `job` | yes | text, max 24 , form `^[A-Za-z0-9]+$` |
| `part` | yes | integer 0..255 |
| `y` | yes | integer 0..255 |

Response body:

| Field | Required | Allowed |
|---|---|---|
| `cells` | yes | list (max 1200) of: integer 0..1048575 |
| `more` | yes | true/false |
| `pal` | yes | list (max 128) of: block/item ID (`namespace:name`) |
| `part` | yes | integer 0..255 |
| `y` | yes | integer 0..255 |

### `w.ops`

Request body:

| Field | Required | Allowed |
|---|---|---|
| `after` | yes | integer 0..2147483647 |
| `job` | yes | text, max 24 , form `^[A-Za-z0-9]+$` |

Response body:

| Field | Required | Allowed |
|---|---|---|
| `done` | yes | true/false |
| `limits` | yes | table { chop?, d?, down?, fuelReserve?, keepOut?, machines?, maxMinutes?, me?, mine?, mineMax?, take?, up?, w? } |
| `ops` | yes | list (max 32) of: table { op, seq, grid?, id?, n?, r?, secs?, side?, slot?, tool?, x?, y?, z? } |

### `w.progress`

Request body:

| Field | Required | Allowed |
|---|---|---|
| `fuel` | yes | integer 0..10000000 |
| `job` | yes | text, max 24 , form `^[A-Za-z0-9]+$` |
| `placed` | yes | integer 0..10000000 |
| `stage` | yes | one of: `survey`, `gather`, `process`, `stockpile`, `build`, `idle` |
| `x` | yes | integer -64..64 |
| `y` | yes | integer -64..64 |
| `z` | yes | integer -64..64 |

Response body:

| Field | Required | Allowed |
|---|---|---|
| `stop` | yes | true/false |

### `w.result`

Request body:

| Field | Required | Allowed |
|---|---|---|
| `job` | yes | text, max 24 , form `^[A-Za-z0-9]+$` |
| `ok` | yes | true/false |
| `seq` | yes | integer 1..2147483647 |
| `code` | no | one of: `blocked`, `missing`, `full`, `no_fuel`, `no_tool`, `out_of_area`, `bad_op` |
| `n` | no | integer 0..10000000 |

Response body:

_(no fields)_

### `w.survey`

Request body:

| Field | Required | Allowed |
|---|---|---|
| `job` | yes | text, max 24 , form `^[A-Za-z0-9]+$` |
| `last` | yes | true/false |
| `pal` | yes | list (max 128) of: block/item ID (`namespace:name`) |
| `pts` | yes | list (max 1200) of: integer 0..549552383 |
| `seq` | yes | integer 0..100000 |

Response body:

| Field | Required | Allowed |
|---|---|---|
| `next` | yes | integer 0..100001 |
