package Dragline::Controller::Api;
use strict;
use warnings;
use utf8;

use Mojo::Base 'Mojolicious::Controller', -signatures;

sub targets ($c) {
    my $targets = $c->db->selectall_arrayref(
        q{SELECT t.*, p.name AS project_name
          FROM targets t
          JOIN projects p ON p.id = t.project_id
          WHERE t.active = 1
          ORDER BY p.name ASC, t.canonical_name ASC},
        { Slice => {} },
    );
    $c->render(json => $targets);
}

sub target ($c) {
    my $id = $c->param('id');

    my $target = $c->db->selectrow_hashref(
        q{SELECT t.*, p.name AS project_name
          FROM targets t
          JOIN projects p ON p.id = t.project_id
          WHERE t.id = ? AND t.active = 1},
        undef, $id,
    );

    unless ($target) {
        $c->render(json => { error => 'Target not found' }, status => 404);
        return;
    }

    my $aliases = $c->db->selectall_arrayref(
        q{SELECT alias FROM target_aliases WHERE target_id = ? ORDER BY alias ASC},
        { Slice => {} }, $id,
    );

    my $domains = $c->db->selectall_arrayref(
        q{SELECT domain, is_primary FROM target_domains WHERE target_id = ? ORDER BY is_primary DESC, domain ASC},
        { Slice => {} }, $id,
    );

    my $monitoring = $c->db->selectrow_hashref(
        q{SELECT * FROM target_monitoring WHERE target_id = ?}, undef, $id,
    );

    my $dossier = $c->db->selectrow_hashref(
        q{SELECT id, status, generated_at FROM dossiers WHERE target_id = ?}, undef, $id,
    );

    $target->{aliases}    = $aliases;
    $target->{domains}    = $domains;
    $target->{monitoring} = $monitoring;
    $target->{dossier}    = $dossier;

    $c->render(json => $target);
}

sub content ($c) {
    my $id   = $c->param('id');
    my $page = $c->param('page') // 1;
    $page    = 1 unless $page =~ /^\d+$/ && $page > 0;

    my $target = $c->db->selectrow_hashref(
        q{SELECT id FROM targets WHERE id = ? AND active = 1}, undef, $id,
    );
    unless ($target) {
        $c->render(json => { error => 'Target not found' }, status => 404);
        return;
    }

    my $limit  = 20;
    my $offset = ($page - 1) * $limit;

    my $rows = $c->db->selectall_arrayref(
        q{SELECT id, source_type, source_url, source_title, language_code,
                 significance_tier, word_count, fetched_at, created_at
          FROM raw_content
          WHERE target_id = ?
          ORDER BY created_at DESC
          LIMIT ? OFFSET ?},
        { Slice => {} }, $id, $limit, $offset,
    );

    my ($total) = $c->db->selectrow_array(
        q{SELECT COUNT(*) FROM raw_content WHERE target_id = ?}, undef, $id,
    );

    $c->render(json => {
        target_id => $id,
        page      => $page + 0,
        per_page  => $limit,
        total     => $total + 0,
        items     => $rows,
    });
}

sub dossier ($c) {
    my $id = $c->param('id');

    my $dossier = $c->db->selectrow_hashref(
        q{SELECT * FROM dossiers WHERE target_id = ? AND status = 'current'},
        undef, $id,
    );

    unless ($dossier) {
        $c->render(json => { error => 'No current dossier' }, status => 404);
        return;
    }

    my $sections = $c->db->selectall_arrayref(
        q{SELECT section_number, section_name, content
          FROM dossier_sections
          WHERE dossier_id = ?
          ORDER BY section_number ASC},
        { Slice => {} }, $dossier->{id},
    );

    $c->render(json => {
        target_id    => $id,
        generated_at => $dossier->{generated_at},
        sections     => $sections,
    });
}

sub change_feed ($c) {
    my $since = $c->param('since');

    my @bind;
    my $where_sql = '';
    if ($since && $since =~ /^\d{4}-\d{2}-\d{2}/) {
        $where_sql = 'WHERE ce.created_at > ?';
        push @bind, $since;
    }

    my $events = $c->db->selectall_arrayref(
        qq{SELECT ce.*, t.canonical_name AS target_name, t.project_id
           FROM change_events ce
           JOIN targets t ON t.id = ce.target_id
           $where_sql
           ORDER BY ce.created_at DESC
           LIMIT 50},
        { Slice => {} }, @bind,
    );

    $c->render(json => $events);
}

sub upload_content ($c) {
    my $id = $c->param('id');

    my $target = $c->db->selectrow_hashref(
        q{SELECT id FROM targets WHERE id = ? AND active = 1}, undef, $id,
    );
    unless ($target) {
        $c->render(json => { error => 'Target not found' }, status => 404);
        return;
    }

    my $body = $c->req->json;
    unless ($body && ref($body) eq 'HASH') {
        $c->render(json => { error => 'JSON body required' }, status => 400);
        return;
    }

    my $url         = $body->{url}         // '';
    my $source_type = $body->{source_type} // '';

    my @valid_types = qw(crawl_static crawl_js pdf forge upload);
    unless (grep { $_ eq $source_type } @valid_types) {
        $c->render(json => { error => 'Invalid source_type' }, status => 400);
        return;
    }

    unless (length($url) && $url =~ m{^https?://}i) {
        $c->render(json => { error => 'A valid URL is required' }, status => 400);
        return;
    }

    unless ($c->check_ssrf($url)) {
        $c->render(json => { error => 'URL blocked by security policy' }, status => 400);
        return;
    }

    my $job_id;
    if ($source_type eq 'pdf') {
        $job_id = $c->minion->enqueue(ingest_pdf => [{ target_id => $id, url => $url }]);
    } else {
        $job_id = $c->minion->enqueue(crawl_static => [{ target_id => $id, url => $url }]);
    }

    $c->render(json => { ok => 1, job_id => $job_id });
}

sub create_target ($c) {
    # Only analyst and admin roles can create
    my $role = $c->stash('api_key_role') // 'readonly';
    unless (grep { $_ eq $role } qw(analyst admin)) {
        $c->render(json => { error => 'Forbidden' }, status => 403);
        return;
    }

    my $body = $c->req->json;
    unless ($body && ref($body) eq 'HASH') {
        $c->render(json => { error => 'JSON body required' }, status => 400);
        return;
    }

    my $project_id = $body->{project_id} // '';
    my $name       = $body->{canonical_name} // '';
    $name =~ s/^\s+|\s+$//g;

    unless (length($project_id) && length($name)) {
        $c->render(json => { error => 'project_id and canonical_name are required' }, status => 400);
        return;
    }

    my $project = $c->db->selectrow_hashref(
        q{SELECT 1 FROM projects WHERE id = ?}, undef, $project_id,
    );
    unless ($project) {
        $c->render(json => { error => 'Project not found' }, status => 404);
        return;
    }

    my $id = $c->new_uuid;
    my $mon_id = $c->new_uuid;

    eval {
        $c->db->begin_work;
        $c->db->do(
            q{INSERT INTO targets
                (id, project_id, canonical_name, canonical_name_lower, entity_type, country,
                 jurisdiction, primary_domain, notes, created_at, updated_at)
              VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, datetime('now'), datetime('now'))},
            undef,
            $id, $project_id, $name, lc($name),
            ($body->{entity_type}    // 'company'),
            ($body->{country}        // undef),
            ($body->{jurisdiction}   // undef),
            ($body->{primary_domain} // undef),
            ($body->{notes}          // undef),
        );
        $c->db->do(
            q{INSERT INTO target_monitoring
                (id, target_id, next_forge_sync_at, next_crawl_at, next_discover_at, created_at, updated_at)
              VALUES (?, ?, datetime('now', '+1 day'), datetime('now', '+7 days'), datetime('now', '+7 days'),
                      datetime('now'), datetime('now'))},
            undef, $mon_id, $id,
        );
        $c->db->commit;
    };
    if ($@) {
        $c->render(json => { error => 'Failed to create target' }, status => 500);
        return;
    }

    $c->log_audit('api_create_target', 'target', $id, { canonical_name => $name });
    $c->render(json => { ok => 1, target_id => $id });
}

sub create_person ($c) {
    my $role = $c->stash('api_key_role') // 'readonly';
    unless (grep { $_ eq $role } qw(analyst admin)) {
        $c->render(json => { error => 'Forbidden' }, status => 403);
        return;
    }

    my $body = $c->req->json;
    unless ($body && ref($body) eq 'HASH') {
        $c->render(json => { error => 'JSON body required' }, status => 400);
        return;
    }

    my $name = $body->{canonical_name} // '';
    $name =~ s/^\s+|\s+$//g;

    unless (length($name)) {
        $c->render(json => { error => 'canonical_name is required' }, status => 400);
        return;
    }

    my $id = $c->new_uuid;

    eval {
        $c->db->do(
            q{INSERT INTO people
                (id, canonical_name, canonical_name_lower, nationality, bio_summary, created_at, updated_at)
              VALUES (?, ?, ?, ?, ?, datetime('now'), datetime('now'))},
            undef,
            $id, $name, lc($name),
            ($body->{nationality} // undef),
            ($body->{bio_summary} // undef),
        );
    };
    if ($@) {
        $c->render(json => { error => 'Failed to create person' }, status => 500);
        return;
    }

    $c->log_audit('api_create_person', 'person', $id, { canonical_name => $name });
    $c->render(json => { ok => 1, person_id => $id });
}

1;
