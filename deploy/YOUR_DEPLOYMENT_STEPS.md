# Your Mus Online Deployment - Exact Commands

Your VPS IP: **75.119.142.247**

Copy and paste these commands in order!

---

## STEP 1: Upload Code to VPS (Run on Your Mac)

Open a new Terminal window (not Claude Code) and run:

```bash
cd /Users/cmatute1/auto-chest/auto-chest
scp -r . root@75.119.142.247:/opt/mus-online/
```

When prompted for password, enter your VPS root password.

**This will take 1-2 minutes to upload.**

---

## STEP 2: Connect to Your VPS

```bash
ssh root@75.119.142.247
```

Enter your VPS password when prompted.

You're now inside your VPS!

---

## STEP 3: Run Setup Script

```bash
cd /opt/mus-online
chmod +x deploy/server-setup.sh
./deploy/server-setup.sh
```

**This will take 2-5 minutes.** It will:
- Update Ubuntu
- Install Love2D
- Install Lua dependencies
- Create directories

---

## STEP 4: Configure Firewall

```bash
sudo ufw allow 22/tcp
sudo ufw allow 12346/tcp
sudo ufw allow 12346/udp
sudo ufw --force enable
```

**Important:** This allows your game server port and protects SSH.

---

## STEP 5: Install and Start Server

```bash
sudo cp /opt/mus-online/deploy/mus-server.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable mus-server
sudo systemctl start mus-server
```

---

## STEP 6: Check Server Status

```bash
sudo systemctl status mus-server
```

**Look for:**
- "active (running)" in **green**
- "Mus Online matchmaking server started on port 12346"

**If you see errors**, run:
```bash
sudo journalctl -u mus-server -n 50 --no-pager
```

Press `q` to exit.

---

## STEP 7: View Live Logs (Optional)

```bash
sudo journalctl -u mus-server -f
```

You should see:
```
Database initialized
Mus Online matchmaking server started on port 12346
```

Press `Ctrl+C` to exit log view.

---

## STEP 8: Test Port is Open (Run on Your Mac)

Open a **new Terminal window** on your Mac (keep VPS SSH open):

```bash
nc -zv 75.119.142.247 12346
```

**Expected output:**
```
Connection to 75.119.142.247 port 12346 [tcp/*] succeeded!
```

**If it fails:**
- Check firewall on VPS: `sudo ufw status`
- Check server is running: `sudo systemctl status mus-server`

---

## STEP 9: Connect Game Client to Production

On your Mac:

```bash
cd /Users/cmatute1/auto-chest/auto-chest
export AUTOCHEST_PRODUCTION=true
export AUTOCHEST_SERVER_IP=75.119.142.247
love .
```

**You should see the login screen!**

Try to:
1. Register a new account
2. Login
3. Click "PLAY ONLINE"

---

## STEP 10: Test Multiplayer

Run the game on **two different computers** (or run twice on your Mac):

**Terminal 1:**
```bash
cd /Users/cmatute1/auto-chest/auto-chest
export AUTOCHEST_PRODUCTION=true
love .
```

**Terminal 2 (same commands):**
```bash
cd /Users/cmatute1/auto-chest/auto-chest
export AUTOCHEST_PRODUCTION=true
love .
```

- Register/login with **different usernames**
- Both click "PLAY ONLINE"
- They should match and start a game!

---

## SUCCESS! 🎉

Your server is now live at: **75.119.142.247:12346**

Anyone can connect by:
1. Setting `export AUTOCHEST_PRODUCTION=true`
2. Running `love .` from your game directory

---

## Useful Commands (Run on VPS)

```bash
# Restart server
sudo systemctl restart mus-server

# Stop server
sudo systemctl stop mus-server

# View logs
sudo journalctl -u mus-server -f

# Check status
sudo systemctl status mus-server

# View matchmaking log file
tail -f /opt/mus-online/server/matchmaking.log
```

---

## Updating Server After Code Changes

When you make changes to your code:

**On your Mac:**
```bash
cd /Users/cmatute1/auto-chest/auto-chest
rsync -avz --exclude 'server/players.db' . root@75.119.142.247:/opt/mus-online/
```

**On VPS:**
```bash
ssh root@75.119.142.247
sudo systemctl restart mus-server
```

---

## Troubleshooting

**Can't upload code?**
```bash
# Check SSH connection
ssh root@75.119.142.247
# If this fails, check your VPS is running
```

**Server won't start?**
```bash
ssh root@75.119.142.247
sudo journalctl -u mus-server -n 100 --no-pager
# Look for error messages
```

**Can't connect from game?**
```bash
# Test port on VPS
ssh root@75.119.142.247
sudo netstat -tulpn | grep 12346
# Should show LISTEN on port 12346
```

---

## Setup Database Backups (Optional)

```bash
ssh root@75.119.142.247
chmod +x /opt/mus-online/deploy/backup-db.sh

# Test backup
/opt/mus-online/deploy/backup-db.sh

# Schedule automatic backups every 6 hours
sudo crontab -e
# Add this line:
0 */6 * * * /opt/mus-online/deploy/backup-db.sh
```

---

## Need Help?

If you get stuck at any step, tell me:
1. Which step number you're on
2. The exact error message
3. I'll help you fix it!
