FROM archlinux:latest

ARG PACMAN_REPO_NAME PACMAN_REPO_URL GPG_KEY_ID

COPY key.asc .

# expect is required by aurutils for non-interactive sessions
# pacman-contrib for paccache, pyalpm for auv.py
RUN cp /etc/pacman.conf pacman.conf && \
    echo -e "\n[$PACMAN_REPO_NAME]\nServer = $PACMAN_REPO_URL" >> pacman.conf && \
    pacman-key --init && \
    pacman-key --populate archlinux && \
    pacman-key --add key.asc && \
    rm key.asc && \
    pacman-key --lsign-key "$GPG_KEY_ID" && \
    pacman -Syu --config pacman.conf --noconfirm base-devel git expect pacman-contrib pyalpm sudo aurutils && \
    rm -r /var/cache/* pacman.conf

# Should match UID/GID of GitHub Actions runners
RUN groupadd -g 1001 builder && \
    useradd -m -u 1001 -g builder -G alpm builder && \
    echo 'builder ALL=(ALL:ALL) NOPASSWD: ALL' >> /etc/sudoers

USER builder
RUN echo -e 'retry = 5\nretry-delay = 2\nretry-all-errors\nconnect-timeout = 10' > ~/.curlrc
