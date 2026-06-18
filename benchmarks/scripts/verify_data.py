#!/usr/bin/env python3
"""verify_data.py — Verify benchmark data integrity using DuckDB and native DB drivers.

This script is intended to run INSIDE the benchmark-native Docker container
which has Python3 + DuckDB + DB drivers (psycopg2, pymssql, oracledb).
It reads source/target files with DuckDB and queries databases directly,
then prints a verification report to stdout.

Usage:
    python3 verify_data.py <tool> <bench_id> <rows>
"""
import sys
import os
import re
from datetime import datetime, timezone

# ── Resolve suffix from rows ─────────────────────────────────────────────────
def get_suffix(rows_str):
    try:
        val = int(rows_str)
        if val == 5000000:
            return "5m"
        elif val == 2000000:
            return "2m"
        elif val % 1000000 == 0:
            return f"{val // 1000000}m"
        else:
            return str(val)
    except ValueError:
        return rows_str

# ── Load environment configuration ───────────────────────────────────────────
def load_env():
    env_vars = {}
    env_path = os.path.join(os.path.dirname(__file__), '..', 'config', 'benchmark.env')
    env_path = os.path.abspath(env_path)
    if os.path.exists(env_path):
        try:
            with open(env_path, 'r') as f:
                for line in f:
                    line = line.strip()
                    if not line or line.startswith('#'):
                        continue
                    if '=' in line:
                        key, val = line.split('=', 1)
                        match = re.match(r'\$\{(?:\w+):-(.+)\}', val)
                        if match:
                            val = match.group(1)
                        env_vars[key] = val
        except Exception as e:
            print(f"Warning: Failed to load env file {env_path}: {e}", file=sys.stderr)
    return env_vars

ENV = load_env()

# ── DuckDB query helper for files (CSV/Parquet) ─────────────────────────────
_HEADERLESS_CSV_CASES = {("native", "B04")}

def query_file(file_path, tool="pandas", bench_id=""):
    import duckdb
    if file_path.endswith('.csv'):
        if (tool, bench_id) in _HEADERLESS_CSV_CASES:
            from_clause = f"read_csv('{file_path}', header=false, names=['id','name','email','amount','country'], ignore_errors=true)"
        else:
            from_clause = f"read_csv_auto('{file_path}', ignore_errors=true)"
    else:
        from_clause = f"'{file_path}'"
    result = duckdb.query(
        f"SELECT count(*), min(amount::DOUBLE), max(amount::DOUBLE), "
        f"coalesce(sum(case when amount is null or amount::VARCHAR = '' then 1 else 0 end), 0) "
        f"FROM {from_clause}"
    ).fetchone()
    return int(result[0]), float(result[1]), float(result[2]), int(result[3])

# ── DB query helper ──────────────────────────────────────────────────────────
def query_db(db_type, table_name):
    if db_type == "postgres":
        host = ENV.get("DB_POSTGRES_HOST", "dtpipe-integ-postgres")
        port = ENV.get("DB_POSTGRES_PORT", "5432")
        db   = ENV.get("DB_POSTGRES_DB", "integration")
        user = ENV.get("DB_POSTGRES_USER", "postgres")
        pwd  = ENV.get("DB_POSTGRES_PASSWORD", "password")
        import psycopg2
        conn = psycopg2.connect(host=host, port=port, dbname=db, user=user, password=pwd)
        cur = conn.cursor()
        cur.execute(
            f'SELECT count(*), min(amount::DOUBLE PRECISION), max(amount::DOUBLE PRECISION), '
            f'COUNT(CASE WHEN amount IS NULL THEN 1 END) FROM {table_name}'
        )
        row = cur.fetchone()
        conn.close()

    elif db_type == "mssql":
        host = ENV.get("DB_MSSQL_HOST", "dtpipe-integ-mssql")
        port = ENV.get("DB_MSSQL_PORT", "1433")
        user = ENV.get("DB_MSSQL_USER", "sa")
        pwd  = ENV.get("DB_MSSQL_PASSWORD", "Password123!")
        import pymssql
        conn = pymssql.connect(server=host, port=port, database='master', user=user, password=pwd)
        cur = conn.cursor()
        cur.execute(
            f'SELECT count(*), min(CAST(amount AS FLOAT)), max(CAST(amount AS FLOAT)), '
            f'COUNT(CASE WHEN amount IS NULL THEN 1 END) FROM {table_name}'
        )
        row = cur.fetchone()
        conn.close()

    elif db_type == "oracle":
        host     = ENV.get("DB_ORACLE_HOST", "dtpipe-integ-oracle")
        port     = ENV.get("DB_ORACLE_PORT", "1521")
        service  = ENV.get("DB_ORACLE_SERVICE", "FREEPDB1")
        # Use the owner of the table as the connection user when the table is schema-qualified.
        # For bench_writer-owned tables (B15 targets), connect as bench_writer.
        # For standard testuser tables, connect as testuser.
        oracle_writer = ENV.get("DB_ORACLE_WRITER_USER", "bench_writer").upper()
        if table_name.upper().startswith(oracle_writer + "."):
            user = ENV.get("DB_ORACLE_WRITER_USER", "bench_writer")
            pwd  = ENV.get("DB_ORACLE_WRITER_PASSWORD", "password")
        else:
            user = ENV.get("DB_ORACLE_USER", "testuser")
            pwd  = ENV.get("DB_ORACLE_PASSWORD", "password")
        import oracledb
        conn = oracledb.connect(user=user, password=pwd, dsn=f'{host}:{port}/{service}')
        cur = conn.cursor()
        cur.execute(
            f'SELECT count(*), min(TO_NUMBER(TO_CHAR(amount))), max(TO_NUMBER(TO_CHAR(amount))), '
            f'COUNT(CASE WHEN amount IS NULL THEN 1 END) FROM {table_name}'
        )
        row = cur.fetchone()
        conn.close()

    else:
        raise Exception(f"Unknown db_type: {db_type}")

    return int(row[0]), float(row[1]), float(row[2]), int(row[3])


def main():
    if len(sys.argv) < 4:
        print("Usage: verify_data.py <tool> <bench_id> <rows>")
        sys.exit(1)

    tool = sys.argv[1].lower()
    bench_id = sys.argv[2].upper()
    rows = sys.argv[3]

    suffix = get_suffix(rows)
    suffix_upper = suffix.upper()

    parquet_file = f"/bench/artifacts/source_data_{suffix}.parquet"
    csv_file = f"/bench/artifacts/source_data_{suffix}.csv"

    # ── Resolve target file/table names per tool ──────────────────────────
    if tool == "dtpipe":
        pg_target     = f"dtpipe_bench_pg" if bench_id == "B01" else "dtpipe_bench_pg_csv"
        mssql_target  = f"dtpipe_bench_mssql" if bench_id == "B03" else "dtpipe_bench_mssql_pq"
        oracle_target = f"DTPIPE_BENCH_ORACLE" if bench_id == "B05" else "DTPIPE_BENCH_ORACLE_CSV"
        pq_target_file = f"/bench/artifacts/dtpipe_bench_pg_to_pq.parquet" if bench_id == "B02" else \
                          (f"/bench/artifacts/dtpipe_bench_oracle_to_pq.parquet" if bench_id == "B06" else
                           f"/bench/artifacts/dtpipe_bench_mssql_to_pq.parquet")
        csv_target_file = f"/bench/artifacts/dtpipe_bench_mssql_to_csv.csv" if bench_id == "B04" else \
                           (f"/bench/artifacts/dtpipe_bench_pg_to_csv.csv" if bench_id == "B08" else
                            f"/bench/artifacts/dtpipe_bench_oracle_to_csv.csv")
    elif tool == "pandas":
        pg_target     = f"pandas_bench_pg" if bench_id == "B01" else "pandas_bench_pg_csv"
        mssql_target  = f"pandas_bench_mssql" if bench_id == "B03" else "pandas_bench_mssql_pq"
        oracle_target = f"pandas_bench_oracle" if bench_id == "B05" else "pandas_bench_oracle_csv"
        pq_target_file = f"/bench/artifacts/pandas_bench_pg_to_pq.parquet" if bench_id == "B02" else \
                          (f"/bench/artifacts/pandas_bench_oracle_to_pq.parquet" if bench_id == "B06" else
                           f"/bench/artifacts/pandas_bench_mssql_to_pq.parquet")
        csv_target_file = f"/bench/artifacts/pandas_bench_mssql_to_csv.csv" if bench_id == "B04" else \
                           (f"/bench/artifacts/pandas_bench_pg_to_csv.csv" if bench_id == "B08" else
                            f"/bench/artifacts/pandas_bench_oracle_to_csv.csv")
    elif tool == "meltano":
        pg_target     = f"meltano_bench_pg" if bench_id == "B01" else "meltano_bench_pg_csv"
        mssql_target  = f"meltano_bench_mssql" if bench_id == "B03" else "meltano_bench_mssql_pq"
        oracle_target = f"meltano_bench_oracle" if bench_id == "B05" else "meltano_bench_oracle_csv"
        pq_target_file = f"/bench/artifacts/meltano_bench_pg_to_pq.parquet" if bench_id == "B02" else \
                          (f"/bench/artifacts/meltano_bench_oracle_to_pq.parquet" if bench_id == "B06" else
                           f"/bench/artifacts/meltano_bench_mssql_to_pq.parquet")
        csv_target_file = f"/bench/artifacts/meltano_bench_mssql_to_csv.csv" if bench_id == "B04" else \
                           (f"/bench/artifacts/meltano_bench_pg_to_csv.csv" if bench_id == "B08" else
                            f"/bench/artifacts/meltano_bench_oracle_to_csv.csv")
    elif tool == "sling":
        pg_target     = f"public.sling_bench_pg" if bench_id == "B01" else "public.sling_bench_pg_csv"
        mssql_target  = f"dbo.sling_bench_mssql" if bench_id == "B03" else "dbo.sling_bench_mssql_pq"
        oracle_user   = ENV.get("DB_ORACLE_USER", "testuser").upper()
        oracle_target = f"{oracle_user}.SLING_BENCH_ORACLE" if bench_id == "B05" else f"{oracle_user}.SLING_BENCH_ORACLE_CSV"
        pq_target_file = f"/bench/artifacts/sling_bench_pg_to_pq.parquet" if bench_id == "B02" else \
                          (f"/bench/artifacts/sling_bench_oracle_to_pq.parquet" if bench_id == "B06" else
                           f"/bench/artifacts/sling_bench_mssql_to_pq.parquet")
        csv_target_file = f"/bench/artifacts/sling_bench_mssql_to_csv.csv" if bench_id == "B04" else \
                           (f"/bench/artifacts/sling_bench_pg_to_csv.csv" if bench_id == "B08" else
                            f"/bench/artifacts/sling_bench_oracle_to_csv.csv")
    elif tool == "ingestr":
        pg_target     = f"ingestr_bench_pg" if bench_id == "B01" else "ingestr_bench_pg_csv"
        mssql_target  = f"ingestr_bench_mssql" if bench_id == "B03" else "ingestr_bench_mssql_pq"
        oracle_target = f"INGESTR_BENCH_ORACLE" if bench_id == "B05" else "INGESTR_BENCH_ORACLE_CSV"
        pq_target_file = f"/bench/artifacts/ingestr_bench_pg_to_pq.parquet" if bench_id == "B02" else \
                          (f"/bench/artifacts/ingestr_bench_oracle_to_pq.parquet" if bench_id == "B06" else
                           f"/bench/artifacts/ingestr_bench_mssql_to_pq.parquet")
        csv_target_file = f"/bench/artifacts/ingestr_bench_mssql_to_csv.csv" if bench_id == "B04" else \
                           (f"/bench/artifacts/ingestr_bench_pg_to_csv.csv" if bench_id == "B08" else
                            f"/bench/artifacts/ingestr_bench_oracle_to_csv.csv")
    elif tool == "native":
        pg_target     = f"native_bench_pg"
        mssql_target  = f"native_bench_mssql"
        oracle_target = f"NATIVE_BENCH_ORACLE"
        pq_target_file = None
        csv_target_file = f"/bench/artifacts/native_bench_mssql_to_csv.csv" if bench_id == "B04" else \
                           (f"/bench/artifacts/native_bench_pg_to_csv.csv" if bench_id == "B08" else
                            f"/bench/artifacts/native_bench_oracle_to_csv.csv")
    else:
        print(f"Unknown tool: {tool}")
        sys.exit(1)

    # ── B13/B14/B15 intra-DB: override source/target tables with reader/writer accounts
    pg_writer_schema   = ENV.get("DB_POSTGRES_WRITER_SCHEMA", "bench_tgt")
    mssql_writer_schema = ENV.get("DB_MSSQL_WRITER_SCHEMA", "bench_tgt")
    oracle_writer_user = ENV.get("DB_ORACLE_WRITER_USER", "bench_writer").upper()
    oracle_owner_user  = ENV.get("DB_ORACLE_USER", "testuser").upper()

    if bench_id == "B13":
        pg2pg_targets = {
            "dtpipe":  f"{pg_writer_schema}.dtpipe_bench_pg2pg",
            "pandas":  f"{pg_writer_schema}.pandas_bench_pg2pg",
            "meltano": f"{pg_writer_schema}.meltano_bench_pg2pg",
            "sling":   f"{pg_writer_schema}.sling_bench_pg2pg",
            "ingestr": f"{pg_writer_schema}.ingestr_bench_pg2pg",
            "native":  f"{pg_writer_schema}.native_bench_pg2pg",
        }
        pg_target_b13 = pg2pg_targets.get(tool, f"{pg_writer_schema}.{tool}_bench_pg2pg")
    elif bench_id == "B14":
        mssql2mssql_targets = {
            "dtpipe":  f"{mssql_writer_schema}.dtpipe_bench_mssql2mssql",
            "pandas":  f"{mssql_writer_schema}.pandas_bench_mssql2mssql",
            "sling":   f"{mssql_writer_schema}.sling_bench_mssql2mssql",
            "ingestr": f"{mssql_writer_schema}.ingestr_bench_mssql2mssql",
            "native":  f"{mssql_writer_schema}.native_bench_mssql2mssql",
        }
        mssql_target_b14 = mssql2mssql_targets.get(tool, f"{mssql_writer_schema}.{tool}_bench_mssql2mssql")
    elif bench_id == "B15":
        ora2ora_targets = {
            "dtpipe":  f"{oracle_writer_user}.DTPIPE_BENCH_ORA2ORA",
            "pandas":  f"{oracle_writer_user}.PANDAS_BENCH_ORA2ORA",
            "sling":   f"{oracle_writer_user}.SLING_BENCH_ORA2ORA",
            "native":  f"{oracle_writer_user}.NATIVE_BENCH_ORA2ORA",
        }
        oracle_target_b15 = ora2ora_targets.get(tool, f"{oracle_writer_user}.{tool.upper()}_BENCH_ORA2ORA")

    try:
        if bench_id == "B01":   # Parquet → PostgreSQL
            source_desc = f"Parquet: {parquet_file}"
            target_desc = f"Postgres table: {pg_target}"
            s_rows, s_min, s_max, s_nulls = query_file(tool=tool, bench_id=bench_id, file_path=parquet_file)
            t_rows, t_min, t_max, t_nulls = query_db("postgres", pg_target)

        elif bench_id == "B02":   # PostgreSQL → Parquet
            source_desc = f"Postgres table: benchmark_source_{suffix}"
            target_desc = f"Parquet: {pq_target_file}"
            s_rows, s_min, s_max, s_nulls = query_db("postgres", f"benchmark_source_{suffix}")
            t_rows, t_min, t_max, t_nulls = query_file(tool=tool, bench_id=bench_id, file_path=pq_target_file)

        elif bench_id == "B03":   # CSV → SQL Server
            source_desc = f"CSV: {csv_file}"
            target_desc = f"SQL Server table: {mssql_target}"
            s_rows, s_min, s_max, s_nulls = query_file(tool=tool, bench_id=bench_id, file_path=csv_file)
            t_rows, t_min, t_max, t_nulls = query_db("mssql", mssql_target)

        elif bench_id == "B04":   # SQL Server → CSV
            source_desc = f"SQL Server table: benchmark_source_{suffix}"
            target_desc = f"CSV: {csv_target_file}"
            s_rows, s_min, s_max, s_nulls = query_db("mssql", f"benchmark_source_{suffix}")
            t_rows, t_min, t_max, t_nulls = query_file(tool=tool, bench_id=bench_id, file_path=csv_target_file)

        elif bench_id == "B05":   # Parquet → Oracle
            source_desc = f"Parquet: {parquet_file}"
            target_desc = f"Oracle table: {oracle_target}"
            s_rows, s_min, s_max, s_nulls = query_file(tool=tool, bench_id=bench_id, file_path=parquet_file)
            t_rows, t_min, t_max, t_nulls = query_db("oracle", oracle_target)

        elif bench_id == "B06":   # Oracle → Parquet
            source_desc = f"Oracle table: BENCHMARK_SOURCE_{suffix_upper}"
            target_desc = f"Parquet: {pq_target_file}"
            s_rows, s_min, s_max, s_nulls = query_db("oracle", f"BENCHMARK_SOURCE_{suffix_upper}")
            t_rows, t_min, t_max, t_nulls = query_file(tool=tool, bench_id=bench_id, file_path=pq_target_file)

        elif bench_id == "B07":   # CSV → PostgreSQL
            source_desc = f"CSV: {csv_file}"
            target_desc = f"Postgres table: {pg_target}"
            s_rows, s_min, s_max, s_nulls = query_file(tool=tool, bench_id=bench_id, file_path=csv_file)
            t_rows, t_min, t_max, t_nulls = query_db("postgres", pg_target)

        elif bench_id == "B08":   # PostgreSQL → CSV
            source_desc = f"Postgres table: benchmark_source_{suffix}"
            target_desc = f"CSV: {csv_target_file}"
            s_rows, s_min, s_max, s_nulls = query_db("postgres", f"benchmark_source_{suffix}")
            t_rows, t_min, t_max, t_nulls = query_file(tool=tool, bench_id=bench_id, file_path=csv_target_file)

        elif bench_id == "B09":   # Parquet → SQL Server
            source_desc = f"Parquet: {parquet_file}"
            target_desc = f"SQL Server table: {mssql_target}"
            s_rows, s_min, s_max, s_nulls = query_file(tool=tool, bench_id=bench_id, file_path=parquet_file)
            t_rows, t_min, t_max, t_nulls = query_db("mssql", mssql_target)

        elif bench_id == "B10":   # SQL Server → Parquet
            source_desc = f"SQL Server table: benchmark_source_{suffix}"
            target_desc = f"Parquet: {pq_target_file}"
            s_rows, s_min, s_max, s_nulls = query_db("mssql", f"benchmark_source_{suffix}")
            t_rows, t_min, t_max, t_nulls = query_file(tool=tool, bench_id=bench_id, file_path=pq_target_file)

        elif bench_id == "B11":   # CSV → Oracle
            source_desc = f"CSV: {csv_file}"
            target_desc = f"Oracle table: {oracle_target}"
            s_rows, s_min, s_max, s_nulls = query_file(tool=tool, bench_id=bench_id, file_path=csv_file)
            t_rows, t_min, t_max, t_nulls = query_db("oracle", oracle_target)

        elif bench_id == "B12":   # Oracle → CSV
            source_desc = f"Oracle table: BENCHMARK_SOURCE_{suffix_upper}"
            target_desc = f"CSV: {csv_target_file}"
            s_rows, s_min, s_max, s_nulls = query_db("oracle", f"BENCHMARK_SOURCE_{suffix_upper}")
            t_rows, t_min, t_max, t_nulls = query_file(tool=tool, bench_id=bench_id, file_path=csv_target_file)

        elif bench_id == "B13":   # PostgreSQL → PostgreSQL
            source_desc = f"Postgres table: benchmark_source_{suffix} (bench_reader)"
            target_desc = f"Postgres table: {pg_target_b13} (bench_writer)"
            s_rows, s_min, s_max, s_nulls = query_db("postgres", f"benchmark_source_{suffix}")
            t_rows, t_min, t_max, t_nulls = query_db("postgres", pg_target_b13)

        elif bench_id == "B14":   # SQL Server → SQL Server
            source_desc = f"SQL Server table: benchmark_source_{suffix} (bench_reader)"
            target_desc = f"SQL Server table: {mssql_target_b14} (bench_writer)"
            s_rows, s_min, s_max, s_nulls = query_db("mssql", f"benchmark_source_{suffix}")
            t_rows, t_min, t_max, t_nulls = query_db("mssql", mssql_target_b14)

        elif bench_id == "B15":   # Oracle → Oracle
            source_desc = f"Oracle table: {oracle_owner_user}.BENCHMARK_SOURCE_{suffix_upper} (bench_reader)"
            target_desc = f"Oracle table: {oracle_target_b15} (bench_writer)"
            s_rows, s_min, s_max, s_nulls = query_db("oracle", f"{oracle_owner_user}.BENCHMARK_SOURCE_{suffix_upper}")
            t_rows, t_min, t_max, t_nulls = query_db("oracle", oracle_target_b15)

        else:
            print(f"Unknown benchmark ID: {bench_id}")
            sys.exit(1)

        print(f"==================================================")
        print(f" VERIFICATION: {tool.upper()} - {bench_id}")
        print(f"==================================================")
        print(f"Source: {source_desc}")
        print(f"Target: {target_desc}")
        print(f"--------------------------------------------------")
        print(f"Statistic     | Source               | Target")
        print(f"--------------------------------------------------")
        print(f"Rows           | {s_rows:<16} | {t_rows:<16}")
        print(f"Min Amount     | {s_min:<16.2f} | {t_min:<16.2f}")
        print(f"Max Amount     | {s_max:<16.2f} | {t_max:<16.2f}")
        print(f"Null Amounts   | {s_nulls:<16} | {t_nulls:<16}")
        print(f"--------------------------------------------------")

        row_match   = (s_rows == t_rows)
        min_match   = (abs(s_min - t_min) < 0.01)
        max_match   = (abs(s_max - t_max) < 0.01)
        nulls_match = (s_nulls == t_nulls)

        if row_match and min_match and max_match and nulls_match:
            print(f"\033[92mRESULT: PASS (Data matches)\033[0m")
            return True
        else:
            errors = []
            if not row_match:
                errors.append(f"Row count mismatch (Source={s_rows}, Target={t_rows})")
            if not min_match:
                errors.append(f"Min amount mismatch (Source={s_min}, Target={t_min})")
            if not max_match:
                errors.append(f"Max amount mismatch (Source={s_max}, Target={t_max})")
            if not nulls_match:
                errors.append(f"Null count mismatch (Source={s_nulls}, Target={t_nulls})")
            print(f"\033[91mRESULT: FAIL ({', '.join(errors)})\033[0m")
            return False

    except Exception as e:
        print(f"\033[91mRESULT: ERROR (Unable to verify) - {str(e)}\033[0m")
        return False

if __name__ == "__main__":
    success = main()
    sys.exit(0 if success else 1)