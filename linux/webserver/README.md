```bash
sudo nerdctl build -t mysite:latest -f linux/webserver/Dockerfile .
```
sudo nerdctl run -d --net=host --name mysite -p 8080:80 mysite:latest
# open http://localhost:8080

=======
# Build

sudo nerdctl build -t kataglyphis-webserver:latest -f linux/webserver/Dockerfile .

# Run mit Volume-Mount für dist UND nginx.conf

sudo nerdctl run -d --name kataglyphis-webserver \
  -p 8080:80 \
  -v "$(pwd)/linux/webserver/dist:/var/www/html" \
  -v "$(pwd)/linux/webserver/nginx.conf:/etc/nginx/nginx.conf:ro" \
  kataglyphis-webserver:latest
