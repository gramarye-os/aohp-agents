# EverOS on a phone

[EverOS](https://github.com/EverMind-AI/EverOS) keeps a memory store: Markdown write-ups of past
conversations with a search index beside them. One host writes the store (it runs the model that
writes the episodes). A phone can carry a **read-only copy** and search it locally, without the
network and faster than asking the writing host.

## What runs on the phone

| unit | what it is |
|---|---|
| `everos-embed.service` | The embedding server, Qwen3-Embedding-0.6B on the CPU, `127.0.0.1:8025`. A second instance of the Driver's own `llama-server` (the helper `llama-run.sh` finds where the Driver staged it), so the local model must be set up first: [llm.md](llm.md). |
| `everos.service` | EverOS itself, `127.0.0.1:8014`, on the store in `/root/everos/root`. |

The phone never builds the index. Embedding a whole store keeps four cores busy for hours and
heated a phone until it switched its external display off. `/root/everos/phone.env` therefore sets
`EVEROS_CASCADE__ENABLED=false`: the server only searches the index it is given. Both hosts must use
the same embedding model for that; `install/everos.pin` names it, and the EverOS commit.

## Setting it up

1. `aohp-llm setup` (once; it stages the Driver's `llama-server`).
2. Create `~/.openclaw/aohp/everos` (any content) and run `aohp-update`. With the file in the config
   repo, a fresh env gets all of this again by itself.
3. Deliver the store from the sending host (below). Until then `everos.service` does not start.

`install/everos.sh` installs the EverOS code and its Python environment, the embedding model, the two
units and the scripts. It fetches nothing from the writing host.

## How the store gets to the phone

The writing host sends it. The files are in `install/everos/sender/`:

| file | what it does |
|---|---|
| `snapshot-index.sh` | Copies the store's `.index` to `index-snapshot`, with `STORE_COMMIT` and `SHA256SUMS`. Run after each commit of the store. |
| `ship-index.sh [phone...]` | Delivers that snapshot and its store commit to each phone. |
| `ship.conf.example` | The settings of `ship-index.sh`; copy it to `ship.conf` beside the script. |
| `everos-ship.service`, `everos-ship.timer` | User units: run the delivery now, and every hour for a phone that was off. |

For each phone `ship-index.sh`

- pushes the store commit into `/root/everos/root` as branch `shipped`,
- copies the index to `/root/everos/index-next` (only files the phone does not have yet),
- runs `/root/everos/apply-index.sh` there: check the checksums, move the store to that commit,
  swap the index, restart EverOS (down a few seconds), and go back to the previous index if the
  server does not come up.

A phone that already has the commit is skipped, so an hourly run costs one login. The phone holds
no key for the writing host.

To set it up on the writing host: copy the two scripts and `ship.conf` to `~/everos`, the units to
`~/.config/systemd/user`, give each phone an ssh name in `~/.ssh/config` (its address, port 2222,
user root) and its host key in `~/.ssh/known_hosts`, then `systemctl --user enable --now
everos-ship.timer`. A phone that was wiped has new host keys; replace its `known_hosts` lines.

**The key.** `EVEROS_SHIP_KEY` in `ship.conf` names the private key the phones accept, and the job
uses that key only. A login key works. To harden it: make a key for this job alone, allow it in the
env's `/root/.ssh/authorized_keys` with a `restrict,command=...` line that permits only the
delivery, and name the new file in `ship.conf`.

A host other than the writing one can deliver too, if it reaches both sides: set `EVEROS_SERVER` to
the writing host's ssh name and `EVEROS_STORE` to a local clone of the store.

## A laptop or another Linux host as a target

The installer covers phone envs only. Another host can still take deliveries if it keeps the same
layout in one folder, for example `~/everos`:

- `EverOS/` (the pinned commit with its `.venv`), `root/` (the store repo) and `phone.env`,
- `apply-index.sh` and `align-mtimes.py` from `install/everos/`,
- a unit named `everos` that reads `phone.env` (a user unit when the login is not root), and an
  embedding server on the port `everos.toml` names.

On the writing host, name the target with its folder: `EVEROS_PHONES="oneplus13-wg frame-wg:everos"`.
A folder without a leading `/` is under the login's home.

## Starting without the network

EverOS loads a token-counting encoding (tiktoken `o200k_base`) at every start. By default it
downloads the file into `/tmp`, and it does not start when the file is gone and the download fails.
The installer keeps a copy in `/root/everos/tiktoken-cache` and sets `TIKTOKEN_CACHE_DIR` in
`phone.env`. On a host set up by hand, do the same; `everos.pin` has the URL, the file name and the
checksum.

## Using it

- `curl http://127.0.0.1:8014/health`
- The `everos-recall` skill searches the local copy first and the writing host second.
- The embedding server speaks the OpenAI `/v1/embeddings` API, so the gateway's memory search can use
  it too (`memory.search.remote.baseUrl: http://127.0.0.1:8025/v1`, model `Qwen/Qwen3-Embedding-0.6B`).
- `/root/everos/apply.log` has one line per delivery; `/root/everos/INDEX_STORE_COMMIT` the commit.
