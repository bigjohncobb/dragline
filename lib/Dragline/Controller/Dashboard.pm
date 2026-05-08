package Dragline::Controller::Dashboard;
use strict;
use warnings;
use utf8;

use Mojo::Base 'Mojolicious::Controller', -signatures;

sub health_check ($c) {
    $c->render(json => { status => 'ok' });
}

sub index ($c) {
    my $events = $c->db->selectall_arrayref(
        q{SELECT ce.*, t.canonical_name AS target_name, t.project_id
          FROM change_events ce
          JOIN targets t ON t.id = ce.target_id
          ORDER BY ce.created_at DESC
          LIMIT 100},
        { Slice => {} },
    );

    my $unseen = $c->db->selectrow_array(
        q{SELECT COUNT(*) FROM change_events WHERE seen = 0},
    );

    $c->stash(
        events       => $events,
        unseen_count => $unseen,
        title        => $unseen ? "($unseen) Dragline" : 'Dragline',
    );
    $c->render(template => 'dashboard/index');
}

sub mark_seen ($c) {
    unless ($c->validate_csrf) {
        $c->render(json => { error => 'Invalid CSRF token' }, status => 403);
        return;
    }

    my $id = $c->param('id');
    $c->db->do(
        q{UPDATE change_events SET seen = 1, seen_at = datetime('now') WHERE id = ?},
        undef, $id,
    );
    $c->render(json => { ok => 1 });
}

sub mark_all_seen ($c) {
    unless ($c->validate_csrf) {
        $c->render(json => { error => 'Invalid CSRF token' }, status => 403);
        return;
    }

    my $n = $c->db->do(
        q{UPDATE change_events SET seen = 1, seen_at = datetime('now') WHERE seen = 0},
    );
    $c->render(json => { ok => 1, count => ($n + 0) });
}

1;
