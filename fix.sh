sudo tee /etc/dpkg/dpkg.cfg.d/01_nodoc > /dev/null << 'EOF'
path-exclude /usr/share/doc/*
path-exclude /usr/share/man/*
path-exclude /usr/share/info/*
EOF
