FROM python:3.12-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    mariadb-client fonts-dejavu-core && \
    rm -rf /var/lib/apt/lists/* && \
    pip install --no-cache-dir Pillow qrcode

RUN adduser --disabled-password --uid 1000 svadmin
COPY admin_portal.py /app/admin_portal.py

USER svadmin
WORKDIR /app
EXPOSE 8090
CMD ["python3", "admin_portal.py"]
