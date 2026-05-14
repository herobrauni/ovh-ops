FROM alpine:3.22.0

RUN apk add --no-cache nfs-utils

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

EXPOSE 2049

ENTRYPOINT ["/entrypoint.sh"]
