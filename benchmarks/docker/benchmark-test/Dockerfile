FROM ubuntu:22.04

# Avoid interactive prompts during apt-get
ENV DEBIAN_FRONTEND=noninteractive

# 1. Install core dependencies, python, git, and unixodbc
RUN apt-get update && apt-get install -y \
    curl \
    gnupg2 \
    apt-transport-https \
    ca-certificates \
    unzip \
    libaio1 \
    postgresql-client \
    jq \
    time \
    git \
    gcc \
    unixodbc \
    unixodbc-dev \
    libpq-dev \
    python3 \
    python3-pip \
    python3-venv \
    libicu-dev \
    && rm -rf /var/lib/apt/lists/*

# 2. Install Microsoft SQL Server tools (bcp and sqlcmd)
RUN curl -fsSL https://packages.microsoft.com/keys/microsoft.asc | gpg --dearmor -o /usr/share/keyrings/microsoft-prod.gpg \
    && echo "deb [arch=amd64,arm64 signed-by=/usr/share/keyrings/microsoft-prod.gpg] https://packages.microsoft.com/ubuntu/22.04/prod/ jammy main" > /etc/apt/sources.list.d/mssql-release.list \
    && apt-get update \
    && ACCEPT_EULA=Y apt-get install -y mssql-tools18 unixodbc-dev \
    && rm -rf /var/lib/apt/lists/*

# 3. Install Oracle Instant Client (basic, sqlplus, and tools for sqlldr)
RUN mkdir -p /opt/oracle
WORKDIR /opt/oracle
RUN ARCH=$(uname -m) && \
    if [ "$ARCH" = "x86_64" ]; then \
        ORACLE_ARCH="x64"; \
        ORACLE_VER="2114000"; \
        ORACLE_FILE_VER="21.14.0.0.0"; \
    else \
        ORACLE_ARCH="arm64"; \
        ORACLE_VER="1919000"; \
        ORACLE_FILE_VER="19.19.0.0.0"; \
    fi && \
    curl -fsSL -o basic.zip "https://download.oracle.com/otn_software/linux/instantclient/${ORACLE_VER}/instantclient-basic-linux.${ORACLE_ARCH}-${ORACLE_FILE_VER}dbru.zip" && \
    curl -fsSL -o sqlplus.zip "https://download.oracle.com/otn_software/linux/instantclient/${ORACLE_VER}/instantclient-sqlplus-linux.${ORACLE_ARCH}-${ORACLE_FILE_VER}dbru.zip" && \
    curl -fsSL -o tools.zip "https://download.oracle.com/otn_software/linux/instantclient/${ORACLE_VER}/instantclient-tools-linux.${ORACLE_ARCH}-${ORACLE_FILE_VER}dbru.zip" && \
    unzip basic.zip && \
    unzip sqlplus.zip && \
    unzip tools.zip && \
    rm *.zip && \
    ln -s /opt/oracle/instantclient_* /opt/oracle/instantclient

# Configure Oracle environment paths
ENV ORACLE_HOME=/opt/oracle/instantclient
ENV LD_LIBRARY_PATH=$ORACLE_HOME
ENV PATH=$ORACLE_HOME:/opt/mssql-tools18/bin:$PATH

# Configure the dynamic linker
RUN echo $ORACLE_HOME > /etc/ld.so.conf.d/oracle-instantclient.conf && ldconfig

# 4. Download and install dtpipe standalone binary from GitHub releases
ARG DTPIPE_VERSION=v1.4.0
RUN ARCH=$(uname -m) && \
    if [ "$ARCH" = "x86_64" ]; then DTPIPE_ARCH="x64"; else DTPIPE_ARCH="arm64"; fi && \
    curl -fsSL -o dtpipe.tar.gz "https://github.com/nicopon/dtpipe/releases/download/${DTPIPE_VERSION}/dtpipe-linux-${DTPIPE_ARCH}.tar.gz" && \
    tar -zxvf dtpipe.tar.gz && \
    chmod +x dtpipe && \
    mv dtpipe /usr/local/bin/dtpipe && \
    rm dtpipe.tar.gz

# 5. Install Sling & ingestr (native Go binaries)
ARG SLING_VERSION=v1.5.20
RUN ARCH=$(uname -m) && \
    if [ "$ARCH" = "x86_64" ]; then SLING_ARCH="linux_amd64"; else SLING_ARCH="linux_arm64"; fi && \
    curl -fsSL -o sling.tar.gz "https://github.com/slingdata-io/sling-cli/releases/download/${SLING_VERSION}/sling_${SLING_ARCH}.tar.gz" && \
    tar -zxvf sling.tar.gz && \
    mv sling /usr/local/bin/sling && \
    rm sling.tar.gz

ARG INGESTR_VERSION=v1.0.37
RUN ARCH=$(uname -m) && \
    if [ "$ARCH" = "x86_64" ]; then INGESTR_ARCH="x86_64"; else INGESTR_ARCH="arm64"; fi && \
    curl -fsSL -o ingestr.tar.gz "https://github.com/bruin-data/ingestr/releases/download/${INGESTR_VERSION}/ingestr_Linux_${INGESTR_ARCH}.tar.gz" && \
    tar -zxvf ingestr.tar.gz && \
    chmod +x ingestr && \
    mv ingestr /usr/local/bin/ingestr && \
    rm ingestr.tar.gz

# 6. Initialize isolated Python virtual environments
RUN python3 -m venv /opt/venv/pandas && \
    /opt/venv/pandas/bin/pip install --no-cache-dir pyarrow pandas psycopg2-binary pyodbc oracledb sqlalchemy pymssql duckdb

RUN python3 -m venv /opt/venv/meltano && \
    /opt/venv/meltano/bin/pip install --no-cache-dir meltano duckdb

# Set workdir mapping target
WORKDIR /bench

CMD ["bash", "-c", "while true; do sleep 3600; done"]
