#!/usr/bin/env python3
import sys
import os
import subprocess
import re

# Resolve suffix from rows
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

# Load environment configuration
def load_env():
    env_vars = {}
     # Look for benchmark.env in the config directory relative to this script
    env_path = os.path.abspath(os.path.join(os.path.dirname(__file__), '..', 'config', 'benchmark.env'))
    if os.path.exists(env_path):
        try:
            with open(env_path, 'r') as f:
                for line in f:
                    line = line.strip()
                    if not line or line.startswith('#'):
                        continue
                    if '=' in line:
                        key, val = line.split('=', 1)
                         # Clean up bash default parameter values e.g. ${VAR:-default}
                        match = re.match(r'\$\{(?:\w+):-(.+)\}', val)
                        if match:
                            val = match.group(1)
                        env_vars[key] = val
        except Exception as e:
            print(f"Warning: Failed to load env file {env_path}: {e}")
    return env_vars

ENV = load_env()

def run_cmd(args):
    result = subprocess.run(args, capture_output=True, text=True)
    if result.returncode != 0:
        raise Exception(f"Command failed: {' '.join(args)}\nError: {result.stderr.strip()}")
    return result.stdout.strip()

# DuckDB query helper (runs in benchmark-sling container)
def query_file(file_path):
    from_clause = f"read_csv_auto('{file_path}', ignore_errors=true)" if file_path.endswith('.csv') else f"'{file_path}'"
    py_code = f"import duckdb; print('|'.join(map(str, duckdb.query(\"SELECT count(*), min(amount::DOUBLE), max(amount::DOUBLE), coalesce(sum(case when amount is null or amount::VARCHAR = '' then 1 else 0 end), 0) FROM {from_clause}\").fetchone())))"
    args = ["docker", "exec", "benchmark-sling", "python3", "-c", py_code]
    res = run_cmd(args)
    parts = res.split('|')
    return int(parts[0]), float(parts[1]), float(parts[2]), int(parts[3])

# Postgres query helper (runs in benchmark-native container using psql)
def query_postgres(table_name):
    host = ENV.get("DB_POSTGRES_HOST", "dtpipe-integ-postgres")
    port = ENV.get("DB_POSTGRES_PORT", "5432")
    db = ENV.get("DB_POSTGRES_DB", "integration")
    user = ENV.get("DB_POSTGRES_USER", "postgres")
    password = ENV.get("DB_POSTGRES_PASSWORD", "password")
    
    bash_script = f"env PGPASSWORD='{password}' psql -h '{host}' -p '{port}' -U '{user}' -d '{db}' -t -A -c 'SELECT count(*), min(amount), max(amount), count(*) FILTER (WHERE amount IS NULL) FROM {table_name}'"
    args = ["docker", "exec", "benchmark-native", "bash", "-c", bash_script]
    res = run_cmd(args)
    parts = res.split('|')
    return int(parts[0]), float(parts[1]), float(parts[2]), int(parts[3])

# SQL Server query helper (runs in benchmark-native container using sqlcmd)
def query_mssql(table_name):
    host = ENV.get("DB_MSSQL_HOST", "dtpipe-integ-mssql")
    port = ENV.get("DB_MSSQL_PORT", "1433")
    user = ENV.get("DB_MSSQL_USER", "sa")
    password = ENV.get("DB_MSSQL_PASSWORD", "Password123!")
    
    query = f"SELECT CAST(count(*) AS VARCHAR) + '|' + CAST(min(amount) AS VARCHAR) + '|' + CAST(max(amount) AS VARCHAR) + '|' + CAST(COUNT(CASE WHEN amount IS NULL THEN 1 END) AS VARCHAR) FROM {table_name}"
    args = [
          "docker", "exec", "benchmark-native", "sqlcmd", "-C",
          "-S", f"{host},{port}", "-U", user, "-P", password,
          "-d", "master", "-h", "-1", "-W", "-Q", query
      ]
    res = run_cmd(args)
      # Output might have trailing whitespace or "(1 rows affected)" line
    lines = [line.strip() for line in res.split('\n') if line.strip() and not line.startswith('(')]
    if not lines:
        raise Exception(f"No output from SQL Server for table {table_name}")
    parts = lines[0].split('|')
    return int(parts[0]), float(parts[1]), float(parts[2]), int(parts[3])

# Oracle query helper (runs in benchmark-native container using sqlplus)
def query_oracle(table_name):
    host = ENV.get("DB_ORACLE_HOST", "dtpipe-integ-oracle")
    port = ENV.get("DB_ORACLE_PORT", "1521")
    service = ENV.get("DB_ORACLE_SERVICE", "FREEPDB1")
    user = ENV.get("DB_ORACLE_USER", "testuser")
    password = ENV.get("DB_ORACLE_PASSWORD", "password")
    
    bash_script = f"sqlplus -S '{user}/{password}@//{host}:{port}/{service}' <<EOF\nSET HEADING OFF FEEDBACK OFF PAGESIZE 0 TAB OFF\nSELECT count(*)||'|'||min(amount)||'|'||max(amount)||'|'||COUNT(CASE WHEN amount IS NULL THEN 1 END) FROM {table_name};\nEXIT;\nEOF"
    args = ["docker", "exec", "benchmark-native", "bash", "-c", bash_script]
    res = run_cmd(args)
    parts = res.split('|')
    return int(parts[0]), float(parts[1]), float(parts[2]), int(parts[3])

def main():
    if len(sys.argv) < 4:
        print("Usage: verify_data.py <tool> <bench_id> <rows>")
        sys.exit(1)

    tool = sys.argv[1].lower()
    bench_id = sys.argv[2].upper()
    rows = sys.argv[3]
    
    suffix = get_suffix(rows)
    suffix_upper = suffix.upper()
    
    source_desc = ""
    target_desc = ""
    
    parquet_file = f"/bench/artifacts/source_data_{suffix}.parquet"
    csv_file = f"/bench/artifacts/source_data_{suffix}.csv"
    
     # Resolve target table/file names
    if tool == "dtpipe":
        pg_target = f"dtpipe_bench_pg" if bench_id == "B01" else "dtpipe_bench_pg_csv"
        mssql_target = f"dtpipe_bench_mssql" if bench_id == "B03" else "dtpipe_bench_mssql_pq"
        oracle_target = f"DTPIPE_BENCH_ORACLE" if bench_id == "B05" else "DTPIPE_BENCH_ORACLE_CSV"
        
        pq_target_file = f"/bench/artifacts/dtpipe_bench_pg_to_pq.parquet" if bench_id == "B02" else \
                          (f"/bench/artifacts/dtpipe_bench_oracle_to_pq.parquet" if bench_id == "B06" else f"/bench/artifacts/dtpipe_bench_mssql_to_pq.parquet")
                          
        csv_target_file = f"/bench/artifacts/dtpipe_bench_mssql_to_csv.csv" if bench_id == "B04" else \
                           (f"/bench/artifacts/dtpipe_bench_pg_to_csv.csv" if bench_id == "B08" else f"/bench/artifacts/dtpipe_bench_oracle_to_csv.csv")
    elif tool == "pandas":
        pg_target = f"pandas_bench_pg" if bench_id == "B01" else "pandas_bench_pg_csv"
        mssql_target = f"pandas_bench_mssql" if bench_id == "B03" else "pandas_bench_mssql_pq"
        oracle_target = f"pandas_bench_oracle" if bench_id == "B05" else "pandas_bench_oracle_csv"
        
        pq_target_file = f"/bench/artifacts/pandas_bench_pg_to_pq.parquet" if bench_id == "B02" else \
                          (f"/bench/artifacts/pandas_bench_oracle_to_pq.parquet" if bench_id == "B06" else f"/bench/artifacts/pandas_bench_mssql_to_pq.parquet")
                          
        csv_target_file = f"/bench/artifacts/pandas_bench_mssql_to_csv.csv" if bench_id == "B04" else \
                           (f"/bench/artifacts/pandas_bench_pg_to_csv.csv" if bench_id == "B08" else f"/bench/artifacts/pandas_bench_oracle_to_csv.csv")
    elif tool == "meltano":
        pg_target = f"meltano_bench_pg" if bench_id == "B01" else "meltano_bench_pg_csv"
        mssql_target = f"meltano_bench_mssql" if bench_id == "B03" else "meltano_bench_mssql_pq"
        oracle_target = f"meltano_bench_oracle" if bench_id == "B05" else "meltano_bench_oracle_csv"
        
        pq_target_file = f"/bench/artifacts/meltano_bench_pg_to_pq.parquet" if bench_id == "B02" else \
                          (f"/bench/artifacts/meltano_bench_oracle_to_pq.parquet" if bench_id == "B06" else f"/bench/artifacts/meltano_bench_mssql_to_pq.parquet")
                          
        csv_target_file = f"/bench/artifacts/meltano_bench_mssql_to_csv.csv" if bench_id == "B04" else \
                           (f"/bench/artifacts/meltano_bench_pg_to_csv.csv" if bench_id == "B08" else f"/bench/artifacts/meltano_bench_oracle_to_csv.csv")
    elif tool == "sling":
        pg_target = f"public.sling_bench_pg" if bench_id == "B01" else "public.sling_bench_pg_csv"
        mssql_target = f"dbo.sling_bench_mssql" if bench_id == "B03" else "dbo.sling_bench_mssql_pq"
        oracle_target = f"TESTUSER.SLING_BENCH_ORACLE" if bench_id == "B05" else "TESTUSER.SLING_BENCH_ORACLE_CSV"
        
        pq_target_file = f"/bench/artifacts/sling_bench_pg_to_pq.parquet" if bench_id == "B02" else \
                          (f"/bench/artifacts/sling_bench_oracle_to_pq.parquet" if bench_id == "B06" else f"/bench/artifacts/sling_bench_mssql_to_pq.parquet")
                          
        csv_target_file = f"/bench/artifacts/sling_bench_mssql_to_csv.csv" if bench_id == "B04" else \
                           (f"/bench/artifacts/sling_bench_pg_to_csv.csv" if bench_id == "B08" else f"/bench/artifacts/sling_bench_oracle_to_csv.csv")
    elif tool == "ingestr":
        pg_target = f"ingestr_bench_pg" if bench_id == "B01" else "ingestr_bench_pg_csv"
        mssql_target = f"ingestr_bench_mssql" if bench_id == "B03" else "ingestr_bench_mssql_pq"
        oracle_target = f"INGESTR_BENCH_ORACLE" if bench_id == "B05" else "INGESTR_BENCH_ORACLE_CSV"
        
        pq_target_file = f"/bench/artifacts/ingestr_bench_pg_to_pq.parquet" if bench_id == "B02" else \
                          (f"/bench/artifacts/ingestr_bench_oracle_to_pq.parquet" if bench_id == "B06" else f"/bench/artifacts/ingestr_bench_mssql_to_pq.parquet")
                          
        csv_target_file = f"/bench/artifacts/ingestr_bench_mssql_to_csv.csv" if bench_id == "B04" else \
                           (f"/bench/artifacts/ingestr_bench_pg_to_csv.csv" if bench_id == "B08" else f"/bench/artifacts/ingestr_bench_oracle_to_csv.csv")
    elif tool == "native":
        pg_target = f"native_bench_pg"
        mssql_target = f"native_bench_mssql"
        oracle_target = f"NATIVE_BENCH_ORACLE"
        
        pq_target_file = None
        
        csv_target_file = f"/bench/artifacts/native_bench_mssql_to_csv.csv" if bench_id == "B04" else \
                           (f"/bench/artifacts/native_bench_pg_to_csv.csv" if bench_id == "B08" else f"/bench/artifacts/native_bench_oracle_to_csv.csv")
    else:
        print(f"Unknown tool: {tool}")
        sys.exit(1)

    try:
          # Get Source and Target stats
        if bench_id == "B01": # Parquet -> PostgreSQL
            source_desc = f"Parquet: {parquet_file}"
            target_desc = f"Postgres table: {pg_target}"
            s_rows, s_min, s_max, s_nulls = query_file(parquet_file)
            t_rows, t_min, t_max, t_nulls = query_postgres(pg_target)
            
        elif bench_id == "B02": # PostgreSQL -> Parquet
            source_desc = f"Postgres table: benchmark_source_{suffix}"
            target_desc = f"Parquet: {pq_target_file}"
            s_rows, s_min, s_max, s_nulls = query_postgres(f"benchmark_source_{suffix}")
            t_rows, t_min, t_max, t_nulls = query_file(pq_target_file)
            
        elif bench_id == "B03": # CSV -> SQL Server
            source_desc = f"CSV: {csv_file}"
            target_desc = f"SQL Server table: {mssql_target}"
            s_rows, s_min, s_max, s_nulls = query_file(csv_file)
            t_rows, t_min, t_max, t_nulls = query_mssql(mssql_target)
            
        elif bench_id == "B04": # SQL Server -> CSV
            source_desc = f"SQL Server table: benchmark_source_{suffix}"
            target_desc = f"CSV: {csv_target_file}"
            s_rows, s_min, s_max, s_nulls = query_mssql(f"benchmark_source_{suffix}")
            t_rows, t_min, t_max, t_nulls = query_file(csv_target_file)
            
        elif bench_id == "B05": # Parquet -> Oracle
            source_desc = f"Parquet: {parquet_file}"
            target_desc = f"Oracle table: {oracle_target}"
            s_rows, s_min, s_max, s_nulls = query_file(parquet_file)
            t_rows, t_min, t_max, t_nulls = query_oracle(oracle_target)
            
        elif bench_id == "B06": # Oracle -> Parquet
            source_desc = f"Oracle table: BENCHMARK_SOURCE_{suffix_upper}"
            target_desc = f"Parquet: {pq_target_file}"
            s_rows, s_min, s_max, s_nulls = query_oracle(f"BENCHMARK_SOURCE_{suffix_upper}")
            t_rows, t_min, t_max, t_nulls = query_file(pq_target_file)
            
        elif bench_id == "B07": # CSV -> PostgreSQL
            source_desc = f"CSV: {csv_file}"
            target_desc = f"Postgres table: {pg_target}"
            s_rows, s_min, s_max, s_nulls = query_file(csv_file)
            t_rows, t_min, t_max, t_nulls = query_postgres(pg_target)
            
        elif bench_id == "B08": # PostgreSQL -> CSV
            source_desc = f"Postgres table: benchmark_source_{suffix}"
            target_desc = f"CSV: {csv_target_file}"
            s_rows, s_min, s_max, s_nulls = query_postgres(f"benchmark_source_{suffix}")
            t_rows, t_min, t_max, t_nulls = query_file(csv_target_file)
            
        elif bench_id == "B09": # Parquet -> SQL Server
            source_desc = f"Parquet: {parquet_file}"
            target_desc = f"SQL Server table: {mssql_target}"
            s_rows, s_min, s_max, s_nulls = query_file(parquet_file)
            t_rows, t_min, t_max, t_nulls = query_mssql(mssql_target)
            
        elif bench_id == "B10": # SQL Server -> Parquet
            source_desc = f"SQL Server table: benchmark_source_{suffix}"
            target_desc = f"Parquet: {pq_target_file}"
            s_rows, s_min, s_max, s_nulls = query_mssql(f"benchmark_source_{suffix}")
            t_rows, t_min, t_max, t_nulls = query_file(pq_target_file)
            
        elif bench_id == "B11": # CSV -> Oracle
            source_desc = f"CSV: {csv_file}"
            target_desc = f"Oracle table: {oracle_target}"
            s_rows, s_min, s_max, s_nulls = query_file(csv_file)
            t_rows, t_min, t_max, t_nulls = query_oracle(oracle_target)
            
        elif bench_id == "B12": # Oracle -> CSV
            source_desc = f"Oracle table: BENCHMARK_SOURCE_{suffix_upper}"
            target_desc = f"CSV: {csv_target_file}"
            s_rows, s_min, s_max, s_nulls = query_oracle(f"BENCHMARK_SOURCE_{suffix_upper}")
            t_rows, t_min, t_max, t_nulls = query_file(csv_target_file)
            
        else:
            print(f"Unknown benchmark ID: {bench_id}")
            sys.exit(1)

          # Print detailed statistics comparison
        print(f"==================================================")
        print(f" VERIFICATION: {tool.upper()} - {bench_id}")
        print(f"==================================================")
        print(f"Source: {source_desc}")
        print(f"Target: {target_desc}")
        print(f"--------------------------------------------------")
        print(f"Statistic    | Source              | Target")
        print(f"--------------------------------------------------")
        print(f"Rows          | {s_rows:<16} | {t_rows:<16}")
        print(f"Min Amount    | {s_min:<16.2f} | {t_min:<16.2f}")
        print(f"Max Amount    | {s_max:<16.2f} | {t_max:<16.2f}")
        print(f"Null Amounts  | {s_nulls:<16} | {t_nulls:<16}")
        print(f"--------------------------------------------------")
        
        row_match = (s_rows == t_rows)
        min_match = (abs(s_min - t_min) < 0.01)
        max_match = (abs(s_max - t_max) < 0.01)
        nulls_match = (s_nulls == t_nulls)
        
        if row_match and min_match and max_match and nulls_match:
            print("\033[92mRESULT: PASS (Data matches)\033[0m")
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