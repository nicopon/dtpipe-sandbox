FROM python:3.12-slim

RUN apt-get update && apt-get install -y \
    libpq-dev \
    gcc \
    git \
    time \
    unixodbc \
    && rm -rf /var/lib/apt/lists/*

# gcc + libpq-dev: Singer plugins compile psycopg2 from source; unixodbc: tap-mssql runtime dep (libodbc.so.2)
RUN pip install --no-cache-dir meltano duckdb

WORKDIR /bench
CMD ["bash", "-c", "while true; do sleep 3600; done"]
