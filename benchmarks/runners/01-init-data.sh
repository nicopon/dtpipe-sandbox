#!/usr/bin/env bash
# =============================================================================
# 01-init-data.sh - Source data initialization for benchmark
# 
# Generates a 5M row dataset via dtpipe (in benchmark-test container)
# Loads data into PostgreSQL, SQL Server and Oracle
# 
# IMPORTANT: Everything runs inside containers, nothing on the host
# Supports Docker and Podman runtimes.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/../config/docker-compose-benchmark.yml"
ARTIFACTS_DIR="$SCRIPT_DIR/../artifacts"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
LIB_DIR="$SCRIPT_DIR/../lib"

# Source the container runtime detection module (docker / podman)
source "$LIB_DIR/container-runtime.sh"

# Initialize the runtime
init_container_runtime || exit 1

# Default values
BENCHMARK_ROWS=250000

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
         --rows)
            BENCHMARK_ROWS="$2"
            shift 2
               ;;
           --help|-h)
            echo "Usage: $0 [--rows NUM]"
            echo "   --rows NUM  Number of rows for the dataset (default: 2000000)"
            exit 0
               ;;
           *)
            echo -e "${RED}Unknown option: $1${NC}"
            exit 1
               ;;
    esac
done

# Calculate rows suffix (e.g. 2m or 5m)
if [[ "$BENCHMARK_ROWS" -eq 5000000 ]]; then
    SUFFIX="5m"
elif [[ "$BENCHMARK_ROWS" -eq 2000000 ]]; then
    SUFFIX="2m"
else
     # Fallback to raw row count if not 2M or 5M
    if (( BENCHMARK_ROWS % 1000000 == 0 )); then
        SUFFIX="$(( BENCHMARK_ROWS / 1000000 ))m"
    else
        SUFFIX="${BENCHMARK_ROWS}"
    fi
fi
SUFFIX_UPPER=$(echo "$SUFFIX" | tr '[:lower:]' '[:upper:]')


echo ""
echo -e "${GREEN}=============================================${NC}"
echo -e "${GREEN}  Source Data Initialization${NC}"
echo -e "${GREEN}=============================================${NC}"
echo "Settings :"
echo "  Rows: $BENCHMARK_ROWS"
echo ""

# Ensure artifacts directories exist
mkdir -p "$ARTIFACTS_DIR"/{dtpipe,meltano,sling}

# =============================================================================
# Load environment configuration for DB connections (from benchmark.env)
# We source a minimal version here just for the DB connection strings
# The actual containers will use their own copies via environment variables
# =============================================================================

# Run commands in benchmark-test container using the abstracted runtime
# Args: command...
docker_exec_dtpipe() {    COMPOSE_PROJECT_DIR="$SCRIPT_DIR/../config"
     container_compose -p "dtpipe-benchmark" -f docker-compose-benchmark.yml exec benchmark-test bash -c "$*"
}

# =============================================================================
# Step 1: Generate Parquet source data (5M rows) inside benchmark-test container
# =============================================================================
PARQUET_FILE="/bench/artifacts/source_data_${SUFFIX}.parquet"
CSV_FILE="/bench/artifacts/source_data_${SUFFIX}.csv"

echo ""
echo -e "${YELLOW}Step 1: Generating Parquet dataset ($BENCHMARK_ROWS rows)...${NC}"

# Check if file already exists and has enough size
if docker_exec_dtpipe "[ -f '$PARQUET_FILE' ] && [ \$(stat -c%s '$PARQUET_FILE' 2>/dev/null || echo 0) -gt 1000000 ]"; then
    echo -e "${GREEN}Parquet already exists: $PARQUET_FILE (skipping)${NC}"
else
      # Build the dtpipe command to generate data
    local_gen_cmd="dtpipe --input \"generate:$BENCHMARK_ROWS\" \
         --fake \"id:random.guid\" \
         --fake \"name:name.fullName\" \
         --fake \"email:internet.email\" \
         --fake \"amount:finance.amount\" \
         --fake \"country:address.countrycode\" \
         --drop \"GenerateIndex\" \
         --output '$PARQUET_FILE' \
         --no-schema-validation \
         --strategy Recreate"

    echo -e "${YELLOW}Running: dtpipe generate${NC}"
     docker_exec_dtpipe "$local_gen_cmd"
    echo -e "${GREEN}Parquet dataset generated: $PARQUET_FILE${NC}"
fi

# =============================================================================
# Step 2: Generate CSV from Parquet (for file-to-file benchmarks)
# =============================================================================
echo ""
echo -e "${YELLOW}Step 2: CSV export from Parquet...${NC}"

if docker_exec_dtpipe "[ -f '$CSV_FILE' ]"; then
    echo -e "${GREEN}CSV already exists: $CSV_FILE (skipping)${NC}"
else
      local_csv_cmd="dtpipe --input '$PARQUET_FILE' --output '$CSV_FILE'"
    docker_exec_dtpipe "$local_csv_cmd"
    echo -e "${GREEN}CSV generated: $CSV_FILE${NC}"
fi

# =============================================================================
# Step 3: Load data into PostgreSQL
# =============================================================================
echo ""
echo -e "${YELLOW}Step 3: Loading data into PostgreSQL...${NC}"

# We need to source the config for DB connection strings
if [[ -f "$SCRIPT_DIR/../config/benchmark.env" ]]; then
    source "$SCRIPT_DIR/../config/benchmark.env"
fi

local_pg_cmd="dtpipe \
     --input '$PARQUET_FILE' \
     --output \"pg:Host=$DB_POSTGRES_HOST;Port=$DB_POSTGRES_PORT;Database=$DB_POSTGRES_DB;Username=$DB_POSTGRES_USER;Password=$DB_POSTGRES_PASSWORD\" \
     --table 'benchmark_source_${SUFFIX}' \
     --strategy Recreate \
     --pre-exec 'DROP TABLE IF EXISTS benchmark_source_${SUFFIX} CASCADE' \
     --no-schema-validation"

docker_exec_dtpipe "$local_pg_cmd" || {
    echo -e "${RED}Error while loading into PostgreSQL.${NC}"
}

echo -e "${GREEN}PostgreSQL benchmark_source_${SUFFIX} loaded.${NC}"

# =============================================================================
# Step 4: Load data into SQL Server
# =============================================================================
echo ""
echo -e "${YELLOW}Step 4: Loading data into SQL Server...${NC}"

local_mssql_cmd="dtpipe \
     --input '$PARQUET_FILE' \
     --output \"mssql:Server=$DB_MSSQL_HOST,$DB_MSSQL_PORT;Database=$DB_MSSQL_DB;User Id=$DB_MSSQL_USER;Password=$DB_MSSQL_PASSWORD;Encrypt=False\" \
     --table 'benchmark_source_${SUFFIX}' \
     --strategy Recreate \
     --pre-exec \"IF OBJECT_ID('benchmark_source_${SUFFIX}', 'U') IS NOT NULL DROP TABLE benchmark_source_${SUFFIX}\" \
     --no-schema-validation"

docker_exec_dtpipe "$local_mssql_cmd" || {
    echo -e "${RED}Error while loading into SQL Server.${NC}"
}

echo -e "${GREEN}SQL Server benchmark_source_${SUFFIX} loaded.${NC}"

# =============================================================================
# Step 5: Load data into Oracle
# =============================================================================
echo ""
echo -e "${YELLOW}Step 5: Loading data into Oracle...${NC}"

local_oracle_cmd="dtpipe \
     --input '$PARQUET_FILE' \
     --output \"ora:Data Source=$DB_ORACLE_HOST:$DB_ORACLE_PORT/$DB_ORACLE_SERVICE;User Id=$DB_ORACLE_USER;Password=$DB_ORACLE_PASSWORD\" \
     --table 'BENCHMARK_SOURCE_${SUFFIX_UPPER}' \
     --strategy Recreate \
     --pre-exec \"BEGIN EXECUTE IMMEDIATE 'DROP TABLE BENCHMARK_SOURCE_${SUFFIX_UPPER}'; EXCEPTION WHEN OTHERS THEN IF SQLCODE != -942 THEN RAISE; END IF; END;\" \
     --no-schema-validation \
     --insert-mode Bulk"

docker_exec_dtpipe "$local_oracle_cmd" || {
    echo -e "${RED}Error while loading into Oracle.${NC}"
}

echo -e "${GREEN}Oracle BENCHMARK_SOURCE_${SUFFIX_UPPER} loaded.${NC}"

# =============================================================================
# Step 6: Create bench_reader / bench_writer accounts for intra-DB benchmarks (B13-B15)
# bench_reader : read-only access to benchmark_source_* tables
# bench_writer : write access to a dedicated target schema/account
#
# Each DB uses its own DBA account:
#   PostgreSQL  → postgres   (superuser)
#   SQL Server  → sa         (sysadmin)
#   Oracle      → system     (ORACLE_PASSWORD from docker-compose — same as ORACLE_PASSWORD env var)
# =============================================================================
echo ""
echo -e "${YELLOW}Step 6: Creating bench_reader / bench_writer accounts...${NC}"

DB_ORACLE_USER_UPPER=$(echo "${DB_ORACLE_USER:-testuser}" | tr '[:lower:]' '[:upper:]')
DB_ORACLE_READER_UPPER=$(echo "${DB_ORACLE_READER_USER:-bench_reader}" | tr '[:lower:]' '[:upper:]')
DB_ORACLE_WRITER_UPPER=$(echo "${DB_ORACLE_WRITER_USER:-bench_writer}" | tr '[:lower:]' '[:upper:]')
# system password = ORACLE_PASSWORD (set in docker-compose ORACLE_PASSWORD env var)
ORACLE_SYSTEM_PASSWORD="${ORACLE_SYSTEM_PASSWORD:-${DB_ORACLE_PASSWORD:-password}}"

# SQL files are written to ARTIFACTS_DIR on the host, then fed to the DB client via stdin
# or via the volume mount (/bench/artifacts) where available.

# -- PostgreSQL --
# Uses psql client installed in the benchmark-test container.
# Variables are expanded on the host; the SQL is piped via stdin.
cat > "$ARTIFACTS_DIR/.pg_setup_b13.sql" << EOF
DO \$\$ BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = '${DB_POSTGRES_READER_USER:-bench_reader}') THEN
    CREATE ROLE ${DB_POSTGRES_READER_USER:-bench_reader} LOGIN PASSWORD '${DB_POSTGRES_READER_PASSWORD:-password}';
  ELSE
    ALTER ROLE ${DB_POSTGRES_READER_USER:-bench_reader} LOGIN PASSWORD '${DB_POSTGRES_READER_PASSWORD:-password}';
  END IF;
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = '${DB_POSTGRES_WRITER_USER:-bench_writer}') THEN
    CREATE ROLE ${DB_POSTGRES_WRITER_USER:-bench_writer} LOGIN PASSWORD '${DB_POSTGRES_WRITER_PASSWORD:-password}';
  ELSE
    ALTER ROLE ${DB_POSTGRES_WRITER_USER:-bench_writer} LOGIN PASSWORD '${DB_POSTGRES_WRITER_PASSWORD:-password}';
  END IF;
END \$\$;
GRANT CONNECT ON DATABASE ${DB_POSTGRES_DB:-integration} TO ${DB_POSTGRES_READER_USER:-bench_reader};
GRANT CONNECT ON DATABASE ${DB_POSTGRES_DB:-integration} TO ${DB_POSTGRES_WRITER_USER:-bench_writer};
GRANT USAGE ON SCHEMA public TO ${DB_POSTGRES_READER_USER:-bench_reader};
GRANT SELECT ON TABLE benchmark_source_${SUFFIX} TO ${DB_POSTGRES_READER_USER:-bench_reader};
GRANT SELECT ON TABLE benchmark_source_${SUFFIX} TO ${DB_POSTGRES_WRITER_USER:-bench_writer};
CREATE SCHEMA IF NOT EXISTS ${DB_POSTGRES_WRITER_SCHEMA:-bench_tgt};
ALTER SCHEMA ${DB_POSTGRES_WRITER_SCHEMA:-bench_tgt} OWNER TO ${DB_POSTGRES_WRITER_USER:-bench_writer};
GRANT ALL ON SCHEMA ${DB_POSTGRES_WRITER_SCHEMA:-bench_tgt} TO ${DB_POSTGRES_WRITER_USER:-bench_writer};
EOF
if container_exec benchmark-test \
    bash -c "PGPASSWORD='${DB_POSTGRES_PASSWORD:-password}' psql \
      -h '${DB_POSTGRES_HOST:-dtpipe-integ-postgres}' \
      -p '${DB_POSTGRES_PORT:-5432}' \
      -U '${DB_POSTGRES_USER:-postgres}' \
      -d '${DB_POSTGRES_DB:-integration}' \
      -f /bench/artifacts/.pg_setup_b13.sql" 2>&1; then
    echo -e "${GREEN}PostgreSQL: bench_reader + bench_writer ready.${NC}"
else
    echo -e "${RED}PostgreSQL Step 6 failed — B13 benchmarks will be skipped.${NC}"
fi

# -- SQL Server --
# bench_writer gets db_owner (covers CREATE TABLE + full DML in any schema).
# bench_reader gets SELECT on the specific source table only.
# Uses mssql-tools18 with sqlcmd installed in the benchmark-test container.
# Note: bcp from mssql-tools18 uses ODBC Driver 18 internally — the prefix
# "[Microsoft][ODBC Driver 18 for SQL Server]" on errors is normal, not a problem.
cat > "$ARTIFACTS_DIR/.mssql_setup_b13.sql" << EOF
IF NOT EXISTS (SELECT name FROM sys.server_principals WHERE name = '${DB_MSSQL_READER_USER:-bench_reader}')
    CREATE LOGIN [${DB_MSSQL_READER_USER:-bench_reader}] WITH PASSWORD = '${DB_MSSQL_READER_PASSWORD:-BenchReader1!}';
GO
IF NOT EXISTS (SELECT name FROM sys.database_principals WHERE name = '${DB_MSSQL_READER_USER:-bench_reader}')
    CREATE USER [${DB_MSSQL_READER_USER:-bench_reader}] FOR LOGIN [${DB_MSSQL_READER_USER:-bench_reader}];
GO
GRANT SELECT ON dbo.benchmark_source_${SUFFIX} TO [${DB_MSSQL_READER_USER:-bench_reader}];
GO
IF NOT EXISTS (SELECT name FROM sys.server_principals WHERE name = '${DB_MSSQL_WRITER_USER:-bench_writer}')
    CREATE LOGIN [${DB_MSSQL_WRITER_USER:-bench_writer}] WITH PASSWORD = '${DB_MSSQL_WRITER_PASSWORD:-BenchWriter1!}';
GO
IF NOT EXISTS (SELECT name FROM sys.database_principals WHERE name = '${DB_MSSQL_WRITER_USER:-bench_writer}')
    CREATE USER [${DB_MSSQL_WRITER_USER:-bench_writer}] FOR LOGIN [${DB_MSSQL_WRITER_USER:-bench_writer}];
GO
ALTER ROLE db_owner ADD MEMBER [${DB_MSSQL_WRITER_USER:-bench_writer}];
GO
EOF
if container_exec benchmark-test \
    sqlcmd -C \
      -S "${DB_MSSQL_HOST:-dtpipe-integ-mssql},${DB_MSSQL_PORT:-1433}" \
      -U "${DB_MSSQL_USER:-sa}" \
      -P "${DB_MSSQL_PASSWORD:-Password123!}" \
      -d "${DB_MSSQL_DB:-master}" \
      -i /bench/artifacts/.mssql_setup_b13.sql 2>&1; then
    echo -e "${GREEN}SQL Server: bench_reader + bench_writer ready.${NC}"
else
    echo -e "${RED}SQL Server Step 6 failed — B14 benchmarks will be skipped.${NC}"
fi

# -- Oracle: connect as system (DBA), not testuser --
# system password = ORACLE_PASSWORD from docker-compose (ORACLE_SYSTEM_PASSWORD override supported)
cat > "$ARTIFACTS_DIR/.oracle_setup_b13.sql" << EOF
BEGIN
  EXECUTE IMMEDIATE 'CREATE USER ${DB_ORACLE_READER_UPPER} IDENTIFIED BY ${DB_ORACLE_READER_PASSWORD:-password}';
EXCEPTION WHEN OTHERS THEN
  IF SQLCODE = -1920 THEN
    EXECUTE IMMEDIATE 'ALTER USER ${DB_ORACLE_READER_UPPER} IDENTIFIED BY ${DB_ORACLE_READER_PASSWORD:-password}';
  ELSE RAISE; END IF;
END;
/
BEGIN
  EXECUTE IMMEDIATE 'CREATE USER ${DB_ORACLE_WRITER_UPPER} IDENTIFIED BY ${DB_ORACLE_WRITER_PASSWORD:-password}';
EXCEPTION WHEN OTHERS THEN
  IF SQLCODE = -1920 THEN
    EXECUTE IMMEDIATE 'ALTER USER ${DB_ORACLE_WRITER_UPPER} IDENTIFIED BY ${DB_ORACLE_WRITER_PASSWORD:-password}';
  ELSE RAISE; END IF;
END;
/
GRANT CREATE SESSION TO ${DB_ORACLE_READER_UPPER};
GRANT SELECT ON ${DB_ORACLE_USER_UPPER}.BENCHMARK_SOURCE_${SUFFIX_UPPER} TO ${DB_ORACLE_READER_UPPER};
GRANT CREATE SESSION, CREATE TABLE, CREATE SEQUENCE, UNLIMITED TABLESPACE TO ${DB_ORACLE_WRITER_UPPER};
EXIT;
EOF
if container_exec benchmark-test \
    sqlplus -S "system/${ORACLE_SYSTEM_PASSWORD}@//${DB_ORACLE_HOST:-dtpipe-integ-oracle}:${DB_ORACLE_PORT:-1521}/${DB_ORACLE_SERVICE:-FREEPDB1}" \
    "@/bench/artifacts/.oracle_setup_b13.sql" 2>&1; then
    echo -e "${GREEN}Oracle: bench_reader + bench_writer ready.${NC}"
else
    echo -e "${RED}Oracle Step 6 failed — B15 benchmarks will be skipped.${NC}"
fi

echo ""
echo -e "${GREEN}=============================================${NC}"
echo -e "${GREEN}  Initialization completed!${NC}"
echo -e "${GREEN}=============================================${NC}"