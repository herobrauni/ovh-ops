# syntax=docker/dockerfile:1
FROM golang:1.25-alpine AS builder
WORKDIR /src
COPY go.mod main.go main_test.go ./
RUN go test -v ./... && CGO_ENABLED=0 GOOS=linux go build -trimpath -ldflags="-s -w" -o /stalwart-alias-bridge .

FROM gcr.io/distroless/static-debian12:nonroot
COPY --from=builder /stalwart-alias-bridge /stalwart-alias-bridge
USER 1000:1000
EXPOSE 8080
ENTRYPOINT ["/stalwart-alias-bridge"]
