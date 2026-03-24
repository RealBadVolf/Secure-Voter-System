FROM mariadb:11.4

COPY securevote.cnf /etc/mysql/conf.d/securevote.cnf
RUN mkdir -p /var/log/mysql && chown mysql:mysql /var/log/mysql

EXPOSE 3306
