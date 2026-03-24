FROM nginx:1.26-alpine

RUN apk add --no-cache openssl

# Generate self-signed cert for development
RUN mkdir -p /etc/nginx/certs && \
    openssl req -x509 -nodes -days 365 \
    -subj "/C=US/ST=FL/O=SecureVote/CN=securevote.local" \
    -newkey rsa:2048 \
    -keyout /etc/nginx/certs/dev.key \
    -out /etc/nginx/certs/dev.crt

COPY nginx.conf /etc/nginx/nginx.conf
COPY default.conf /etc/nginx/conf.d/default.conf

EXPOSE 80 443
