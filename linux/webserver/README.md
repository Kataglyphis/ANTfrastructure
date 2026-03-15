```bash
sudo nerdctl build -t kataglyphis-webserver:latest -f linux/webserver/Dockerfile .
```
```bash
sudo nerdctl run -d --name mysite -p 8443:8443 -p 8080:80 kataglyphis-webserver:latest
```
# open http://localhost:8080

=======
# Build

```bash
sudo nerdctl build -t kataglyphis-webserver:latest -f linux/webserver/Dockerfile .
```

# Run mit Volume-Mount für dist UND nginx.conf
```bash
sudo nerdctl run -d --name kataglyphis-webserver \
  -p 8080:80 \
  -p 8443:8443 \
  -v "$(pwd)/linux/webserver/dist:/var/www/html" \
  -v "$(pwd)/linux/webserver/nginx.conf:/etc/nginx/nginx.conf:ro" \
  kataglyphis-webserver:latest
```

```bash
docker exec kataglyphis-webserver nginx -t
docker exec kataglyphis-webserver nginx -s reload
```

Reload browser with cache: F5 !!

---

# Troubleshooting

## Container not reachable from other devices on the network

**Symptom:** Nginx is running and reachable locally (localhost), but other devices on the same network cannot access it.

**Cause:** UFW (Uncomplicated Firewall) has `DEFAULT_FORWARD_POLICY="DROP"` which blocks forwarded traffic to containers.

**Diagnosis:**
```bash
# Check if packets are being dropped in FORWARD chain
sudo iptables -L FORWARD -n -v | head -5
# Look for "policy DROP" and non-zero packet count

# Check current UFW forward policy
grep "DEFAULT_FORWARD_POLICY" /etc/default/ufw
```

**Fix:**
```bash
# Change forward policy to ACCEPT and reload UFW
sudo sed -i 's/DEFAULT_FORWARD_POLICY="DROP"/DEFAULT_FORWARD_POLICY="ACCEPT"/' /etc/default/ufw
sudo ufw reload
```

After this, the container should be accessible from other devices using the host's IP address (e.g., `http://192.168.x.x`).
