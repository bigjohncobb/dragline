package Dragline::Controller::Notifications;
use strict;
use warnings;
use utf8;

use Mojo::Base 'Mojolicious::Controller', -signatures;

sub index ($c) {
    my $user_id = $c->current_user->{id};

    my $notifications = $c->db->selectall_arrayref(
        q{SELECT * FROM user_notifications
          WHERE user_id = ?
          ORDER BY created_at DESC
          LIMIT 50},
        { Slice => {} }, $user_id,
    );

    my $unread_count = $c->db->selectrow_array(
        q{SELECT COUNT(*) FROM user_notifications WHERE user_id = ? AND is_read = 0},
        undef, $user_id,
    );

    $c->stash(
        notifications => $notifications,
        unread_count  => $unread_count,
    );
    $c->render(template => 'notifications/index');
}

sub mark_read ($c) {
    unless ($c->validate_csrf) {
        $c->render(json => { error => 'Invalid CSRF token' }, status => 403);
        return;
    }

    my $id = $c->param('id');
    my $user_id = $c->current_user->{id};

    $c->db->do(
        q{UPDATE user_notifications
          SET is_read = 1, read_at = datetime('now')
          WHERE id = ? AND user_id = ?},
        undef, $id, $user_id,
    );

    $c->render(json => { ok => 1 });
}

sub mark_all_read ($c) {
    unless ($c->validate_csrf) {
        $c->render(json => { error => 'Invalid CSRF token' }, status => 403);
        return;
    }

    my $user_id = $c->current_user->{id};
    my $n = $c->db->do(
        q{UPDATE user_notifications
          SET is_read = 1, read_at = datetime('now')
          WHERE user_id = ? AND is_read = 0},
        undef, $user_id,
    );

    $c->render(json => { ok => 1, count => ($n + 0) });
}

sub preferences ($c) {
    my $user_id = $c->current_user->{id};

    my $prefs = $c->db->selectall_arrayref(
        q{SELECT * FROM notification_preferences
          WHERE user_id = ?
          ORDER BY event_type ASC},
        { Slice => {} }, $user_id,
    );

    $c->stash(prefs => $prefs);
    $c->render(template => 'notifications/preferences');
}

sub update_preferences ($c) {
    unless ($c->validate_csrf) {
        $c->render(text => 'Forbidden', status => 403);
        return;
    }

    my $user_id = $c->current_user->{id};
    my @types = $c->param('event_type');
    my @email = $c->param('email_enabled');
    my @web   = $c->param('web_enabled');

    my %email_map = map { $_ => 1 } @email;
    my %web_map   = map { $_ => 1 } @web;

    eval {
        $c->db->begin_work;
        for my $type (@types) {
            $c->db->do(
                q{INSERT INTO notification_preferences
                  (id, user_id, event_type, email_enabled, web_enabled, created_at, updated_at)
                  VALUES (?, ?, ?, ?, ?, datetime('now'), datetime('now'))
                  ON CONFLICT(user_id, event_type) DO UPDATE SET
                    email_enabled = excluded.email_enabled,
                    web_enabled = excluded.web_enabled,
                    updated_at = datetime('now')},
                undef,
                $c->new_uuid, $user_id, $type,
                ($email_map{$type} ? 1 : 0),
                ($web_map{$type}   ? 1 : 0),
            );
        }
        $c->db->commit;
    };
    if ($@) {
        eval { $c->db->rollback };
        $c->flash(error => 'Failed to update preferences.');
        $c->redirect_to('/notifications/preferences');
        return;
    }

    $c->flash(success => 'Preferences updated.');
    $c->redirect_to('/notifications/preferences');
}

1;
