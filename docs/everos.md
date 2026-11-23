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

A host that reaches both sides carries it: `install/everos/sender/ship-index.sh [phone...]`.
It needs the writing host to provide an index snapshot (a copy of the store's `.index` with
`STORE_COMMIT` and `SHA256SUMS`), and a local clone of the store. For each phone it

- pushes the store commit into `/root/everos/root` as branch `shipped`,
- copies the index to `/root/everos/index-next` (only files the phone does not have yet),
- runs `/root/everos/apply-index.sh` there: check the checksums, move the store to that commit,
  swap the index, restart EverOS (down a few seconds), and go back to the previous index if the
  server does not come up.

The phone holds no key for the writing host. A phone that is off gets the store on a later run.

## Using it

- `curl http://127.0.0.1:8014/health`
- The `everos-recall` skill searches the local copy first and the writing host second.
- The embedding server speaks the OpenAI `/v1/embeddings` API, so the gateway's memory search can use
  it too (`memory.search.remote.baseUrl: http://127.0.0.1:8025/v1`, model `Qwen/Qwen3-Embedding-0.6B`).
- `/root/everos/apply.log` has one line per delivery; `/root/everos/INDEX_STORE_COMMIT` the commit.
