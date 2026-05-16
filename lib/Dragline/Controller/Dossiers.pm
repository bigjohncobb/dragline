package Dragline::Controller::Dossiers;
use strict;
use warnings;
use utf8;

use Mojo::Base 'Mojolicious::Controller', -signatures;

use JSON::PP qw(decode_json encode_json);

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

    my $versions = $c->db->selectall_arrayref(
        q{SELECT id, version_number, created_by, created_at
          FROM dossier_versions WHERE dossier_id = ? ORDER BY version_number DESC},
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
        versions => $versions,
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

    my $job_id = $c->minion->enqueue(synthesise => [{ target_id => $id }]);
    $c->db->do(
        q{UPDATE dossiers SET minion_job_id = ? WHERE target_id = ?},
        undef, "$job_id", $id,
    );
    my $pending = $c->session('pending_jobs') // [];
    push @$pending, { id => "$job_id", task => 'synthesise', label => 'Generate dossier' };
    splice(@$pending, 0, scalar(@$pending) - 15) if @$pending > 15;
    $c->session(pending_jobs => $pending);
    $c->flash(success => 'Dossier generation started.');
    $c->redirect_to("/targets/$id/dossier");
}

sub cancel ($c) {
    unless ($c->validate_csrf) {
        $c->render(text => 'Forbidden', status => 403);
        return;
    }

    my $id = $c->param('id');

    my $dossier = $c->db->selectrow_hashref(
        q{SELECT * FROM dossiers WHERE target_id = ?}, undef, $id,
    );

    unless ($dossier && $dossier->{status} eq 'generating') {
        $c->flash(error => 'No dossier generation in progress.');
        $c->redirect_to("/targets/$id/dossier");
        return;
    }

    # Remove the Minion job if it exists
    if ($dossier->{minion_job_id}) {
        eval {
            my $job = $c->minion->job($dossier->{minion_job_id});
            if ($job) {
                $job->remove;
            }
        };
    }

    $c->db->do(
        q{UPDATE dossiers SET status = 'draft', minion_job_id = NULL, updated_at = datetime('now') WHERE target_id = ?},
        undef, $id,
    );

    $c->log_audit('cancel_dossier_generation', 'target', $id);
    $c->flash(success => 'Dossier generation cancelled.');
    $c->redirect_to("/targets/$id/dossier");
}

sub show_version ($c) {
    my $id         = $c->param('id');
    my $version_id = $c->param('version_id');

    my $target = $c->db->selectrow_hashref(
        q{SELECT * FROM targets WHERE id = ?}, undef, $id,
    );
    unless ($target) {
        $c->reply->not_found;
        return;
    }

    my $version = $c->db->selectrow_hashref(
        q{SELECT * FROM dossier_versions WHERE id = ?}, undef, $version_id,
    );
    unless ($version) {
        $c->reply->not_found;
        return;
    }

    my $snapshot = eval { JSON::PP::decode_json($version->{snapshot_json}) } // [];

    my $dossier = $c->db->selectrow_hashref(
        q{SELECT * FROM dossiers WHERE target_id = ?}, undef, $id,
    );

    my $versions = $c->db->selectall_arrayref(
        q{SELECT id, version_number, created_by, created_at
          FROM dossier_versions WHERE dossier_id = ? ORDER BY version_number DESC},
        { Slice => {} }, ($dossier ? $dossier->{id} : undef),
    );

    $c->stash(
        target   => $target,
        dossier  => $dossier,
        versions => $versions,
        viewing_version => $version,
        snapshot => $snapshot,
    );
    $c->render(template => 'targets/dossier');
}

sub restore_version ($c) {
    unless ($c->validate_csrf) {
        $c->render(text => 'Forbidden', status => 403);
        return;
    }

    my $id         = $c->param('id');
    my $version_id = $c->param('version_id');

    my $version = $c->db->selectrow_hashref(
        q{SELECT * FROM dossier_versions WHERE id = ?}, undef, $version_id,
    );
    unless ($version) {
        $c->flash(error => 'Version not found.');
        $c->redirect_to("/targets/$id/dossier");
        return;
    }

    my $snapshot = eval { JSON::PP::decode_json($version->{snapshot_json}) } // [];

    my $dossier = $c->db->selectrow_hashref(
        q{SELECT * FROM dossiers WHERE target_id = ?}, undef, $id,
    );
    unless ($dossier) {
        $c->flash(error => 'Dossier not found.');
        $c->redirect_to("/targets/$id/dossier");
        return;
    }

    eval {
        $c->db->begin_work;
        for my $sec (@$snapshot) {
            $c->db->do(
                q{INSERT INTO dossier_sections
                    (id, dossier_id, section_number, section_name, content, model_used, token_count, created_at, updated_at)
                  VALUES (?, ?, ?, ?, ?, ?, ?, datetime('now'), datetime('now'))
                  ON CONFLICT(dossier_id, section_number) DO UPDATE SET
                    content     = excluded.content,
                    model_used  = excluded.model_used,
                    token_count = excluded.token_count,
                    updated_at  = datetime('now')},
                undef,
                $c->new_uuid, $dossier->{id}, $sec->{section_number},
                $sec->{section_name}, $sec->{content},
                $sec->{model_used} // undef, $sec->{token_count} // 0,
            );
        }

        my $version_num = $c->db->selectrow_array(
            q{SELECT COALESCE(MAX(version_number), 0) + 1 FROM dossier_versions WHERE dossier_id = ?},
            undef, $dossier->{id},
        );
        my $snapshot_json = eval { encode_json([map { {
            section_number => $_->{section_number},
            section_name   => $_->{section_name},
            content        => $_->{content},
            model_used     => $_->{model_used},
            token_count    => $_->{token_count},
        } } @$snapshot]) };
        $c->db->do(
            q{INSERT INTO dossier_versions
                (id, dossier_id, target_id, version_number, snapshot_json, created_by)
              VALUES (?, ?, ?, ?, ?, 'restore')},
            undef, $c->new_uuid, $dossier->{id}, $id, $version_num, $snapshot_json,
        );

        $c->db->do(
            q{UPDATE dossiers SET status = 'current', updated_at = datetime('now') WHERE id = ?},
            undef, $dossier->{id},
        );

        $c->db->commit;
    };
    if ($@) {
        eval { $c->db->rollback };
        $c->flash(error => 'Failed to restore version: ' . $@);
        $c->redirect_to("/targets/$id/dossier");
        return;
    }

    $c->log_audit('restore_dossier_version', 'target', $id, { version_id => $version_id });
    $c->flash(success => 'Dossier restored to version ' . $version->{version_number} . '.');
    $c->redirect_to("/targets/$id/dossier");
}

sub export_dossier ($c) {
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
        $c->flash(error => 'No dossier to export.');
        $c->redirect_to("/targets/$id/dossier");
        return;
    }

    my $sections = $c->db->selectall_arrayref(
        q{SELECT section_number, section_name, content, model_used
          FROM dossier_sections WHERE dossier_id = ? ORDER BY section_number ASC},
        { Slice => {} }, $dossier->{id},
    );

    my $type = $c->param('format') // 'json';
    if ($type eq 'json') {
        $c->res->headers->content_type('application/json; charset=utf-8');
        $c->res->headers->content_disposition("attachment; filename=\"$target->{canonical_name}-dossier.json\"");
        $c->render(json => {
            target       => $target->{canonical_name},
            generated_at => $dossier->{generated_at},
            status       => $dossier->{status},
            sections     => $sections,
        });
    } else {
        my $txt = "DOSSIER: $target->{canonical_name}\n";
        $txt .= ('=' x 60) . "\n";
        $txt .= "Generated: " . ($dossier->{generated_at} // 'unknown') . "\n";
        $txt .= "Status: $dossier->{status}\n\n";
        for my $s (@$sections) {
            $txt .= uc($s->{section_name}) . "\n";
            $txt .= ('-' x 40) . "\n";
            $txt .= ($s->{content} // '') . "\n\n";
        }
        $c->res->headers->content_type('text/plain; charset=utf-8');
        $c->res->headers->content_disposition("attachment; filename=\"$target->{canonical_name}-dossier.txt\"");
        $c->render(text => $txt);
    }
}

1;
