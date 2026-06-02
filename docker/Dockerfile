FROM archlinux:latest

COPY aurutils-*.pkg.tar.zst ./

# expect is required by aurutils for non-interactive sessions
# pacman-contrib for paccache, pyalpm for repo-list
RUN pacman-key --init && \
    pacman-key --populate archlinux && \
    pacman -Syu --noconfirm base-devel git expect pacman-contrib pyalpm sudo && \
    pacman -U --noconfirm aurutils-*.pkg.tar.zst && \
    rm aurutils-*.pkg.tar.zst && \
    rm -r /var/cache/*

# Should match UID/GID of GitHub Actions runners
RUN groupadd -g 1001 builder && \
    useradd -m -u 1001 -g builder -G alpm builder && \
    echo 'builder ALL=(ALL:ALL) NOPASSWD: ALL' >> /etc/sudoers

USER builder
RUN echo -e 'retry = 5\nretry-delay = 2\nretry-all-errors\nconnect-timeout = 10' > ~/.curlrc
