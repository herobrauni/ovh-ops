# syntax=docker/dockerfile:1
FROM golang:1.27-alpine@sha256:70bd7ddea8b6cbe5d6943cde279d6b67feb10cc924fb9100d1d8757c1575b280 AS builder
WORKDIR /src
COPY go.mod main.go main_test.go ./
RUN go test -v ./... && CGO_ENABLED=0 GOOS=linux go build -trimpath -ldflags="-s -w" -o /stalwart-alias-bridge .

FROM gcr.io/distroless/static-debian12:nonroot@sha256:afa5c872c891853ca7fcf1f12c3edb23f7eeef36189728842dd51042ff57f7ab
COPY --from=builder /stalwart-alias-bridge /stalwart-alias-bridge
USER 1000:1000
EXPOSE 8080
ENTRYPOINT ["/stalwart-alias-bridge"]
