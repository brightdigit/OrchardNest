apt update
apt -y full-upgrade
apt -y tmux supervisor postgresql nginx zsh
apt -y install \
          binutils \
          git \
          gnupg2 \
          libc6-dev \
          libcurl4 \
          libedit2 \
          libgcc-9-dev \
          libpython2.7 \
          libsqlite3-0 \
          libstdc++-9-dev \
          libxml2 \
          libz3-dev \
          pkg-config \
          tzdata \
          zlib1g-dev

sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" "" --unattended
curl https://swift.org/builds/swift-5.2.5-release/ubuntu2004/swift-5.2.5-RELEASE/swift-5.2.5-RELEASE-ubuntu20.04.tar.gz | tar xzf - -C /usr/share/
mv /usr/share/swift-5.2.5-RELEASE-ubuntu20.04 /usr/share/swift
export PATH=/usr/share/swift/usr/bin:"${PATH}"

# download swift

# create db and user with password