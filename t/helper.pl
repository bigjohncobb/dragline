use strict;
use warnings;
use utf8;

use lib 'local/lib/perl5';

use Exporter 'import';
our @EXPORT = qw(app db admin_ua analyst_ua extract_csrf);

use FindBin;
use Test::Mojo;
use Crypt::Passphrase;
use Dragline::DB;

BEGIN {
    $ENV{DRAGLINE_SECRET}      = 'x' x 64;
    $ENV{DRAGLINE_DB}          = ':memory:';
    $ENV{DRAGLINE_MINION_DB}   = ':memory:';
}

# Cache get_dbh connections so :memory: is shared across the process
BEGIN {
    no warnings 'redefine';
    my %cache;
    my $orig = \&Dragline::DB::get_dbh;
    *Dragline::DB::get_dbh = sub {
        my ($path) = @_;
        return $cache{$path} if exists $cache{$path};
        my $dbh = $orig->($path);
        $cache{$path} = $dbh;
        return $dbh;
    };
}

# Load dragline.pl without executing the Mojolicious::Commands->start_app line
{
    my $path = "$FindBin::Bin/../dragline.pl";
    open my $fh, '<', $path or die "Cannot open $path: $!";
    my $src = do { local $/; <$fh> };
    close $fh;
    # Remove the shebang and the final start_app call
    $src =~ s/^#!.*\n//;
    $src =~ s/\npackage main;\s*\nuse Mojolicious::Commands;\s*\nMojolicious::Commands->start_app\('Dragline'\);\s*\n//s;
    eval $src;
    die "Failed to load dragline.pl: $@" if $@;
}

# Initialise schema by calling the same get_dbh the app will use
my $_dbh = Dragline::DB::get_dbh(':memory:');

# Insert test users with a known password
my $pp   = Crypt::Passphrase->new(encoder => 'Bcrypt');
my $hash = $pp->hash_password('testpass123');

# Remove placeholder admin from seed data
$_dbh->do(q{DELETE FROM users WHERE username_lower = 'admin'});

$_dbh->do(
    q{INSERT INTO users (id, username, username_lower, password_hash, role, active, created_at, updated_at)
      VALUES (?, ?, ?, ?, ?, 1, datetime('now'), datetime('now'))},
    undef,
    '00000000-0000-0000-0000-000000000001',
    'admin',
    'admin',
    $hash,
    'admin',
);

$_dbh->do(
    q{INSERT INTO users (id, username, username_lower, password_hash, role, active, created_at, updated_at)
      VALUES (?, ?, ?, ?, ?, 1, datetime('now'), datetime('now'))},
    undef,
    '00000000-0000-0000-0000-000000000002',
    'analyst',
    'analyst',
    $hash,
    'analyst',
);

# Single app instance for all tests
my $_app = Dragline->new;
$_app->sessions->secure(0);  # Test::Mojo uses HTTP, not HTTPS

sub app  { $_app }
sub db   { $_dbh }

sub extract_csrf {
    my ($t) = @_;
    my $html = $t->tx->res->body // '';
    $html =~ /name="_csrf_token" value="([^"]+)"/ or die "No CSRF token found in response";
    return $1;
}

sub admin_ua {
    my ($t) = @_;
    $t //= Test::Mojo->new(app());
    $t->get_ok('/login')->status_is(200);
    my $csrf = extract_csrf($t);
    $t->post_ok('/login' => form => {
        username    => 'admin',
        password    => 'testpass123',
        _csrf_token => $csrf,
    })->status_is(302);
    return $t;
}

sub analyst_ua {
    my ($t) = @_;
    $t //= Test::Mojo->new(app());
    $t->get_ok('/login')->status_is(200);
    my $csrf = extract_csrf($t);
    $t->post_ok('/login' => form => {
        username    => 'analyst',
        password    => 'testpass123',
        _csrf_token => $csrf,
    })->status_is(302);
    return $t;
}

1;
