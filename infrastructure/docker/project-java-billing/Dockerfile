FROM maven:3.9 AS builder
WORKDIR /app
COPY pom.xml ./
RUN mvn dependency:go-offline
COPY . .
RUN mvn package -DskipTests

FROM openjdk:17-slim
RUN apt-get update && apt-get install -y --no-install-recommends curl && rm -rf /var/lib/apt/lists/*
ENV PORT=4004
WORKDIR /app
COPY --from=builder /app/target/*.jar /app/app.jar

EXPOSE 4004
HEALTHCHECK --interval=30s --timeout=3s --start-period=10s --retries=3 CMD curl -f http://localhost:4004/ || exit 1
RUN groupadd -r appgroup && useradd -r -g appgroup appuser
RUN chown -R appuser:appgroup /app
USER appuser

ENTRYPOINT ["java", "-jar", "/app/app.jar"]
