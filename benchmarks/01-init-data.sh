#!/usr/bin/env bash
# =============================================================================
# 01-init-data.sh - Source data initialization for benchmark
# 
# Generates a 5M row dataset via dtpipe (in benchmark-dtpipe container)
# Loads data into PostgreSQL, SQL Server and Oracle
# 
# IMPORTANT: Everything runs inside containers, nothing on the host
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/config/docker-compose-benchmark.yml"
ARTIFACTS_DIR="$SCRIPT_DIR/artifacts"

# Default values
BENCHMARK_ROWS=2000000

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

# Function to docker exec and run commands in benchmark-dtpipe container
# Args: command...
docker_exec_dtpipe() {
      (cd "$SCRIPT_DIR/config" && docker compose -f docker-compose-benchmark.yml \
        exec benchmark-dtpipe bash -c 'export PATH="${PATH}:/root/.dotnet/tools"; '"$*"
)
}

# =============================================================================
# Step 1: Generate Parquet source data (5M rows) inside benchmark-dtpipe container
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
if [[ -f "$SCRIPT_DIR/config/benchmark.env" ]]; then
    source "$SCRIPT_DIR/config/benchmark.env"
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

echo ""
echo -e "${GREEN}=============================================${NC}"
echo -e "${GREEN}  Initialization completed!${NC}"
echo -e "${GREEN}=============================================${NC}"