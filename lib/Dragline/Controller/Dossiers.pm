package Dragline::Controller::Dossiers;
use strict;
use warnings;
use utf8;

use Mojo::Base 'Mojolicious::Controller', -signatures;

sub show ($c) {
    my $id = $c->param('id');

    my $target = $c->db->selectrow_hashref(
        q{SELECT * FROM targets WHERE id = ?}, undef, $id,
    );
    unless ($target) {
        $c->reply->not_found;
        return;
    }

    my $dossier = $c->db->selectrow_hashref(
        q{SELECT * FROM dossiers WHERE target_id = ?}, undef, $id,
    );

    unless ($dossier) {
        $c->stash(target => $target, no_dossier => 1);
        $c->render(template => 'targets/dossier');
        return;
    }

    my $sections = $c->db->selectall_arrayref(
        q{SELECT * FROM dossier_sections WHERE dossier_id = ? ORDER BY section_number ASC},
        { Slice => {} }, $dossier->{id},
    );

    my $progress;
    if ($dossier->{status} eq 'generating') {
        $progress = scalar(grep { defined $_->{content} } @$sections);
    }

    $c->stash(
        target   => $target,
        dossier  => $dossier,
        sections => $sections,
        progress => $progress,
    );
    $c->render(template => 'targets/dossier');
}

sub generate ($c) {
    unless ($c->validate_csrf) {
        $c->render(text => 'Forbidden', status => 403);
        return;
    }

    unless ($c->rate_limit('expensive')) {
        $c->flash(error => 'Too many requests. Please wait and try again.');
        return $c->redirect_to('/targets/' . $c->param('id') . '/dossier');
    }

    my $id = $c->param('id');

    my $target = $c->db->selectrow_hashref(
        q{SELECT * FROM targets WHERE id = ?}, undef, $id,
    );
    unless ($target) {
        $c->reply->not_found;
        return;
    }

    my $dossier = $c->db->selectrow_hashref(
        q{SELECT * FROM dossiers WHERE target_id = ?}, undef, $id,
    );

    if ($dossier && $dossier->{status} eq 'generating') {
        $c->flash(error => 'Dossier generation already in progress.');
        $c->redirect_to("/targets/$id/dossier");
        return;
    }

    if ($dossier) {
        $c->db->do(
            q{UPDATE dossiers SET status = 'generating', updated_at = datetime('now')
              WHERE target_id = ?},
            undef, $id,
        );
    } else {
        my $dossier_id = $c->new_uuid;
        $c->db->do(
            q{INSERT INTO dossiers (id, target_id, status, created_at, updated_at)
              VALUES (?, ?, 'generating', datetime('now'), datetime('now'))},
            undef, $dossier_id, $id,
        );
    }

    $c->minion->enqueue(synthesise => [{ target_id => $id }]);
    $c->flash(success => 'Dossier generation started.');
    $c->redirect_to("/targets/$id/dossier");
}

1;
