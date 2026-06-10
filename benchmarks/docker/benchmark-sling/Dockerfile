FROM python:3.12-slim

RUN apt-get update && apt-get install -y \
    time \
    && rm -rf /var/lib/apt/lists/*

# sling uses its own built-in Go drivers — pyodbc/oracledb/psycopg2 not needed
RUN pip install --no-cache-dir sling pyarrow duckdb

WORKDIR /bench
CMD ["bash", "-c", "while true; do sleep 3600; done"]
