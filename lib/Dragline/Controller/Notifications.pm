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

    $c->stash(notifications => $notifications);
    $c->render(template => 'notifications/index');
}

sub mark_read ($c) {
    unless ($c->validate_csrf) {
        $c->flash(error => 'Invalid CSRF token');
        $c->redirect_to('/notifications');
        return;
    }

    my $id = $c->param('id');
    my $user_id = $c->current_user->{id};

    $c->db->do(
        q{UPDATE user_notifications
          SET is_read = 1
          WHERE id = ? AND user_id = ?},
        undef, $id, $user_id,
    );

    my $back = $c->req->headers->referer // '/notifications';
    $c->redirect_to($back);
}

sub mark_all_read ($c) {
    unless ($c->validate_csrf) {
        $c->flash(error => 'Invalid CSRF token');
        $c->redirect_to('/notifications');
        return;
    }

    my $user_id = $c->current_user->{id};
    my $n = $c->db->do(
        q{UPDATE user_notifications
          SET is_read = 1
          WHERE user_id = ? AND is_read = 0},
        undef, $user_id,
    );

    $c->flash(success => 'All notifications marked read.');
    $c->redirect_to('/notifications');
}

sub dismiss ($c) {
    unless ($c->validate_csrf) {
        $c->flash(error => 'Invalid CSRF token');
        $c->redirect_to('/notifications');
        return;
    }

    my $id = $c->param('id');
    my $user_id = $c->current_user->{id};

    $c->db->do(
        q{DELETE FROM user_notifications WHERE id = ? AND user_id = ?},
        undef, $id, $user_id,
    );

    my $back = $c->req->headers->referer // '/notifications';
    $c->redirect_to($back);
}

sub bulk_action ($c) {
    unless ($c->validate_csrf) {
        $c->flash(error => 'Invalid CSRF token');
        $c->redirect_to('/notifications');
        return;
    }

    my $action = $c->param('bulk_action') // '';
    my @ids = $c->param('notif_ids') ? @{$c->every_param('notif_ids')} : ();
    my $user_id = $c->current_user->{id};

    unless (@ids) {
        $c->flash(error => 'No notifications selected.');
        $c->redirect_to('/notifications');
        return;
    }

    my $placeholders = join(', ', ('?') x @ids);

    if ($action eq 'mark_read') {
        $c->db->do(
            qq{UPDATE user_notifications SET is_read = 1
              WHERE id IN ($placeholders) AND user_id = ?},
            undef, @ids, $user_id,
        );
        $c->flash(success => scalar(@ids) . ' notifications marked read.');
    }
    elsif ($action eq 'dismiss') {
        $c->db->do(
            qq{DELETE FROM user_notifications
              WHERE id IN ($placeholders) AND user_id = ?},
            undef, @ids, $user_id,
        );
        $c->flash(success => scalar(@ids) . ' notifications dismissed.');
    }
    else {
        $c->flash(error => 'Unknown bulk action.');
    }

    $c->redirect_to('/notifications');
}

sub preferences_form ($c) {
    my $user_id = $c->current_user->{id};

    my @event_types = qw(new_content updated_content gap_detected dossier_updated crawl_failed forge_sync discovery_complete);

    my $prefs = $c->db->selectall_arrayref(
        q{SELECT * FROM notification_preferences WHERE user_id = ?},
        { Slice => {} }, $user_id,
    );

    my %pref_map;
    for my $p (@$prefs) {
        $pref_map{$p->{event_type}} = $p->{notify_in_app};
    }

    $c->stash(
        event_types => \@event_types,
        pref_map    => \%pref_map,
    );
    $c->render(template => 'notifications/preferences');
}

sub update_preferences ($c) {
    unless ($c->validate_csrf) {
        $c->render(text => 'Forbidden', status => 403);
        return;
    }

    my $user_id = $c->current_user->{id};
    my @types = $c->param('event_type');
    my @enabled = $c->param('notify_in_app');
    my %enabled_map = map { $_ => 1 } @enabled;

    eval {
        $c->db->begin_work;
        for my $type (@types) {
            $c->db->do(
                q{INSERT INTO notification_preferences (user_id, event_type, notify_in_app)
                  VALUES (?, ?, ?)
                  ON CONFLICT(user_id, event_type) DO UPDATE SET
                    notify_in_app = excluded.notify_in_app},
                undef, $user_id, $type, ($enabled_map{$type} ? 1 : 0),
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
