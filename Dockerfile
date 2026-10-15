# syntax=docker/dockerfile:1

FROM golang:1.25-bookworm AS builder
WORKDIR /app
COPY go.mod go.sum ./
RUN go mod download
COPY . .
ARG VERSION=dev
RUN go build -trimpath -ldflags="-s -w -X main.version=${VERSION}" -o /out/server ./cmd/server

FROM builder AS test
RUN go test -race ./...

FROM gcr.io/distroless/base-debian12:nonroot
COPY --from=builder /out/server /server
ENV MODEL_DIR=/models PORT=8456
USER nonroot:nonroot
EXPOSE 8456
ENTRYPOINT ["/server"]
