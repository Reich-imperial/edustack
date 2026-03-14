# EduStack — Nginx Reverse Proxy Image
FROM nginx:1.25-alpine
LABEL project="EduStack"
LABEL author="Samson Olanipekun"
LABEL github="github.com/Reich-imperial/edustack"

RUN rm -f /etc/nginx/conf.d/default.conf
COPY edustack.conf /etc/nginx/conf.d/edustack.conf

EXPOSE 80
