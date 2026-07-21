# Mus Online Deployment — Exact Commands

Your VPS IP: **75.119.142.247**

> **This server coexists with the AutoChest autobattler on the same VPS.**
> Mus is fully namespaced away from it — different directory (`/opt/mus-online`
> vs `/opt/autochest`), different port (**12346** vs 12345), different systemd
> unit (`mus-server`), and its own database. **Never** point these commands at
> `/opt/autochest`, reuse port 12345, or touch the AutoChest systemd unit.

Copy and paste these in order. Run the **(Mac)** blocks in a terminal on your
laptop and the **(VPS)** blocks inside the SSH session.

---

## Prerequisites (already satisfied)

Because the VPS already runs AutoChest, it **already has** `love`, `lua5.1`,
`luarocks`, `lsqlite3complete`, `bcrypt`, and `xvfb` installed.

**Do NOT run `deploy/server-setup.sh`** — it does `apt upgrade -y` and
`add-apt-repository`, which is unnecessary and risky on a live production box.
The only case you'd install anything is if Step 2 fails with a missing-module
error; then install just that one rock (see Troubleshooting).

---

## STEP 1: Upload Code to the VPS (Mac)

The server relies on repo-relative paths (`package.path` gets `../?.lua` in
`server/main.lua`), so `server/`, `shared/`, and `lib/` must all sit as siblings
under `/opt/mus-online`. Upload the whole repo, excluding git and any local DB:

```bash
rsync -avz --exclude '.git' --exclude 'server/players.db' \
  ~/mus-online/ root@75.119.142.247:/opt/mus-online/
```

Enter your VPS root password when prompted. Takes ~1-2 minutes.

---

## STEP 2: Install & Start the systemd Unit (VPS)

```bash
ssh root@75.119.142.247

sudo cp /opt/mus-online/deploy/mus-server.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now mus-server
sudo systemctl status mus-server
```

The unit is `mus-server`, `WorkingDirectory=/opt/mus-online`, and runs
`xvfb-run -a love server/` (headless Love2D). It is a **separate** unit from
AutoChest's, so restarting/stopping it never affects the autobattler.

**Look for:** `active (running)` in green.

**If it fails to start:**
```bash
sudo journalctl -u mus-server -n 50 --no-pager
```

---

## STEP 3: Open the Mus Port (VPS)

Add **only** 12346. Leave AutoChest's 12345 rule in place.

```bash
sudo ufw allow 12346/tcp
sudo ufw allow 12346/udp
sudo ufw status          # confirm BOTH 12345 (autochest) and 12346 (mus) appear
```

---

## STEP 4: Verify the Server (Mac + VPS)

**Port reachable (Mac)** — ENet is UDP:
```bash
nc -zvu 75.119.142.247 12346
```

**Watch live logs (VPS)** — keep this open while you test:
```bash
ssh root@75.119.142.247 'journalctl -u mus-server -f'
```

You should see:
```
Database initialized
Mus Online matchmaking server started on port 12346
```

The database is created fresh at `/opt/mus-online/server/players.db` — its own
file, separate from AutoChest's. Press `Ctrl+C` to stop tailing.

---

## STEP 5: Log In / Create an Account (Mac)

`play-online.sh` already sets `MUS_PRODUCTION=true` and
`MUS_SERVER_IP=75.119.142.247`, so it connects straight to production:

```bash
cd ~/mus-online && ./play-online.sh
```

You should reach the **name-entry screen** → register a new account. Watch the
`journalctl -f` from Step 4 to see the register/login messages land server-side.

---

## STEP 6: Test Multiplayer (Mac)

Run the client twice (two terminals), registering **different** usernames, and
have both queue — or use a private room with "start with bots" to fill a table.

```bash
cd ~/mus-online && ./play-online.sh   # terminal 1
cd ~/mus-online && ./play-online.sh   # terminal 2
```

---

## SUCCESS 🎉

Mus Online is live at **75.119.142.247:12346**, running alongside AutoChest on
12345. Anyone can connect with `./play-online.sh` from the repo.

---

## Updating the Server After Code Changes

**Mac** — re-sync (the `--exclude` keeps the live player DB intact):
```bash
rsync -avz --exclude '.git' --exclude 'server/players.db' \
  ~/mus-online/ root@75.119.142.247:/opt/mus-online/
```

**VPS** — restart only the mus unit:
```bash
ssh root@75.119.142.247 'sudo systemctl restart mus-server'
```

---

## Useful Commands (VPS)

```bash
sudo systemctl restart mus-server     # restart
sudo systemctl stop mus-server        # stop
sudo systemctl status mus-server      # status
sudo journalctl -u mus-server -f      # live logs
sudo netstat -tulpn | grep 12346      # confirm it's listening
```

---

## Troubleshooting

**Server won't start / missing module?**
```bash
ssh root@75.119.142.247
sudo journalctl -u mus-server -n 100 --no-pager
```
If it names a missing Lua rock (rare — AutoChest installed the shared set), add
just that one, e.g.:
```bash
sudo luarocks install <rockname>
sudo systemctl restart mus-server
```

**Can't connect from the client?**
```bash
ssh root@75.119.142.247 'sudo netstat -tulpn | grep 12346'   # should show LISTEN
ssh root@75.119.142.247 'sudo ufw status'                     # 12346 tcp+udp present?
```

**Did I break AutoChest?** You shouldn't have — nothing above touches it. Sanity check:
```bash
ssh root@75.119.142.247 'sudo systemctl status <autochest-unit> && sudo ufw status | grep 12345'
```

---

## Setup Database Backups (Optional)

```bash
ssh root@75.119.142.247
chmod +x /opt/mus-online/deploy/backup-db.sh
/opt/mus-online/deploy/backup-db.sh          # test once

sudo crontab -e
# add:
0 */6 * * * /opt/mus-online/deploy/backup-db.sh
```

---

## Need Help?

If you get stuck, note: (1) which step, (2) the exact error, (3) the last ~20
lines of `journalctl -u mus-server`.
