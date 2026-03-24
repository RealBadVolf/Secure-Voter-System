FROM mariadb:11.4

# Harden: remove test database, set character set
RUN echo "[mysqld]\n\
character-set-server=utf8mb4\n\
collation-server=utf8mb4_unicode_ci\n\
innodb_file_per_table=1\n\
innodb_flush_log_at_trx_commit=1\n\
max_connections=100\n\
log_error=/var/log/mysql/error.log\n\
general_log=0\n\
slow_query_log=1\n\
slow_query_log_file=/var/log/mysql/slow.log\n\
long_query_time=2\n\
" > /etc/mysql/conf.d/securevote.cnf

RUN mkdir -p /var/log/mysql && chown mysql:mysql /var/log/mysql

EXPOSE 3306
