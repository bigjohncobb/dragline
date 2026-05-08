use strict;
use warnings;
use utf8;

use Test::More;
use Test::Mojo;
use FindBin;
require "$FindBin::Bin/helper.pl";

my $t = Test::Mojo->new(app());

subtest 'Login with correct credentials succeeds' => sub {
    $t->get_ok('/login')->status_is(200);
    my $csrf = extract_csrf($t);
    $t->post_ok('/login' => form => {
        username    => 'admin',
        password    => 'testpass123',
        _csrf_token => $csrf,
    })->status_is(302)->header_like(Location => qr{^/});
};

subtest 'Login with wrong password fails' => sub {
    my $ua = Test::Mojo->new(app());
    $ua->get_ok('/login')->status_is(200);
    my $csrf = extract_csrf($ua);
    $ua->post_ok('/login' => form => {
        username    => 'admin',
        password    => 'wrongpassword',
        _csrf_token => $csrf,
    })->status_is(401);
    like($ua->tx->res->body, qr/Invalid username or password/i, 'Error message shown');
};

subtest 'Login with nonexistent user fails' => sub {
    my $ua = Test::Mojo->new(app());
    $ua->get_ok('/login')->status_is(200);
    my $csrf = extract_csrf($ua);
    $ua->post_ok('/login' => form => {
        username    => 'nobody',
        password    => 'testpass123',
        _csrf_token => $csrf,
    })->status_is(401);
    like($ua->tx->res->body, qr/Invalid username or password/i, 'Error message shown');
};

subtest 'Session persists' => sub {
    my $ua = admin_ua();
    $ua->get_ok('/')->status_is(200);
    unlike($ua->tx->res->body, qr/Please log in/i, 'Not redirected to login');
};

subtest 'Logout clears session' => sub {
    my $ua = admin_ua();
    $ua->get_ok('/logout')->status_is(302)->header_like(Location => qr{/login});
    $ua->get_ok('/')->status_is(302)->header_like(Location => qr{/login});
};

subtest 'Rate limit after 5 failed logins' => sub {
    my $ua = Test::Mojo->new(app());
    # Clear any previous failed attempts from other subtests
    db()->do(q{DELETE FROM login_attempts});
    for my $i (1 .. 5) {
        $ua->get_ok('/login')->status_is(200);
        my $csrf = extract_csrf($ua);
        $ua->post_ok('/login' => form => {
            username    => 'admin',
            password    => 'wrong',
            _csrf_token => $csrf,
        })->status_is(401);
    }
    # 6th attempt should be rate-limited
    $ua->get_ok('/login')->status_is(200);
    my $csrf = extract_csrf($ua);
    $ua->post_ok('/login' => form => {
        username    => 'admin',
        password    => 'wrong',
        _csrf_token => $csrf,
    })->status_is(429);
};

subtest 'Protected route redirects to login without session' => sub {
    my $ua = Test::Mojo->new(app());
    $ua->get_ok('/')->status_is(302)->header_like(Location => qr{/login});
};

done_testing();
