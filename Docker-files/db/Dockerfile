# EduStack — MySQL Database Image
FROM mysql:8.0
LABEL project="EduStack"
LABEL author="Samson Olanipekun"
LABEL github="github.com/Reich-imperial/edustack"

ENV MYSQL_ROOT_PASSWORD=eduAdmin@2026
ENV MYSQL_DATABASE=edustack

# Copy schema + seed data — auto-executed on first container start
COPY ../../src/main/resources/db_setup.sql /docker-entrypoint-initdb.d/01_db_setup.sql

EXPOSE 3306
