FROM mcr.microsoft.com/dotnet/sdk:8 AS builder
WORKDIR /app
COPY *.csproj ./
RUN dotnet restore
COPY . .
RUN dotnet publish -c Release -o /app/publish

FROM mcr.microsoft.com/dotnet/aspnet:8
ENV PORT=4005
ENV ASPNETCORE_URLS=http://+:4005
WORKDIR /app
COPY --from=builder /app/publish .

EXPOSE 4005
HEALTHCHECK --interval=30s --timeout=3s --start-period=10s --retries=3 CMD curl -f http://localhost:4005/ || exit 1
RUN useradd -m -s /bin/bash appuser
RUN chown -R appuser:appuser /app
USER appuser

ENTRYPOINT ["dotnet", "/app/dotnet-reporting.dll"]
