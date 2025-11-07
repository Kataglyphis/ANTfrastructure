```bash
docker build -t mysite:latest -f linux/webserver/Dockerfile .
```
docker run -d --name mysite -p 8080:80 mysite-ubuntu:latest
# open http://localhost:8080
