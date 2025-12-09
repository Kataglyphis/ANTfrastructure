```bash
sudo nerdctl build -t mysite:latest -f linux/webserver/Dockerfile .
```
sudo nerdctl run -d --net=host --name mysite -p 8080:80 mysite:latest
# open http://localhost:8080

