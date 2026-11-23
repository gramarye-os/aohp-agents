# A local model in an env

An env can have a language model that runs on the phone itself. The AOHP Driver ships the server
(llama.cpp's `llama-server`) and runs it on the Android side as the unit `llama-server.service` of
the env, on the NPU where the phone has one the Driver supports, otherwise on the CPU. It answers
on `http://127.0.0.1:8082/v1` (OpenAI-style API). `aohp-llm` does the rest.

## Quick start

```
aohp-llm setup          # fetch a model, start the server, add it to the OpenClaw gateway
aohp-llm status
```

`setup` picks `qwen3.5-4b` on a phone with 11 GB of memory or more and `qwen3.5-2b` below that;
name one to choose yourself (`aohp-llm models` lists them). Options: `--device auto|htp|cpu`,
`--ctx N` (context window), `--threads N` (CPU threads).

## What `setup` does

1. **Fetch**: downloads the model file to `/opt/llm/models` (1 to 3 GB, resumable, checked against
   its sha256). The list of models and where they come from is `install/llm-models.tsv`.
2. **Use**: asks the Driver to write and start `llama-server.service` for that file. The unit is
   enabled, so it starts with the env.
3. **OpenClaw**: adds the provider `local` with that one model to the gateway config and restarts
   the gateway. The model is then `local/<name>`, for example `local/qwen3.5-4b`. The default model
   of the gateway is not changed.
4. **Note**: writes the choice to `~/.openclaw/aohp/llm`.

Each step can be run alone: `aohp-llm fetch`, `use`, `openclaw` (`openclaw --disable` takes the
provider out again). Running `setup` again changes nothing when everything is already in place.

## After a wipe

`aohp-update` runs `aohp-llm apply`: when `~/.openclaw/aohp/llm` exists, it puts back whatever is
missing (the file, the unit, the provider). A fresh env gets that file with the rest of its config
when the config repo carries it; without the file nothing is fetched.

## Good to know

- A small model has a small context window (16k tokens for `qwen3.5-4b` as set up here). The full
  prompt of the main agent does not fit; use the local model for an agent with a short prompt and
  few skills.
- One model at a time: `aohp-llm use <other>` restarts the server with the other file.
- The server's log: `journalctl -u llama-server`.
