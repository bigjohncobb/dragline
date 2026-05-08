package Dragline::Controller::Webhooks;
use strict;
use warnings;
use utf8;

use Mojo::Base 'Mojolicious::Controller', -signatures;

use JSON::PP qw(encode_json decode_json);

sub index ($c) {
    my $configs = $c->db->selectall_arrayref(
        q{SELECT wc.*,
                 (SELECT COUNT(*) FROM webhook_deliveries WHERE webhook_id = wc.id) AS delivery_count
          FROM webhook_configs wc
          ORDER BY wc.name ASC},
        { Slice => {} },
    );

    $c->stash(configs => $configs);
    $c->render(template => 'webhooks/index');
}

sub create ($c) {
    unless ($c->validate_csrf) {
        $c->render(text => 'Forbidden', status => 403);
        return;
    }

    my $name        = $c->param('name') // '';
    my $url         = $c->param('url')  // '';
    my $secret      = $c->param('secret') // undef;
    my $event_types = $c->param('event_types') // '["*"]';
    $name =~ s/^\s+|\s+$//g;
    $url  =~ s/^\s+|\s+$//g;

    unless (length($name) && length($url)) {
        $c->flash(error => 'Name and URL are required.');
        $c->redirect_to('/admin/webhooks');
        return;
    }

    unless ($url =~ m{^https?://}i) {
        $c->flash(error => 'URL must start with http:// or https://');
        $c->redirect_to('/admin/webhooks');
        return;
    }

    my $id = $c->new_uuid;
    eval {
        $c->db->do(
            q{INSERT INTO webhook_configs (id, name, url, secret, event_types, created_at, updated_at)
              VALUES (?, ?, ?, ?, ?, datetime('now'), datetime('now'))},
            undef, $id, $name, $url, $secret, $event_types,
        );
    };
    if ($@) {
        $c->flash(error => 'Failed to create webhook config.');
        $c->redirect_to('/admin/webhooks');
        return;
    }

    $c->log_audit('create', 'webhook_config', $id, { name => $name });
    $c->flash(success => 'Webhook config created.');
    $c->redirect_to('/admin/webhooks');
}

sub update ($c) {
    unless ($c->validate_csrf) {
        $c->render(text => 'Forbidden', status => 403);
        return;
    }

    my $id          = $c->param('id');
    my $name        = $c->param('name') // '';
    my $url         = $c->param('url')  // '';
    my $secret      = $c->param('secret') // undef;
    my $event_types = $c->param('event_types') // '["*"]';
    my $active      = $c->param('active') // '1';
    $name =~ s/^\s+|\s+$//g;
    $url  =~ s/^\s+|\s+$//g;

    unless (length($name) && length($url)) {
        $c->flash(error => 'Name and URL are required.');
        $c->redirect_to('/admin/webhooks');
        return;
    }

    $c->db->do(
        q{UPDATE webhook_configs
          SET name = ?, url = ?, secret = ?, event_types = ?, active = ?, updated_at = datetime('now')
          WHERE id = ?},
        undef, $name, $url, $secret, $event_types, ($active ? 1 : 0), $id,
    );

    $c->log_audit('update', 'webhook_config', $id, { name => $name });
    $c->flash(success => 'Webhook config updated.');
    $c->redirect_to('/admin/webhooks');
}

sub delete ($c) {
    unless ($c->validate_csrf) {
        $c->render(text => 'Forbidden', status => 403);
        return;
    }

    my $id = $c->param('id');
    $c->db->do(q{DELETE FROM webhook_configs WHERE id = ?}, undef, $id);

    $c->log_audit('delete', 'webhook_config', $id);
    $c->flash(success => 'Webhook config deleted.');
    $c->redirect_to('/admin/webhooks');
}

sub deliveries ($c) {
    my $webhook_id = $c->param('id');

    my $config = $c->db->selectrow_hashref(
        q{SELECT * FROM webhook_configs WHERE id = ?}, undef, $webhook_id,
    );
    unless ($config) {
        $c->reply->not_found;
        return;
    }

    my $deliveries = $c->db->selectall_arrayref(
        q{SELECT * FROM webhook_deliveries
          WHERE webhook_id = ?
          ORDER BY created_at DESC
          LIMIT 50},
        { Slice => {} }, $webhook_id,
    );

    $c->stash(
        config     => $config,
        deliveries => $deliveries,
    );
    $c->render(template => 'webhooks/deliveries');
}

1;
