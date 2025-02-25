FROM golang:1.23-bookworm AS builder

ARG DEBIAN_FRONTEND=noninteractive
ARG GOARCH=''

WORKDIR /workspace

# Copy the Go Modules manifests
COPY go.mod go.mod
COPY go.sum go.sum

# cache deps before building and copying source so that we don't need to re-download as much
# and so that source changes don't invalidate our downloaded layer
RUN go mod download

COPY cmd cmd
COPY html html
COPY pb pb
COPY *.go ./
COPY Makefile ./

ARG TARGETOS
ARG TARGETARCH

# Run unit tests first
RUN make unit-test

# Build
ARG METALBOND_VERSION
RUN CGO_ENABLED=0 GOOS=$TARGETOS GOARCH=$TARGETARCH go build -buildvcs=false -ldflags "-s -w -X github.com/ironcore-dev/metalbond.METALBOND_VERSION=$METALBOND_VERSION" -o metalbond cmd/cmd.go

FROM debian:bookworm-slim AS metalbond

RUN apt-get update && apt-get install -y iproute2 ethtool wget adduser inetutils-ping && rm -rf /var/lib/apt/lists/*
COPY --from=builder /workspace/metalbond /usr/sbin/metalbond
COPY --from=builder /workspace/html /usr/share/metalbond/html

RUN echo '254    metalbond' >> "/etc/iproute2/rt_protos"
