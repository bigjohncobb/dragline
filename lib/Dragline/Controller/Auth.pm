package Dragline::Controller::Auth;
use strict;
use warnings;
use utf8;

use Mojo::Base 'Mojolicious::Controller', -signatures;

use Crypt::Passphrase;

sub login_form ($c) {
    return $c->redirect_to('/') if $c->current_user;
    $c->render(template => 'auth/login');
}

sub login ($c) {
    unless ($c->validate_csrf) {
        $c->render(template => 'auth/login', status => 403);
        return;
    }

    my $username = $c->param('username') // '';
    my $password = $c->param('password') // '';
    my $ip       = $c->tx->remote_address // '';

    # Rate-limit failed login attempts per IP
    my ($fail_count) = $c->db->selectrow_array(
        q{SELECT COUNT(*) FROM login_attempts
          WHERE ip_address = ? AND success = 0 AND attempted_at > datetime('now', '-60 seconds')},
        undef, $ip,
    );
    if ($fail_count >= 5) {
        $c->render(text => 'Too many failed login attempts. Please wait.', status => 429);
        return;
    }

    my $user = $c->db->selectrow_hashref(
        q{SELECT * FROM users WHERE username_lower = LOWER(?) AND active = 1},
        undef, $username,
    );

    my $pp = Crypt::Passphrase->new(encoder => 'Bcrypt');

    unless ($user && $pp->verify_password($password, $user->{password_hash})) {
        $c->db->do(
            q{INSERT INTO login_attempts (id, ip_address, attempted_at, success)
              VALUES (?, ?, datetime('now'), 0)},
            undef, $c->new_uuid, $ip,
        );
        $c->stash(error => 'Invalid username or password');
        $c->render(template => 'auth/login', status => 401);
        return;
    }

    $c->session(user => {
        id       => $user->{id},
        username => $user->{username},
        role     => $user->{role},
    });

    $c->db->do(
        q{UPDATE users SET last_login_at = datetime('now') WHERE id = ?},
        undef, $user->{id},
    );

    $c->log_audit('login', 'user', $user->{id});
    $c->redirect_to('/');
}

sub logout ($c) {
    my $user = $c->current_user;
    if ($user) {
        $c->log_audit('logout', 'user', $user->{id});
    }
    $c->session(expires => 1);
    $c->redirect_to('/login');
}

sub change_password_form ($c) {
    $c->render(template => 'auth/change_password');
}

sub change_password ($c) {
    unless ($c->validate_csrf) {
        $c->render(template => 'auth/change_password', status => 403);
        return;
    }

    my $current_password = $c->param('current_password') // '';
    my $new_password     = $c->param('new_password')     // '';
    my $confirm_password = $c->param('confirm_password') // '';

    unless (length($new_password) >= 8) {
        $c->flash(error => 'New password must be at least 8 characters.');
        $c->redirect_to('/change-password');
        return;
    }

    unless ($new_password eq $confirm_password) {
        $c->flash(error => 'New password and confirmation do not match.');
        $c->redirect_to('/change-password');
        return;
    }

    my $user = $c->db->selectrow_hashref(
        q{SELECT * FROM users WHERE id = ? AND active = 1},
        undef, $c->current_user->{id},
    );

    my $pp = Crypt::Passphrase->new(encoder => 'Bcrypt');

    unless ($user && $pp->verify_password($current_password, $user->{password_hash})) {
        $c->flash(error => 'Current password is incorrect.');
        $c->redirect_to('/change-password');
        return;
    }

    my $new_hash = $pp->hash_password($new_password);
    $c->db->do(
        q{UPDATE users SET password_hash = ?, updated_at = datetime('now') WHERE id = ?},
        undef, $new_hash, $user->{id},
    );

    $c->log_audit('change_password', 'user', $user->{id});
    $c->flash(success => 'Password changed successfully.');
    $c->redirect_to('/');
}

1;
