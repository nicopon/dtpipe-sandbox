import sys
import os
from sling import Sling

def main():
    if len(sys.argv) < 2:
        print("Usage: _sling_bench.py <bench_id> [rows]")
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
    pg_conn = "postgresql://postgres:password@dtpipe-integ-postgres:5432/integration?sslmode=disable"
    mssql_conn = "sqlserver://sa:Password123!@dtpipe-integ-mssql:1433?database=master&encrypt=disable&TrustServerCertificate=true"
    oracle_conn = f"oracle://testuser:password@dtpipe-integ-oracle:1521?service_name=FREEPDB1&PREFETCH_ROWS=50000"

    parquet_src = f"file:///bench/artifacts/source_data_{suffix}.parquet"
    csv_src = f"file:///bench/artifacts/source_data_{suffix}.csv"

    table_suffix = suffix
    oracle_table_suffix = suffix.upper()

    print(f"Running sling benchmark {bench_id} on {rows} rows...")

    if bench_id == "B01":
        # Parquet -> PostgreSQL
        Sling(
            src_conn=parquet_src,
            tgt_conn=pg_conn,
            tgt_object="public.sling_bench_pg",
            mode="full-refresh"
        ).run()

    elif bench_id == "B02":
        # PostgreSQL -> Parquet
        Sling(
            src_conn=pg_conn,
            src_stream=f"public.benchmark_source_{table_suffix}",
            tgt_object="file:///bench/artifacts/sling_bench_pg_to_pq.parquet",
            mode="full-refresh"
        ).run()

    elif bench_id == "B03":
        # CSV -> SQL Server
        Sling(
            src_conn=csv_src,
            tgt_conn=mssql_conn,
            tgt_object="dbo.sling_bench_mssql",
            mode="full-refresh"
        ).run()

    elif bench_id == "B04":
        # SQL Server -> CSV
        Sling(
            src_conn=mssql_conn,
            src_stream=f"dbo.benchmark_source_{table_suffix}",
            tgt_object="file:///bench/artifacts/sling_bench_mssql_to_csv.csv",
            mode="full-refresh"
        ).run()

    elif bench_id == "B05":
        # Parquet -> Oracle
        Sling(
            src_conn=parquet_src,
            tgt_conn=oracle_conn,
            tgt_object="TESTUSER.SLING_BENCH_ORACLE",
            mode="full-refresh"
        ).run()

    elif bench_id == "B06":
        # Oracle -> Parquet
        Sling(
            src_conn=oracle_conn,
            src_stream=f"SELECT RAWTOHEX(id) as id, name, email, amount, country FROM TESTUSER.BENCHMARK_SOURCE_{oracle_table_suffix}",
            tgt_object="file:///bench/artifacts/sling_bench_oracle_to_pq.parquet",
            mode="full-refresh"
        ).run()

    elif bench_id == "B07":
        # CSV -> PostgreSQL
        Sling(
            src_conn=csv_src,
            tgt_conn=pg_conn,
            tgt_object="public.sling_bench_pg_csv",
            mode="full-refresh"
        ).run()

    elif bench_id == "B08":
        # PostgreSQL -> CSV
        Sling(
            src_conn=pg_conn,
            src_stream=f"public.benchmark_source_{table_suffix}",
            tgt_object="file:///bench/artifacts/sling_bench_pg_to_csv.csv",
            mode="full-refresh"
        ).run()

    elif bench_id == "B09":
        # Parquet -> SQL Server
        Sling(
            src_conn=parquet_src,
            tgt_conn=mssql_conn,
            tgt_object="dbo.sling_bench_mssql_pq",
            mode="full-refresh"
        ).run()

    elif bench_id == "B10":
        # SQL Server -> Parquet
        Sling(
            src_conn=mssql_conn,
            src_stream=f"dbo.benchmark_source_{table_suffix}",
            tgt_object="file:///bench/artifacts/sling_bench_mssql_to_pq.parquet",
            mode="full-refresh"
        ).run()

    elif bench_id == "B11":
        # CSV -> Oracle
        Sling(
            src_conn=csv_src,
            tgt_conn=oracle_conn,
            tgt_object="TESTUSER.SLING_BENCH_ORACLE_CSV",
            mode="full-refresh"
        ).run()

    elif bench_id == "B12":
        # Oracle -> CSV
        Sling(
            src_conn=oracle_conn,
            src_stream=f"SELECT RAWTOHEX(id) as id, name, email, amount, country FROM TESTUSER.BENCHMARK_SOURCE_{oracle_table_suffix}",
            tgt_object="file:///bench/artifacts/sling_bench_oracle_to_csv.csv",
            mode="full-refresh"
        ).run()


    else:
        print(f"Unknown benchmark ID: {bench_id}")
        sys.exit(1)

    print("Success")

if __name__ == "__main__":
    main()
