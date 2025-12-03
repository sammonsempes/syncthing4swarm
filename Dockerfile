FROM syncthing/syncthing:2.0.10

COPY entrypoint.sh /entrypoint.sh
RUN chmod 0555 /entrypoint.sh

EXPOSE 8384 22000/tcp 22000/udp 21027/udp

ENTRYPOINT ["/bin/sh", "/entrypoint.sh"]
CMD ["/bin/syncthing", "serve"]
