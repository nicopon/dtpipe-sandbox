FROM python:3.12-slim

RUN apt-get update && apt-get install -y \
    time \
    && rm -rf /var/lib/apt/lists/*

# psycopg2-binary, pymssql, oracledb ship pre-compiled wheels — no gcc/libpq needed
RUN pip install --no-cache-dir pyarrow pandas psycopg2-binary pyodbc oracledb sqlalchemy pymssql duckdb

WORKDIR /bench
CMD ["bash", "-c", "while true; do sleep 3600; done"]
