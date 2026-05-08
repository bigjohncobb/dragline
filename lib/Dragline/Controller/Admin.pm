package Dragline::Controller::Admin;
use strict;
use warnings;
use utf8;

use Mojo::Base 'Mojolicious::Controller', -signatures;

use Crypt::Passphrase;
use Crypt::PRNG qw(random_bytes);
use Digest::SHA qw(sha256_hex);
use Dragline::Cost;

my @KNOWN_SETTINGS = qw(
    anthropic_api_key  qwen_api_key  alibaba_api_key  brave_api_key
    forge_api_url      forge_api_key  ollama_base_url  crawl_service_url
    r_service_url      crawl_content_threshold  default_embed_model
);

my %ENCRYPTED_SETTINGS = map { $_ => 1 } qw(
    anthropic_api_key  qwen_api_key  alibaba_api_key  brave_api_key
    forge_api_key
);

sub health ($c) {
    my $db_ok = eval { $c->db->selectrow_array('SELECT 1'); 1 };
    my $minion_stats = eval { $c->minion->stats } // {};

    $c->stash(
        db_ok        => $db_ok ? 1 : 0,
        minion_stats => $minion_stats,
    );
    $c->render(template => 'admin/health');
}

sub settings_form ($c) {
    my $rows = $c->db->selectall_arrayref(
        q{SELECT key, value, is_encrypted FROM settings ORDER BY key ASC},
        { Slice => {} },
    );

    my %settings;
    for my $row (@$rows) {
        $settings{$row->{key}} = {
            value        => $row->{is_encrypted} ? "\x{2022}" x 8 : ($row->{value} // ''),
            is_encrypted => $row->{is_encrypted},
        };
    }

    $c->stash(settings => \%settings);
    $c->render(template => 'admin/settings');
}

sub update_settings ($c) {
    unless ($c->validate_csrf) {
        $c->render(text => 'Forbidden', status => 403);
        return;
    }

    unless ($c->rate_limit('write')) {
        $c->flash(error => 'Too many requests. Please wait and try again.');
        $c->redirect_to('/admin/settings');
        return;
    }

    my @updated;
    for my $key (@KNOWN_SETTINGS) {
        my $val = $c->param($key);
        next unless defined $val;

        # For encrypted fields: skip update if placeholder submitted
        if ($ENCRYPTED_SETTINGS{$key} && $val =~ /^\x{2022}+$/) {
            next;
        }

        $c->set_setting($key, $val, $ENCRYPTED_SETTINGS{$key} ? 1 : 0);
        push @updated, $key;
    }

    $c->log_audit('update_settings', 'settings', undef, { keys_updated => \@updated });
    $c->flash(success => 'Settings saved.');
    $c->redirect_to('/admin/settings');
}

sub costs ($c) {
    my $summary   = Dragline::Cost::summary($c->db, 30);
    my $breakdown = Dragline::Cost::daily_breakdown($c->db, 30);
    $c->stash(summary => $summary, breakdown => $breakdown);
    $c->render(template => 'admin/costs');
}

sub audit_log ($c) {
    my $page   = $c->param('page') // 1;
    $page      = 1 unless $page =~ /^\d+$/ && $page > 0;
    my $limit  = 50;
    my $offset = ($page - 1) * $limit;

    my $action      = $c->param('action')      // '';
    my $entity_type = $c->param('entity_type') // '';

    my @where;
    my @bind;
    if (length($action)) {
        push @where, 'action = ?';
        push @bind,  $action;
    }
    if (length($entity_type)) {
        push @where, 'entity_type = ?';
        push @bind,  $entity_type;
    }

    my $where_sql = @where ? 'WHERE ' . join(' AND ', @where) : '';

    my $entries = $c->db->selectall_arrayref(
        qq{SELECT al.*, u.username
           FROM audit_log al
           LEFT JOIN users u ON u.id = al.user_id
           $where_sql
           ORDER BY al.created_at DESC
           LIMIT ? OFFSET ?},
        { Slice => {} }, @bind, $limit, $offset,
    );

    my ($total) = $c->db->selectrow_array(
        "SELECT COUNT(*) FROM audit_log $where_sql", undef, @bind,
    );

    $c->stash(
        entries     => $entries,
        page        => $page,
        total       => $total,
        per_page    => $limit,
        filter_action      => $action,
        filter_entity_type => $entity_type,
    );
    $c->render(template => 'admin/audit');
}

sub users ($c) {
    my $users = $c->db->selectall_arrayref(
        q{SELECT * FROM users ORDER BY username ASC},
        { Slice => {} },
    );
    $c->stash(users => $users);
    $c->render(template => 'admin/users');
}

sub create_user ($c) {
    unless ($c->validate_csrf) {
        $c->render(text => 'Forbidden', status => 403);
        return;
    }

    unless ($c->rate_limit('write')) {
        $c->flash(error => 'Too many requests. Please wait and try again.');
        $c->redirect_to('/admin/users');
        return;
    }

    my $username = $c->param('username') // '';
    my $password = $c->param('password') // '';
    my $role     = $c->param('role')     // 'analyst';
    $username =~ s/^\s+|\s+$//g;

    unless (length($username) && length($password)) {
        $c->flash(error => 'Username and password are required.');
        $c->redirect_to('/admin/users');
        return;
    }

    unless (grep { $_ eq $role } qw(admin analyst)) {
        $role = 'analyst';
    }

    my $existing = $c->db->selectrow_array(
        q{SELECT 1 FROM users WHERE username_lower = LOWER(?)}, undef, $username,
    );
    if ($existing) {
        $c->flash(error => 'Username already exists.');
        $c->redirect_to('/admin/users');
        return;
    }

    my $pp   = Crypt::Passphrase->new(encoder => 'Bcrypt');
    my $hash = $pp->hash_password($password);
    my $id   = $c->new_uuid;

    $c->db->do(
        q{INSERT INTO users
            (id, username, username_lower, password_hash, role, active, created_at, updated_at)
          VALUES (?, ?, LOWER(?), ?, ?, 1, datetime('now'), datetime('now'))},
        undef, $id, $username, $username, $hash, $role,
    );

    $c->log_audit('create_user', 'user', $id, { username => $username, role => $role });
    $c->flash(success => "User \"$username\" created.");
    $c->redirect_to('/admin/users');
}

sub delete_user ($c) {
    unless ($c->validate_csrf) {
        $c->render(text => 'Forbidden', status => 403);
        return;
    }

    unless ($c->rate_limit('write')) {
        $c->flash(error => 'Too many requests. Please wait and try again.');
        $c->redirect_to('/admin/users');
        return;
    }

    my $id      = $c->param('id');
    my $current = $c->current_user;

    if ($current && $current->{id} eq $id) {
        $c->flash(error => 'You cannot delete your own account.');
        $c->redirect_to('/admin/users');
        return;
    }

    $c->db->do(
        q{UPDATE users SET active = 0 WHERE id = ?}, undef, $id,
    );
    $c->log_audit('delete_user', 'user', $id);
    $c->flash(success => 'User deactivated.');
    $c->redirect_to('/admin/users');
}

sub api_keys ($c) {
    my $keys = $c->db->selectall_arrayref(
        q{SELECT * FROM api_keys ORDER BY created_at DESC},
        { Slice => {} },
    );
    $c->stash(api_keys => $keys);
    $c->render(template => 'admin/api_keys');
}

sub create_api_key ($c) {
    unless ($c->validate_csrf) {
        $c->render(text => 'Forbidden', status => 403);
        return;
    }

    unless ($c->rate_limit('write')) {
        $c->flash(error => 'Too many requests. Please wait and try again.');
        $c->redirect_to('/admin/api-keys');
        return;
    }

    my $name = $c->param('name') // '';
    my $role = $c->param('role') // 'readonly';
    $name =~ s/^\s+|\s+$//g;

    unless (length($name)) {
        $c->flash(error => 'Key name is required.');
        $c->redirect_to('/admin/api-keys');
        return;
    }

    unless (grep { $_ eq $role } qw(readonly analyst admin)) {
        $role = 'readonly';
    }

    my $raw_key  = unpack('H*', random_bytes(32));
    my $key_hash = sha256_hex($raw_key);
    my $prefix   = substr($raw_key, 0, 8);
    my $id       = $c->new_uuid;

    $c->db->do(
        q{INSERT INTO api_keys (id, name, key_hash, key_prefix, role, active, created_at, updated_at)
          VALUES (?, ?, ?, ?, ?, 1, datetime('now'), datetime('now'))},
        undef, $id, $name, $key_hash, $prefix, $role,
    );

    $c->log_audit('create_api_key', 'api_key', $id, { name => $name, role => $role });
    $c->flash(new_api_key => $raw_key);
    $c->redirect_to('/admin/api-keys');
}

sub delete_api_key ($c) {
    unless ($c->validate_csrf) {
        $c->render(text => 'Forbidden', status => 403);
        return;
    }

    unless ($c->rate_limit('write')) {
        $c->flash(error => 'Too many requests. Please wait and try again.');
        $c->redirect_to('/admin/api-keys');
        return;
    }

    my $id = $c->param('id');
    $c->db->do(q{UPDATE api_keys SET active = 0 WHERE id = ?}, undef, $id);
    $c->log_audit('delete_api_key', 'api_key', $id);
    $c->flash(success => 'API key revoked.');
    $c->redirect_to('/admin/api-keys');
}

sub rotate_api_key ($c) {
    unless ($c->validate_csrf) {
        $c->render(text => 'Forbidden', status => 403);
        return;
    }

    unless ($c->rate_limit('write')) {
        $c->flash(error => 'Too many requests. Please wait and try again.');
        $c->redirect_to('/admin/api-keys');
        return;
    }

    my $id = $c->param('id');
    my $existing = $c->db->selectrow_hashref(
        q{SELECT * FROM api_keys WHERE id = ? AND active = 1}, undef, $id,
    );
    unless ($existing) {
        $c->flash(error => 'API key not found.');
        $c->redirect_to('/admin/api-keys');
        return;
    }

    my $raw_key  = unpack('H*', random_bytes(32));
    my $key_hash = sha256_hex($raw_key);
    my $prefix   = substr($raw_key, 0, 8);

    $c->db->do(
        q{UPDATE api_keys SET key_hash = ?, key_prefix = ?, updated_at = datetime('now')
          WHERE id = ?},
        undef, $key_hash, $prefix, $id,
    );

    $c->log_audit('rotate_api_key', 'api_key', $id);
    $c->flash(new_api_key => $raw_key);
    $c->redirect_to('/admin/api-keys');
}

1;
