# Mus Online Cloud Deployment Guide

## Prerequisites

- Ubuntu VPS (20.04 or 22.04)
- SSH access to the server
- Your VPS IP address

---

## Step 1: Connect to Your VPS

On your local terminal (outside Claude Code):

```bash
ssh root@YOUR_SERVER_IP
# Or if using a different user:
ssh ubuntu@YOUR_SERVER_IP
```

---

## Step 2: Run Server Setup Script

On your VPS, run these commands:

```bash
# Create temporary directory
mkdir -p /tmp/mus-online-setup
cd /tmp/mus-online-setup

# Download or paste the setup script
# (We'll upload it in the next step)
```

---

## Step 3: Upload Code to VPS

**Back on your local machine** (in your project directory):

```bash
# Option A: Using SCP (simple file transfer)
cd /Users/cmatute1/auto-chest/auto-chest
scp -r . root@YOUR_SERVER_IP:/opt/mus-online/

# Option B: Using rsync (better for updates)
rsync -avz --exclude 'server/players.db' \
  /Users/cmatute1/auto-chest/auto-chest/ \
  root@YOUR_SERVER_IP:/opt/mus-online/
```

Replace `YOUR_SERVER_IP` with your actual IP address.

---

## Step 4: Install Dependencies on VPS

**Back on your VPS SSH session:**

```bash
cd /opt/mus-online
chmod +x deploy/server-setup.sh
./deploy/server-setup.sh
```

This will:
- Update system packages
- Install Love2D and Lua
- Install lsqlite3complete and bcrypt
- Create necessary directories

---

## Step 5: Configure Firewall

```bash
# Allow SSH (important!)
sudo ufw allow 22/tcp

# Allow game server port
sudo ufw allow 12346/tcp
sudo ufw allow 12346/udp

# Enable firewall
sudo ufw enable
```

---

## Step 6: Install and Start Service

```bash
# Copy service file
sudo cp /opt/mus-online/deploy/mus-server.service /etc/systemd/system/

# Reload systemd
sudo systemctl daemon-reload

# Enable service (start on boot)
sudo systemctl enable mus-server

# Start service
sudo systemctl start mus-server

# Check status
sudo systemctl status mus-server
```

You should see **"active (running)"** in green.

---

## Step 7: Verify Server is Running

```bash
# Check server logs
sudo journalctl -u mus-server -f

# You should see:
# "Database initialized"
# "Mus Online matchmaking server started on port 12346"
```

Press `Ctrl+C` to exit log viewing.

---

## Step 8: Test Connection from Local Machine

On your local machine, test the connection:

```bash
# Test if port is open (on Mac/Linux)
nc -zv 75.119.142.247 12346

# On Windows (PowerShell)
Test-NetConnection -ComputerName YOUR_SERVER_IP -Port 12346
```

You should see "succeeded" or "Connection successful".

---

## Step 9: Configure Client to Use Production Server

**Option A: Environment Variables (Recommended)**

On your local machine, before running the game:

```bash
export AUTOCHEST_PRODUCTION=true
export AUTOCHEST_SERVER_IP=YOUR_SERVER_IP
love .
```

**Option B: Edit config.lua**

Edit `src/config.lua` and replace `YOUR_SERVER_IP_HERE` with your actual IP:

```lua
config.SERVER_ADDRESS = "75.119.142.247"  -- Your actual IP
```

---

## Step 10: Set Up Automatic Backups

On your VPS:

```bash
# Make backup script executable
chmod +x /opt/mus-online/deploy/backup-db.sh

# Test backup
/opt/mus-online/deploy/backup-db.sh

# Add to crontab (runs every 6 hours)
sudo crontab -e

# Add this line:
0 */6 * * * /opt/mus-online/deploy/backup-db.sh
```

---

## Common Server Management Commands

```bash
# View real-time logs
sudo journalctl -u mus-server -f

# Restart server
sudo systemctl restart mus-server

# Stop server
sudo systemctl stop mus-server

# Start server
sudo systemctl start mus-server

# Check server status
sudo systemctl status mus-server

# View matchmaking log file
tail -f /opt/mus-online/server/matchmaking.log
```

---

## Updating Server Code

When you make code changes:

```bash
# On your local machine
cd /Users/cmatute1/auto-chest/auto-chest
rsync -avz --exclude 'server/players.db' . root@75.119.142.247:/opt/mus-online/

# On VPS
ssh root@YOUR_SERVER_IP
sudo systemctl restart mus-server
```

---

## Troubleshooting

### Server won't start

```bash
# Check logs for errors
sudo journalctl -u mus-server -n 50

# Check if port is already in use
sudo netstat -tulpn | grep 12346
```

### Can't connect from client

```bash
# Check firewall
sudo ufw status

# Check if server is listening
sudo netstat -tulpn | grep 12346

# Test from VPS itself
nc -zv 127.0.0.1 12346
```

### Database errors

```bash
# Check database permissions
ls -la /opt/mus-online/server/players.db

# Reset database (WARNING: deletes all data)
rm /opt/mus-online/server/players.db
sudo systemctl restart mus-server
```

---

## Cost Optimization

Your server should handle 50-100 concurrent players on a $5/month VPS.

**Current specs:**
- 1 CPU core
- 1GB RAM
- 25GB storage

If you need to scale up, upgrade to:
- 2 CPU cores
- 2GB RAM
- $10-12/month

---

## Security Recommendations

1. **Change default SSH port** (optional but recommended)
2. **Set up fail2ban** to prevent brute force attacks
3. **Keep system updated**: `sudo apt update && sudo apt upgrade`
4. **Use SSH keys instead of passwords**
5. **Regular database backups** (already configured)

---

## Success Indicators

✅ Server status shows "active (running)"
✅ Logs show "Mus Online matchmaking server started on port 12346"
✅ Firewall allows port 12346
✅ Client can connect and see login screen
✅ Two clients can match and play together

---

Need help? Check the logs first:
```bash
sudo journalctl -u mus-server -n 100
```
