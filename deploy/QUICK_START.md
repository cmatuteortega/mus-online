# Mus Online Cloud Deployment - Quick Start

## What You Need

1. **Your VPS IP Address**: `_________________` (fill this in)
2. **SSH Username**: Usually `root` or `ubuntu`

---

## Part 1: Commands on Your Local Machine (Mac Terminal)

### 1. Upload Code to VPS

```bash
cd /Users/cmatute1/auto-chest/auto-chest

# Replace YOUR_SERVER_IP with your actual IP
scp -r . root@YOUR_SERVER_IP:/opt/mus-online/
```

When prompted, enter your VPS password.

---

## Part 2: Commands on Your VPS (SSH Session)

### 2. Connect to VPS

```bash
# Replace YOUR_SERVER_IP with your actual IP
ssh root@YOUR_SERVER_IP
```

### 3. Run Setup Script

```bash
cd /opt/mus-online
chmod +x deploy/server-setup.sh
./deploy/server-setup.sh
```

Wait for it to complete (2-5 minutes).

### 4. Configure Firewall

```bash
sudo ufw allow 22/tcp
sudo ufw allow 12346/tcp
sudo ufw allow 12346/udp
sudo ufw --force enable
```

### 5. Start Server

```bash
sudo cp /opt/mus-online/deploy/mus-server.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable mus-server
sudo systemctl start mus-server
```

### 6. Verify Server is Running

```bash
sudo systemctl status mus-server
```

Look for **"active (running)"** in green.

### 7. View Logs (Optional)

```bash
sudo journalctl -u mus-server -f
```

Press `Ctrl+C` to exit.

---

## Part 3: Test Connection from Your Mac

### 8. Test Port Connection

```bash
# Replace YOUR_SERVER_IP
nc -zv YOUR_SERVER_IP 12346
```

Should show "succeeded".

### 9. Run Game with Production Server

```bash
cd /Users/cmatute1/auto-chest/auto-chest

# Replace YOUR_SERVER_IP
export AUTOCHEST_PRODUCTION=true
export AUTOCHEST_SERVER_IP=YOUR_SERVER_IP
love .
```

### 10. Test Multiplayer

- Run the game on two different computers
- Both should connect to `YOUR_SERVER_IP`
- Register/login with different usernames
- Both click "PLAY ONLINE"
- They should match and start a game!

---

## Quick Reference

| Task | Command |
|------|---------|
| Restart server | `sudo systemctl restart mus-server` |
| View logs | `sudo journalctl -u mus-server -f` |
| Stop server | `sudo systemctl stop mus-server` |
| Check status | `sudo systemctl status mus-server` |
| Update code | Upload with scp, then restart |

---

## Troubleshooting

**Can't connect to VPS?**
```bash
# Check if SSH port is open
nc -zv YOUR_SERVER_IP 22
```

**Server won't start?**
```bash
# Check error logs
sudo journalctl -u mus-server -n 50 --no-pager
```

**Firewall blocking?**
```bash
# Check firewall status
sudo ufw status verbose
```

---

## Success Checklist

- [ ] Code uploaded to `/opt/mus-online/`
- [ ] Setup script completed without errors
- [ ] Firewall allows port 12346
- [ ] Server status shows "active (running)"
- [ ] Port 12346 responds to nc test
- [ ] Game client can connect and see login screen
- [ ] Two clients can match and play

---

**Still stuck?** Check the full guide: `deploy/DEPLOYMENT_GUIDE.md`
