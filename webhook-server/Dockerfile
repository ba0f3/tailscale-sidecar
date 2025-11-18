# Build stage
FROM golang:1.25-alpine AS builder

WORKDIR /build

# Copy go mod files first (for better caching)
COPY go.mod go.sum* ./

# Copy source code
COPY main.go .

# Download dependencies and build
RUN go mod tidy && \
    go mod download && \
    CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -o webhook-server main.go

# Runtime stage
FROM alpine:latest

RUN apk --no-cache add ca-certificates

WORKDIR /app

COPY --from=builder /build/webhook-server .

EXPOSE 8443

ENTRYPOINT ["./webhook-server"]

