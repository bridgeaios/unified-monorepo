FROM golang:1.21-alpine AS builder
WORKDIR /app
COPY go.mod go.sum ./
RUN go mod download
COPY . .
RUN go build -o /app/bin/go-monitor .

FROM alpine:3.18
RUN apk --no-cache add ca-certificates
ENV PORT=4002
WORKDIR /app
COPY --from=builder /app/bin/go-monitor /app/go-monitor

EXPOSE 4002
HEALTHCHECK --interval=30s --timeout=3s --start-period=10s --retries=3 CMD wget --no-verbose --tries=1 --spider http://localhost:4002/
RUN addgroup -S appgroup && adduser -S appuser -G appgroup
RUN chown -R appuser:appgroup /app
USER appuser

CMD ["/app/go-monitor"]
