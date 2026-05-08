package Dragline::Controller::Settings;
use strict;
use warnings;
use utf8;

use Mojo::Base 'Mojolicious::Controller', -signatures;

use JSON::PP qw(encode_json decode_json);

sub webhooks ($c) {
    my $user_id = $c->current_user->{id};

    my $configs = $c->db->selectall_arrayref(
        q{SELECT wc.*,
                 (SELECT COUNT(*) FROM webhook_deliveries WHERE webhook_config_id = wc.id) AS delivery_count
          FROM webhook_configs wc
          WHERE wc.user_id = ?
          ORDER BY wc.created_at DESC},
        { Slice => {} }, $user_id,
    );

    $c->stash(configs => $configs);
    $c->render(template => 'settings/webhooks');
}

sub create_webhook ($c) {
    unless ($c->validate_csrf) {
        $c->render(text => 'Forbidden', status => 403);
        return;
    }

    my $user_id    = $c->current_user->{id};
    my $url        = $c->param('url')  // '';
    my $secret     = $c->param('secret') // undef;
    my $event_types = $c->param('event_types') // '[]';
    my $target_id  = $c->param('target_id') // undef;
    $url =~ s/^\s+|\s+$//g;

    unless (length($url)) {
        $c->flash(error => 'URL is required.');
        $c->redirect_to('/settings/webhooks');
        return;
    }

    unless ($url =~ m{^https?://}i) {
        $c->flash(error => 'URL must start with http:// or https://');
        $c->redirect_to('/settings/webhooks');
        return;
    }

    # Validate event_types is valid JSON
    eval { decode_json($event_types) };
    if ($@) {
        $c->flash(error => 'Event types must be valid JSON.');
        $c->redirect_to('/settings/webhooks');
        return;
    }

    # Encrypt secret if provided
    my $stored_secret = ($secret && length($secret))
        ? $c->encrypt_value($secret)
        : undef;

    my $id = $c->new_uuid;
    eval {
        $c->db->do(
            q{INSERT INTO webhook_configs (id, user_id, target_id, url, secret, event_types, created_at)
              VALUES (?, ?, ?, ?, ?, ?, datetime('now'))},
            undef, $id, $user_id, $target_id, $url, $stored_secret, $event_types,
        );
    };
    if ($@) {
        $c->flash(error => 'Failed to create webhook config.');
        $c->redirect_to('/settings/webhooks');
        return;
    }

    $c->flash(success => 'Webhook config created.');
    $c->redirect_to('/settings/webhooks');
}

sub delete_webhook ($c) {
    unless ($c->validate_csrf) {
        $c->render(text => 'Forbidden', status => 403);
        return;
    }

    my $id      = $c->param('id');
    my $user_id = $c->current_user->{id};

    $c->db->do(
        q{DELETE FROM webhook_configs WHERE id = ? AND user_id = ?},
        undef, $id, $user_id,
    );

    $c->flash(success => 'Webhook config deleted.');
    $c->redirect_to('/settings/webhooks');
}

1;
