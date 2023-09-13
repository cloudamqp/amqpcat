FROM 84codes/crystal:latest-alpine AS builder

WORKDIR /tmp
COPY shard.yml shard.lock ./
RUN shards install --production
COPY src/ src/
RUN shards build --release --production --static && strip bin/*

FROM alpine:latest
USER 2:2
COPY --from=builder /tmp/bin/amqpcat /amqpcat
ENTRYPOINT ["/amqpcat"]
