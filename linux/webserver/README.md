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
