FROM golang:1.26-alpine AS builder

WORKDIR /app

COPY go.mod go.sum ./
RUN go mod download

COPY main.go .
RUN CGO_ENABLED=0 go build -o controller .

FROM alpine:latest

RUN apk add --no-cache nftables iproute2

COPY --from=builder /app/controller /app/controller

EXPOSE 8080

CMD ["/app/controller"]