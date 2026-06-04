FROM archlinux:base-devel

ARG UID GID

# expect is required by aurutils for non-interactive sessions
# pacman-contrib for paccache, pyalpm for auv.py
RUN pacman-key --init && \
    pacman-key --populate archlinux && \
    pacman -Syu --noconfirm --needed git expect pacman-contrib pyalpm sudo && \
    groupadd -g $GID builder && \
    useradd -m -u $UID -g builder -G alpm builder && \
    echo 'builder ALL=(ALL:ALL) NOPASSWD: ALL' >> /etc/sudoers && \
    sudo -Hu builder bash -eo pipefail -c '\
        cd ~; \
        curl -sSfL https://aur.archlinux.org/cgit/aur.git/snapshot/aurutils.tar.gz | tar -xzf -; \
        makepkg -D aurutils -si --noconfirm; \
        rm -r aurutils; \
        echo -e "retry = 5\nretry-delay = 2\nretry-all-errors\nconnect-timeout = 10" > .curlrc' && \
    rm -r /var/cache/*

USER builder
