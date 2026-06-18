import sys
import os
import pandas as pd
from sqlalchemy import create_engine, Numeric

def main():
    if len(sys.argv) < 2:
        print("Usage: _pandas_bench.py <bench_id> [rows]")
        sys.exit(1)

    bench_id = sys.argv[1]
    rows = sys.argv[2] if len(sys.argv) > 2 else "2000000"

    # Resolve suffix (e.g. 2m or 5m)
    if rows == "5000000":
        suffix = "5m"
    elif rows == "2000000":
        suffix = "2m"
    else:
        try:
            val = int(rows)
            if val % 1000000 == 0:
                suffix = f"{val // 1000000}m"
            else:
                suffix = str(val)
        except ValueError:
            suffix = rows

    # Database connection strings (defaults matching benchmark.env)
    pg_conn = "postgresql+psycopg2://postgres:password@dtpipe-integ-postgres:5432/integration"
    mssql_conn = "mssql+pymssql://sa:Password123!@dtpipe-integ-mssql:1433/master"
    oracle_conn = "oracle+oracledb://testuser:password@dtpipe-integ-oracle:1521/?service_name=FREEPDB1"

    # Intra-DB accounts (B13-B15)
    pg_reader_conn = f"postgresql+psycopg2://{os.environ.get('DB_POSTGRES_READER_USER','bench_reader')}:{os.environ.get('DB_POSTGRES_READER_PASSWORD','password')}@{os.environ.get('DB_POSTGRES_HOST','dtpipe-integ-postgres')}:{os.environ.get('DB_POSTGRES_PORT','5432')}/{os.environ.get('DB_POSTGRES_DB','integration')}"
    pg_writer_conn = f"postgresql+psycopg2://{os.environ.get('DB_POSTGRES_WRITER_USER','bench_writer')}:{os.environ.get('DB_POSTGRES_WRITER_PASSWORD','password')}@{os.environ.get('DB_POSTGRES_HOST','dtpipe-integ-postgres')}:{os.environ.get('DB_POSTGRES_PORT','5432')}/{os.environ.get('DB_POSTGRES_DB','integration')}"
    pg_writer_schema = os.environ.get('DB_POSTGRES_WRITER_SCHEMA', 'bench_tgt')
    mssql_reader_conn = f"mssql+pymssql://{os.environ.get('DB_MSSQL_READER_USER','bench_reader')}:{os.environ.get('DB_MSSQL_READER_PASSWORD','BenchReader1!')}@{os.environ.get('DB_MSSQL_HOST','dtpipe-integ-mssql')}:{os.environ.get('DB_MSSQL_PORT','1433')}/{os.environ.get('DB_MSSQL_DB','master')}"
    mssql_writer_conn = f"mssql+pymssql://{os.environ.get('DB_MSSQL_WRITER_USER','bench_writer')}:{os.environ.get('DB_MSSQL_WRITER_PASSWORD','BenchWriter1!')}@{os.environ.get('DB_MSSQL_HOST','dtpipe-integ-mssql')}:{os.environ.get('DB_MSSQL_PORT','1433')}/{os.environ.get('DB_MSSQL_DB','master')}"
    mssql_writer_schema = os.environ.get('DB_MSSQL_WRITER_SCHEMA', 'bench_tgt')
    oracle_reader_conn = f"oracle+oracledb://{os.environ.get('DB_ORACLE_READER_USER','bench_reader')}:{os.environ.get('DB_ORACLE_READER_PASSWORD','password')}@{os.environ.get('DB_ORACLE_HOST','dtpipe-integ-oracle')}:{os.environ.get('DB_ORACLE_PORT','1521')}/?service_name={os.environ.get('DB_ORACLE_SERVICE','FREEPDB1')}"
    oracle_writer_conn = f"oracle+oracledb://{os.environ.get('DB_ORACLE_WRITER_USER','bench_writer')}:{os.environ.get('DB_ORACLE_WRITER_PASSWORD','password')}@{os.environ.get('DB_ORACLE_HOST','dtpipe-integ-oracle')}:{os.environ.get('DB_ORACLE_PORT','1521')}/?service_name={os.environ.get('DB_ORACLE_SERVICE','FREEPDB1')}"
    oracle_writer_user = os.environ.get('DB_ORACLE_WRITER_USER', 'bench_writer').upper()

    parquet_src = f"/bench/artifacts/source_data_{suffix}.parquet"
    csv_src = f"/bench/artifacts/source_data_{suffix}.csv"

    table_suffix = suffix
    oracle_table_suffix = suffix.upper()

    print(f"Running pandas benchmark {bench_id} on {rows} rows...")

    if bench_id == "B01":
        # Parquet -> PostgreSQL
        engine = create_engine(pg_conn)
        df = pd.read_parquet(parquet_src)
        if 'id' in df.columns:
            df['id'] = df['id'].apply(lambda x: x.hex() if isinstance(x, bytes) else str(x))
        df.to_sql(f"pandas_bench_pg", engine, if_exists="replace", index=False)

    elif bench_id == "B02":
        # PostgreSQL -> Parquet
        engine = create_engine(pg_conn)
        df = pd.read_sql(f"SELECT * FROM benchmark_source_{table_suffix}", engine)
        df.to_parquet(f"/bench/artifacts/pandas_bench_pg_to_pq.parquet", index=False)

    elif bench_id == "B03":
        # CSV -> SQL Server
        engine = create_engine(mssql_conn)
        df = pd.read_csv(csv_src)
        df.to_sql(f"pandas_bench_mssql", engine, if_exists="replace", index=False)

    elif bench_id == "B04":
        # SQL Server -> CSV
        engine = create_engine(mssql_conn)
        df = pd.read_sql(f"SELECT * FROM benchmark_source_{table_suffix}", engine)
        df.to_csv(f"/bench/artifacts/pandas_bench_mssql_to_csv.csv", index=False)

    elif bench_id == "B05":
        # Parquet -> Oracle
        engine = create_engine(oracle_conn)
        df = pd.read_parquet(parquet_src)
        if 'id' in df.columns:
            df['id'] = df['id'].apply(lambda x: x.hex() if isinstance(x, bytes) else str(x))
        df.to_sql(f"pandas_bench_oracle", engine, if_exists="replace", index=False)

    elif bench_id == "B06":
        # Oracle -> Parquet
        engine = create_engine(oracle_conn, arraysize=50000)
        df = pd.read_sql(f"SELECT * FROM BENCHMARK_SOURCE_{oracle_table_suffix}", engine)
        df.to_parquet(f"/bench/artifacts/pandas_bench_oracle_to_pq.parquet", index=False)

    elif bench_id == "B07":
        # CSV -> PostgreSQL
        engine = create_engine(pg_conn)
        df = pd.read_csv(csv_src)
        df.to_sql("pandas_bench_pg_csv", engine, if_exists="replace", index=False)

    elif bench_id == "B08":
        # PostgreSQL -> CSV
        engine = create_engine(pg_conn)
        df = pd.read_sql(f"SELECT * FROM benchmark_source_{table_suffix}", engine)
        df.to_csv(f"/bench/artifacts/pandas_bench_pg_to_csv.csv", index=False)

    elif bench_id == "B09":
        # Parquet -> SQL Server
        engine = create_engine(mssql_conn)
        df = pd.read_parquet(parquet_src)
        if 'id' in df.columns:
            df['id'] = df['id'].apply(lambda x: x.hex() if isinstance(x, bytes) else str(x))
        df.to_sql("pandas_bench_mssql_pq", engine, if_exists="replace", index=False)

    elif bench_id == "B10":
        # SQL Server -> Parquet
        engine = create_engine(mssql_conn)
        df = pd.read_sql(f"SELECT * FROM benchmark_source_{table_suffix}", engine)
        df.to_parquet(f"/bench/artifacts/pandas_bench_mssql_to_pq.parquet", index=False)

    elif bench_id == "B11":
        # CSV -> Oracle
        engine = create_engine(oracle_conn)
        df = pd.read_csv(csv_src)
        df.to_sql("pandas_bench_oracle_csv", engine, if_exists="replace", index=False, dtype={'amount': Numeric(18, 2)})

    elif bench_id == "B12":
        # Oracle -> CSV
        engine = create_engine(oracle_conn, arraysize=50000)
        df = pd.read_sql(f"SELECT * FROM BENCHMARK_SOURCE_{oracle_table_suffix}", engine)
        df.to_csv(f"/bench/artifacts/pandas_bench_oracle_to_csv.csv", index=False)

    elif bench_id == "B13":
        # PostgreSQL → PostgreSQL (bench_reader → bench_writer)
        src_engine = create_engine(pg_reader_conn)
        tgt_engine = create_engine(pg_writer_conn)
        df = pd.read_sql(f"SELECT * FROM benchmark_source_{table_suffix}", src_engine)
        df.to_sql("pandas_bench_pg2pg", tgt_engine, schema=pg_writer_schema, if_exists="replace", index=False)

    elif bench_id == "B14":
        # SQL Server → SQL Server (bench_reader → bench_writer)
        src_engine = create_engine(mssql_reader_conn)
        tgt_engine = create_engine(mssql_writer_conn)
        df = pd.read_sql(f"SELECT * FROM benchmark_source_{table_suffix}", src_engine)
        df.to_sql("pandas_bench_mssql2mssql", tgt_engine, schema=mssql_writer_schema, if_exists="replace", index=False)

    elif bench_id == "B15":
        # Oracle → Oracle (bench_reader → bench_writer)
        oracle_owner = os.environ.get('DB_ORACLE_USER', 'testuser').upper()
        src_engine = create_engine(oracle_reader_conn, arraysize=50000)
        tgt_engine = create_engine(oracle_writer_conn)
        df = pd.read_sql(f"SELECT RAWTOHEX(id) AS id, name, email, amount, country FROM {oracle_owner}.BENCHMARK_SOURCE_{oracle_table_suffix}", src_engine)
        df.to_sql("pandas_bench_ora2ora", tgt_engine, if_exists="replace", index=False, dtype={'amount': Numeric(18, 2)})

    else:
        print(f"Unknown benchmark ID: {bench_id}")
        sys.exit(1)

    print("Success")

if __name__ == "__main__":
    main()
