FROM python:3.12-slim

RUN apt-get update && apt-get install -y \
    time \
    && rm -rf /var/lib/apt/lists/*

RUN pip install --no-cache-dir ingestr duckdb

WORKDIR /bench
CMD ["bash", "-c", "while true; do sleep 3600; done"]
