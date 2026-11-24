FROM rust:1.75 AS builder
WORKDIR /app
COPY Cargo.toml Cargo.lock ./
RUN cargo fetch
COPY . .
RUN cargo build --release

FROM alpine:3.18
RUN apk --no-cache add ca-certificates
ENV PORT=4003
WORKDIR /app
COPY --from=builder /app/target/release/rust-worker /app/rust-worker

EXPOSE 4003
HEALTHCHECK --interval=30s --timeout=3s --start-period=10s --retries=3 CMD wget --no-verbose --tries=1 --spider http://localhost:4003/
RUN addgroup -S appgroup && adduser -S appuser -G appgroup
RUN chown -R appuser:appgroup /app
USER appuser

CMD ["/app/rust-worker"]
