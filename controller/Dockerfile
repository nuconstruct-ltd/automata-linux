FROM rust:alpine AS builder

WORKDIR /app

# Install musl-dev for compilation
RUN apk add --no-cache musl-dev

# Copy manifests
COPY Cargo.toml .
# Create dummy main to cache dependencies
RUN mkdir src && echo "fn main() {}" > src/main.rs
RUN cargo build --release

# Copy actual source
COPY src src
# Touch main.rs to force rebuild
RUN touch src/main.rs
RUN cargo build --release

FROM alpine:latest

WORKDIR /app

# Install nftables
RUN apk add --no-cache nftables

# Copy binary
COPY --from=builder /app/target/release/controller /app/controller

# Expose port
EXPOSE 8080

CMD ["/app/controller"]
