package Dragline::Controller::Auth;
use strict;
use warnings;
use utf8;

use Mojo::Base 'Mojolicious::Controller', -signatures;

use Crypt::Passphrase;
use Crypt::PRNG qw(random_bytes);
use Digest::SHA qw(sha256_hex);

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

sub forgot_password_form ($c) {
    return $c->redirect_to('/') if $c->current_user;
    $c->render(template => 'auth/forgot_password');
}

sub forgot_password ($c) {
    unless ($c->validate_csrf) {
        $c->render(template => 'auth/forgot_password', status => 403);
        return;
    }

    my $username = $c->param('username') // '';
    $username =~ s/^\s+|\s+$//g;

    unless (length($username)) {
        $c->stash(error => 'Please enter your username.');
        $c->render(template => 'auth/forgot_password');
        return;
    }

    my $user = $c->db->selectrow_hashref(
        q{SELECT * FROM users WHERE username_lower = LOWER(?) AND active = 1},
        undef, $username,
    );

    # Always show success to avoid username enumeration
    unless ($user) {
        $c->stash(success_msg => 'If that account exists and is active, a password reset link has been generated.');
        $c->render(template => 'auth/forgot_password');
        return;
    }

    my $raw_token = unpack('H*', Crypt::PRNG::random_bytes(32));
    my $token_hash = sha256_hex($raw_token);
    my $token_id   = $c->new_uuid;

    $c->db->do(
        q{INSERT INTO password_reset_tokens (id, user_id, token_hash, expires_at, created_at)
          VALUES (?, ?, ?, datetime('now', '+1 hour'), datetime('now'))},
        undef, $token_id, $user->{id}, $token_hash,
    );

    $c->log_audit('password_reset_request', 'user', $user->{id});
    $c->stash(reset_token => $raw_token, username => $username, success_msg => 1);
    $c->render(template => 'auth/forgot_password');
}

sub reset_password_form ($c) {
    return $c->redirect_to('/') if $c->current_user;

    my $token = $c->param('token') // '';
    unless (length($token)) {
        $c->flash(error => 'Invalid or missing reset token.');
        $c->redirect_to('/login');
        return;
    }

    my $token_hash = sha256_hex($token);

    my $reset = $c->db->selectrow_hashref(
        q{SELECT * FROM password_reset_tokens
          WHERE token_hash = ? AND used = 0 AND expires_at > datetime('now')},
        undef, $token_hash,
    );

    unless ($reset) {
        $c->stash(error => 'This reset link is invalid or has expired.');
        $c->render(template => 'auth/forgot_password');
        return;
    }

    $c->stash(reset_token => $token);
    $c->render(template => 'auth/reset_password');
}

sub reset_password ($c) {
    unless ($c->validate_csrf) {
        $c->render(text => 'Forbidden', status => 403);
        return;
    }

    my $token = $c->param('token') // '';
    unless (length($token)) {
        $c->flash(error => 'Invalid or missing reset token.');
        $c->redirect_to('/login');
        return;
    }

    my $token_hash = sha256_hex($token);

    my $reset = $c->db->selectrow_hashref(
        q{SELECT * FROM password_reset_tokens
          WHERE token_hash = ? AND used = 0 AND expires_at > datetime('now')},
        undef, $token_hash,
    );

    unless ($reset) {
        $c->flash(error => 'This reset link is invalid or has expired.');
        $c->redirect_to('/login');
        return;
    }

    my $new_password     = $c->param('new_password')     // '';
    my $confirm_password = $c->param('confirm_password') // '';

    unless (length($new_password) >= 8) {
        $c->stash(reset_token => $token, error => 'New password must be at least 8 characters.');
        $c->render(template => 'auth/reset_password');
        return;
    }

    unless ($new_password eq $confirm_password) {
        $c->stash(reset_token => $token, error => 'New password and confirmation do not match.');
        $c->render(template => 'auth/reset_password');
        return;
    }

    my $pp      = Crypt::Passphrase->new(encoder => 'Bcrypt');
    my $new_hash = $pp->hash_password($new_password);

    $c->db->do(
        q{UPDATE users SET password_hash = ?, updated_at = datetime('now') WHERE id = ?},
        undef, $new_hash, $reset->{user_id},
    );

    # Mark all tokens for this user as used
    $c->db->do(
        q{UPDATE password_reset_tokens SET used = 1 WHERE user_id = ?},
        undef, $reset->{user_id},
    );

    $c->log_audit('password_reset_complete', 'user', $reset->{user_id});
    $c->flash(success => 'Password has been reset. Please sign in with your new password.');
    $c->redirect_to('/login');
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
