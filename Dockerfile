FROM crystallang/crystal:0.36.0-alpine as builder
WORKDIR /tmp
COPY shard.yml shard.lock ./
RUN shards install --production
COPY src/ src/
RUN shards build --release --production --static
RUN strip bin/*

FROM scratch
USER 2:2
COPY --from=builder /tmp/bin/amqpcat /amqpcat
ENTRYPOINT ["/amqpcat"]
