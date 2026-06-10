FROM mcr.microsoft.com/dotnet/sdk:latest

RUN dotnet tool install -g dtpipe 2>/dev/null || true

ENV PATH="${PATH}:/root/.dotnet/tools"

WORKDIR /bench
CMD ["bash", "-c", "while true; do sleep 3600; done"]
