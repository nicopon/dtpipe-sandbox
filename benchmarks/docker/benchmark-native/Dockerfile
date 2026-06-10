FROM ubuntu:22.04

# Avoid interactive prompts during apt-get
ENV DEBIAN_FRONTEND=noninteractive

# Install core dependencies and postgresql-client
RUN apt-get update && apt-get install -y \
    curl \
    gnupg2 \
    apt-transport-https \
    ca-certificates \
    unzip \
    libaio1 \
    postgresql-client \
    time \
    && rm -rf /var/lib/apt/lists/*

# Install Microsoft SQL Server tools (bcp and sqlcmd)
RUN curl -fsSL https://packages.microsoft.com/keys/microsoft.asc | gpg --dearmor -o /usr/share/keyrings/microsoft-prod.gpg \
    && echo "deb [arch=amd64,arm64 signed-by=/usr/share/keyrings/microsoft-prod.gpg] https://packages.microsoft.com/ubuntu/22.04/prod/ jammy main" > /etc/apt/sources.list.d/mssql-release.list \
    && apt-get update \
    && ACCEPT_EULA=Y apt-get install -y mssql-tools18 unixodbc-dev \
    && rm -rf /var/lib/apt/lists/*

# Install Oracle Instant Client (basic, sqlplus, and tools for sqlldr)
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

# Set Oracle environment paths and add tools to PATH
ENV ORACLE_HOME=/opt/oracle/instantclient
ENV LD_LIBRARY_PATH=$ORACLE_HOME
ENV PATH=$ORACLE_HOME:/opt/mssql-tools18/bin:$PATH

# Configure the dynamic linker
RUN echo $ORACLE_HOME > /etc/ld.so.conf.d/oracle-instantclient.conf && ldconfig

# Workdir mapping target
WORKDIR /bench

CMD ["bash", "-c", "while true; do sleep 3600; done"]
