package Dragline::SSRF;
use strict;
use warnings;
use utf8;

use Socket qw(inet_aton AF_INET);

our $VERSION = '0.1.0';

my @ALLOWED_PORTS = (80, 443, 8080, 8443);

# Returns (1, undef) if safe, (0, "reason") if blocked
sub validate {
    my ($url) = @_;

    unless ($url =~ m{^https?://}i) {
        return (0, 'Only HTTP and HTTPS schemes are allowed');
    }

    my ($host, $port);
    if ($url =~ m{^https?://([^/:?\#]+)(?::(\d+))?}i) {
        $host = $1;
        $port = $2;
    } else {
        return (0, 'Could not parse URL host');
    }

    if (defined $port && $port ne '') {
        unless (grep { $_ == $port } @ALLOWED_PORTS) {
            return (0, "Port $port is not allowed");
        }
    }

    # Check for IPv6 loopback and link-local before DNS resolution
    if ($host =~ /^\[?::1\]?$/) {
        return (0, 'IPv6 loopback address is blocked');
    }
    if ($host =~ /^\[?fe[89ab][0-9a-f]:/i) {
        return (0, 'IPv6 link-local address is blocked');
    }
    if ($host =~ /^\[?f[cd][0-9a-f]{2}:/i) {
        return (0, 'IPv6 ULA address is blocked');
    }

    # Explicit metadata endpoint check
    if ($host eq '169.254.169.254') {
        return (0, 'Cloud metadata endpoint is blocked');
    }

    # Resolve hostname to IP
    my $packed_ip = inet_aton($host);
    unless (defined $packed_ip) {
        return (0, 'DNS resolution failed');
    }

    my $ip = join('.', unpack('C4', $packed_ip));

    # Check private/reserved IPv4 ranges
    my @octets = split /\./, $ip;

    # 127.0.0.0/8 — loopback
    if ($octets[0] == 127) {
        return (0, 'DNS resolves to private address');
    }

    # 10.0.0.0/8 — RFC 1918
    if ($octets[0] == 10) {
        return (0, 'DNS resolves to private address');
    }

    # 172.16.0.0/12 — RFC 1918
    if ($octets[0] == 172 && $octets[1] >= 16 && $octets[1] <= 31) {
        return (0, 'DNS resolves to private address');
    }

    # 192.168.0.0/16 — RFC 1918
    if ($octets[0] == 192 && $octets[1] == 168) {
        return (0, 'DNS resolves to private address');
    }

    # 169.254.0.0/16 — link-local
    if ($octets[0] == 169 && $octets[1] == 254) {
        return (0, 'DNS resolves to private address');
    }

    # 100.64.0.0/10 — CGNAT
    if ($octets[0] == 100 && $octets[1] >= 64 && $octets[1] <= 127) {
        return (0, 'DNS resolves to private address');
    }

    return (1, undef);
}

1;
