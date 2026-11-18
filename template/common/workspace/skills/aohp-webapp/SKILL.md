---
name: aohp-webapp
description: Put a web app you built in this env on the phone's home screen - "install it", "make it an app", "add it to the home screen". Covers apps made only of files (no network) and apps with their own server in the env.
metadata: {"openclaw":{"requires":{"bins":["aohp-webapp"]},"os":["linux"]}}
---

# Web apps on the home screen

You cannot install an APK from this env. What you can do is put a web app on the phone's home
screen: the user gets an icon, and tapping it opens the app full screen in a window of its own,
with its own entry in recents. Use `aohp-webapp`.

The user is asked once by the phone to add the icon. Tell them to expect that question.

## Pick the kind of app

**Files only (`--dir`).** A folder with `index.html` and whatever it loads. Use this for a game, a
calculator, a note pad: anything that needs no server.

- Do not start a web server. The phone reads the files straight from the folder.
- The app has **no network at all**: no fetch to the internet, no CDN, no WebSocket. Put every
  script, font and image in the folder and load them with relative paths.
- `localStorage` and IndexedDB work and belong to this app alone.
- Keep the folder where it is. The app is read from it every time it opens, so an edit shows up at
  the next start, and deleting the folder breaks the app.

```bash
aohp-webapp pin --dir /root/.openclaw/workspace/mygame/app
```

The name and colour come from `manifest.json` in the folder (`name` or `short_name`,
`theme_color`) unless you pass `--name` / `--color '#rrggbb'`. A game usually wants `--immersive`
(hides the status and navigation bars).

**With its own server (`--url`).** Use this when the app has a backend: a database, Redis,
multiplayer, an API.

- Bind the server to `127.0.0.1`, never `0.0.0.0`: on `0.0.0.0` everyone on the Wi-Fi can reach it.
- Run it as a unit, so it comes back after a reboot. A server started from your shell dies with it.

```bash
cat > /etc/aohp/system/mygame.service <<'EOF'
[Unit]
Description=My game server

[Service]
WorkingDirectory=/root/.openclaw/workspace/mygame
ExecStart=/usr/bin/node server.js --host 127.0.0.1 --port 8080
Restart=on-failure

[Install]
WantedBy=aohp.target
EOF
systemctl daemon-reload && systemctl enable --now mygame.service
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:8080/      # must answer before you pin

aohp-webapp pin --name "My Game" --url http://127.0.0.1:8080/ --unit mygame.service
```

With `--unit` the phone starts that unit, if it is stopped, before it opens the app.

## Other options

- `--icon /path/in/env/icon.png`: PNG, JPEG or WebP, at most 1 MB. Without it the icon is a coloured
  tile with the app's first letter.
- `--id my-game`: the app's id (lower-case letters, digits, `-`). The default is made from the name.
  Pinning the same id again updates the app.
- `--no-pin`: register without asking for an icon; open it with `aohp-webapp open <id>`.

## Manage

```bash
aohp-webapp list
aohp-webapp open <id>       # open it now
aohp-webapp remove <id>     # the icon stays, disabled, until the user drags it away
```

## If it fails

- "this phone's Driver has no web apps yet": the AOHP Driver app is older than v0.9.0-cred.23. Say
  so; the fallback is a server on 127.0.0.1 and a browser bookmark.
- A `--dir` app shows a blank page: it loads something from the network or by an absolute `http`
  address. Make it relative and local.
