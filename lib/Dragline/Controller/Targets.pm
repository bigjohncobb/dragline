package Dragline::Controller::Targets;
use strict;
use warnings;
use utf8;

use Mojo::Base 'Mojolicious::Controller', -signatures;

use Scalar::Util qw(looks_like_number);

sub index ($c) {
    my $search = $c->param('search') // '';
    $search =~ s/^\s+|\s+$//g;

    my @where;
    my @bind;

    if (length($search)) {
        my $like = '%' . lc($search) . '%';
        push @where, q{(
            LOWER(t.canonical_name) LIKE ?
            OR EXISTS (
                SELECT 1 FROM target_aliases ta
                WHERE ta.target_id = t.id AND LOWER(ta.alias) LIKE ?
            )
            OR LOWER(t.country) LIKE ?
        )};
        push @bind, $like, $like, $like;
    }

    my $where_sql = @where ? 'WHERE ' . join(' AND ', @where) : '';

    my $targets = $c->db->selectall_arrayref(
        qq{SELECT t.*, p.name AS project_name
          FROM targets t
          JOIN projects p ON p.id = t.project_id
          $where_sql
          ORDER BY p.name ASC, t.canonical_name ASC},
        { Slice => {} }, @bind,
    );

    $c->stash(targets => $targets, search => $search);
    $c->render(template => 'targets/index');
}

sub export_csv ($c) {
    my $targets = $c->db->selectall_arrayref(
        q{SELECT t.*, p.name AS project_name
          FROM targets t
          JOIN projects p ON p.id = t.project_id
          ORDER BY p.name ASC, t.canonical_name ASC},
        { Slice => {} },
    );

    my $csv = "id,canonical_name,entity_type,country,project_name,active,created_at\n";
    for my $t (@$targets) {
        my $name = $t->{canonical_name};
        $name =~ s/"/""/g;
        $csv .= sprintf('"%s","%s","%s","%s","%s","%s","%s"' . "\n",
            $t->{id}, $name, $t->{entity_type} // '',
            $t->{country} // '', $t->{project_name} // '',
            $t->{active} ? 'active' : 'inactive',
            $t->{created_at} // '',
        );
    }

    $c->res->headers->content_type('text/csv; charset=utf-8');
    $c->res->headers->header('Content-Disposition' => 'attachment; filename="dragline-targets.csv"');
    $c->render(text => $csv);
}

sub new_form ($c) {
    my $project_id = $c->param('project_id');
    my $project = $c->db->selectrow_hashref(
        q{SELECT * FROM projects WHERE id = ?}, undef, $project_id,
    );
    unless ($project) {
        $c->reply->not_found;
        return;
    }
    $c->stash(project => $project);
    $c->render(template => 'targets/new');
}

sub create ($c) {
    unless ($c->validate_csrf) {
        $c->render(text => 'Forbidden', status => 403);
        return;
    }

    unless ($c->rate_limit('write')) {
        $c->flash(error => 'Too many requests. Please wait and try again.');
        my $pid = $c->param('project_id');
        $c->redirect_to("/projects/$pid/targets/new");
        return;
    }

    my $project_id = $c->param('project_id');
    my $name       = $c->param('canonical_name') // '';
    $name =~ s/^\s+|\s+$//g;

    unless (length($name)) {
        $c->flash(error => 'Target name is required.');
        $c->redirect_to("/projects/$project_id/targets/new");
        return;
    }

    my $name_lower   = lc($name);
    my $id           = $c->new_uuid;
    my $mon_id       = $c->new_uuid;
    my $entity_type  = $c->param('entity_type')  // 'company';
    my $country      = $c->param('country')       // undef;
    my $jurisdiction = $c->param('jurisdiction')  // undef;
    my $primary_domain = $c->param('primary_domain') // undef;
    my $notes        = $c->param('notes')         // undef;

    eval {
        $c->db->begin_work;

        $c->db->do(
            q{INSERT INTO targets
                (id, project_id, canonical_name, canonical_name_lower,
                 entity_type, country, jurisdiction, primary_domain, notes,
                 created_at, updated_at)
              VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, datetime('now'), datetime('now'))},
            undef,
            $id, $project_id, $name, $name_lower,
            $entity_type, $country, $jurisdiction, $primary_domain, $notes,
        );

        $c->db->do(
            q{INSERT INTO target_monitoring
                (id, target_id,
                 next_forge_sync_at, next_crawl_at, next_discover_at,
                 created_at, updated_at)
              VALUES (?, ?,
                datetime('now', '+1 day'),
                datetime('now', '+7 days'),
                datetime('now', '+7 days'),
                datetime('now'), datetime('now'))},
            undef, $mon_id, $id,
        );

        $c->db->commit;
    };
    if ($@) {
        eval { $c->db->rollback };
        if ($@ =~ /UNIQUE constraint failed/) {
            $c->flash(error => 'A target with that name already exists in this project.');
        } else {
            $c->flash(error => 'Failed to create target.');
        }
        $c->redirect_to("/projects/$project_id/targets/new");
        return;
    }

    $c->log_audit('create', 'target', $id, { canonical_name => $name });
    $c->flash(success => "Target \"$name\" created.");
    $c->redirect_to("/targets/$id");
}

sub show ($c) {
    my $id = $c->param('id');

    my $target = $c->db->selectrow_hashref(
        q{SELECT t.*, p.name AS project_name
          FROM targets t
          JOIN projects p ON p.id = t.project_id
          WHERE t.id = ?},
        undef, $id,
    );
    unless ($target) {
        $c->reply->not_found;
        return;
    }

    my $aliases = $c->db->selectall_arrayref(
        q{SELECT * FROM target_aliases WHERE target_id = ? ORDER BY alias ASC},
        { Slice => {} }, $id,
    );

    my $domains = $c->db->selectall_arrayref(
        q{SELECT * FROM target_domains WHERE target_id = ? ORDER BY is_primary DESC, domain ASC},
        { Slice => {} }, $id,
    );

    my $monitoring = $c->db->selectrow_hashref(
        q{SELECT * FROM target_monitoring WHERE target_id = ?}, undef, $id,
    );

    my $people = $c->db->selectall_arrayref(
        q{SELECT pr.*, p.canonical_name AS person_name
          FROM person_roles pr
          JOIN people p ON p.id = pr.person_id
          WHERE pr.target_id = ? AND pr.is_current = 1
          ORDER BY p.canonical_name ASC},
        { Slice => {} }, $id,
    );

    my $events = $c->db->selectall_arrayref(
        q{SELECT * FROM change_events WHERE target_id = ? ORDER BY created_at DESC LIMIT 10},
        { Slice => {} }, $id,
    );

    my ($raw_count) = $c->db->selectrow_array(
        q{SELECT COUNT(*) FROM raw_content WHERE target_id = ?}, undef, $id,
    );

    my $dossier = $c->db->selectrow_hashref(
        q{SELECT * FROM dossiers WHERE target_id = ?}, undef, $id,
    );

    my $org_structure = $c->db->selectall_arrayref(
        q{SELECT os.*, pa.canonical_name AS parent_name, ch.canonical_name AS child_name
          FROM org_structure os
          LEFT JOIN targets pa ON pa.id = os.parent_target_id
          LEFT JOIN targets ch ON ch.id = os.child_target_id
          WHERE os.parent_target_id = ? OR os.child_target_id = ?
          ORDER BY os.created_at DESC},
        { Slice => {} }, $id, $id,
    );

    my $peers = $c->db->selectall_arrayref(
        q{SELECT pr.*, ta.canonical_name AS target_a_name, tb.canonical_name AS target_b_name
          FROM peer_relationships pr
          JOIN targets ta ON ta.id = pr.target_id_a
          JOIN targets tb ON tb.id = pr.target_id_b
          WHERE pr.target_id_a = ? OR pr.target_id_b = ?
          ORDER BY pr.created_at DESC},
        { Slice => {} }, $id, $id,
    );

    my $all_targets = $c->db->selectall_arrayref(
        q{SELECT id, canonical_name FROM targets WHERE active = 1 AND id != ? ORDER BY canonical_name ASC},
        { Slice => {} }, $id,
    );

    my $user = $c->current_user;
    my $bookmark_collections = [];
    if ($user) {
        $bookmark_collections = $c->db->selectall_arrayref(
            q{SELECT id, name FROM bookmark_collections WHERE user_id = ? ORDER BY name ASC},
            { Slice => {} }, $user->{id},
        );
    }

    $c->stash(
        target               => $target,
        aliases              => $aliases,
        domains              => $domains,
        monitoring           => $monitoring,
        people               => $people,
        events               => $events,
        raw_count            => $raw_count,
        dossier              => $dossier,
        org_structure        => $org_structure,
        peers                => $peers,
        all_targets          => $all_targets,
        bookmark_collections => $bookmark_collections,
    );
    $c->render(template => 'targets/show');
}

sub edit_form ($c) {
    my $id = $c->param('id');
    my $target = $c->db->selectrow_hashref(
        q{SELECT t.*, p.name AS project_name
          FROM targets t JOIN projects p ON p.id = t.project_id
          WHERE t.id = ?},
        undef, $id,
    );
    unless ($target) {
        $c->reply->not_found;
        return;
    }

    my $projects = $c->db->selectall_arrayref(
        q{SELECT id, name FROM projects ORDER BY name ASC},
        { Slice => {} },
    );

    $c->stash(target => $target, projects => $projects);
    $c->render(template => 'targets/edit');
}

sub update ($c) {
    unless ($c->validate_csrf) {
        $c->render(text => 'Forbidden', status => 403);
        return;
    }

    unless ($c->rate_limit('write')) {
        $c->flash(error => 'Too many requests. Please wait and try again.');
        return $c->redirect_to('/targets/' . $c->param('id') . '/edit');
    }

    my $id   = $c->param('id');
    my $name = $c->param('canonical_name') // '';
    $name =~ s/^\s+|\s+$//g;

    unless (length($name)) {
        $c->flash(error => 'Target name is required.');
        $c->redirect_to("/targets/$id/edit");
        return;
    }

    my $target = $c->db->selectrow_hashref(
        q{SELECT * FROM targets WHERE id = ?}, undef, $id,
    );
    unless ($target) {
        $c->reply->not_found;
        return;
    }

    my $new_project_id = $c->param('project_id') // '';
    my $project_changed = 0;

    if ($new_project_id && $new_project_id ne $target->{project_id}) {
        my $existing = $c->db->selectrow_array(
            q{SELECT 1 FROM targets WHERE project_id = ? AND canonical_name_lower = ? AND id != ?},
            undef, $new_project_id, lc($name), $id,
        );
        if ($existing) {
            $c->flash(error => 'A target with that name already exists in the destination project.');
            $c->redirect_to("/targets/$id/edit");
            return;
        }
        $project_changed = 1;
    }

    eval {
        $c->db->do(
            q{UPDATE targets SET
                canonical_name = ?, canonical_name_lower = ?,
                entity_type = ?, country = ?, jurisdiction = ?,
                primary_domain = ?, notes = ?,
                project_id = COALESCE(?, project_id)
              WHERE id = ?},
            undef,
            $name, lc($name),
            ($c->param('entity_type')    // $target->{entity_type}),
            ($c->param('country')        // undef),
            ($c->param('jurisdiction')   // undef),
            ($c->param('primary_domain') // undef),
            ($c->param('notes')          // undef),
            ($project_changed ? $new_project_id : undef),
            $id,
        );
    };
    if ($@) {
        if ($@ =~ /UNIQUE constraint failed/) {
            $c->flash(error => 'A target with that name already exists in this project.');
        } else {
            $c->flash(error => 'Failed to update target.');
        }
        $c->redirect_to("/targets/$id/edit");
        return;
    }

    $c->log_audit('update', 'target', $id, { canonical_name => $name });
    $c->flash(success => 'Target updated.');
    $c->redirect_to("/targets/$id");
}

sub delete ($c) {
    unless ($c->validate_csrf) {
        $c->render(text => 'Forbidden', status => 403);
        return;
    }

    unless ($c->rate_limit('write')) {
        $c->flash(error => 'Too many requests. Please wait and try again.');
        return $c->redirect_to('/targets');
    }

    my $id     = $c->param('id');
    my $target = $c->db->selectrow_hashref(
        q{SELECT * FROM targets WHERE id = ?}, undef, $id,
    );
    unless ($target) {
        $c->reply->not_found;
        return;
    }

    $c->db->do(q{DELETE FROM targets WHERE id = ?}, undef, $id);
    $c->log_audit('delete', 'target', $id, { canonical_name => $target->{canonical_name} });
    $c->flash(success => 'Target deleted.');
    $c->redirect_to('/targets');
}

sub activate ($c) {
    unless ($c->validate_csrf) {
        $c->render(text => 'Forbidden', status => 403);
        return;
    }

    my $id = $c->param('id');
    $c->db->do(q{UPDATE targets SET active = 1 WHERE id = ?}, undef, $id);
    $c->log_audit('activate', 'target', $id);
    $c->flash(success => 'Target activated.');
    $c->redirect_to("/targets/$id");
}

sub deactivate ($c) {
    unless ($c->validate_csrf) {
        $c->render(text => 'Forbidden', status => 403);
        return;
    }

    my $id = $c->param('id');
    $c->db->do(q{UPDATE targets SET active = 0 WHERE id = ?}, undef, $id);
    $c->log_audit('deactivate', 'target', $id);
    $c->flash(success => 'Target deactivated.');
    $c->redirect_to("/targets/$id");
}

sub add_alias ($c) {
    unless ($c->validate_csrf) {
        $c->render(text => 'Forbidden', status => 403);
        return;
    }

    unless ($c->rate_limit('write')) {
        $c->flash(error => 'Too many requests. Please wait and try again.');
        return $c->redirect_to('/targets/' . $c->param('id'));
    }

    my $id    = $c->param('id');
    my $alias = $c->param('alias') // '';
    $alias =~ s/^\s+|\s+$//g;

    unless (length($alias)) {
        $c->flash(error => 'Alias is required.');
        $c->redirect_to("/targets/$id");
        return;
    }

    my $alias_id    = $c->new_uuid;
    my $alias_lower = lc($alias);

    eval {
        $c->db->do(
            q{INSERT INTO target_aliases (id, target_id, alias, alias_lower, created_at)
              VALUES (?, ?, ?, ?, datetime('now'))},
            undef, $alias_id, $id, $alias, $alias_lower,
        );
    };
    if ($@) {
        if ($@ =~ /UNIQUE constraint failed/) {
            $c->flash(error => 'That alias already exists for this target.');
        } else {
            $c->flash(error => 'Failed to add alias.');
        }
        $c->redirect_to("/targets/$id");
        return;
    }

    $c->log_audit('add_alias', 'target', $id, { alias => $alias });
    $c->flash(success => 'Alias added.');
    $c->redirect_to("/targets/$id");
}

sub delete_alias ($c) {
    unless ($c->validate_csrf) {
        $c->render(text => 'Forbidden', status => 403);
        return;
    }

    my $id       = $c->param('id');
    my $alias_id = $c->param('alias_id');
    $c->db->do(
        q{DELETE FROM target_aliases WHERE id = ? AND target_id = ?},
        undef, $alias_id, $id,
    );
    $c->log_audit('delete_alias', 'target', $id, { alias_id => $alias_id });
    $c->flash(success => 'Alias removed.');
    $c->redirect_to("/targets/$id");
}

sub add_domain ($c) {
    unless ($c->validate_csrf) {
        $c->render(text => 'Forbidden', status => 403);
        return;
    }

    unless ($c->rate_limit('write')) {
        $c->flash(error => 'Too many requests. Please wait and try again.');
        return $c->redirect_to('/targets/' . $c->param('id'));
    }

    my $id     = $c->param('id');
    my $domain = $c->param('domain') // '';
    $domain =~ s/^\s+|\s+$//g;
    $domain = lc($domain);

    unless (length($domain) && $domain =~ /\./
            && $domain !~ /\s/
            && $domain !~ m{^https?://}i) {
        $c->flash(error => 'Please enter a valid domain (e.g. example.com).');
        $c->redirect_to("/targets/$id");
        return;
    }

    my $domain_id  = $c->new_uuid;
    my $is_primary = $c->param('is_primary') ? 1 : 0;

    eval {
        $c->db->do(
            q{INSERT INTO target_domains (id, target_id, domain, is_primary, created_at)
              VALUES (?, ?, ?, ?, datetime('now'))},
            undef, $domain_id, $id, $domain, $is_primary,
        );
    };
    if ($@) {
        if ($@ =~ /UNIQUE constraint failed/) {
            $c->flash(error => 'That domain already exists for this target.');
        } else {
            $c->flash(error => 'Failed to add domain.');
        }
        $c->redirect_to("/targets/$id");
        return;
    }

    $c->log_audit('add_domain', 'target', $id, { domain => $domain });
    $c->flash(success => 'Domain added.');
    $c->redirect_to("/targets/$id");
}

sub delete_domain ($c) {
    unless ($c->validate_csrf) {
        $c->render(text => 'Forbidden', status => 403);
        return;
    }

    my $id        = $c->param('id');
    my $domain_id = $c->param('domain_id');
    $c->db->do(
        q{DELETE FROM target_domains WHERE id = ? AND target_id = ?},
        undef, $domain_id, $id,
    );
    $c->log_audit('delete_domain', 'target', $id, { domain_id => $domain_id });
    $c->flash(success => 'Domain removed.');
    $c->redirect_to("/targets/$id");
}

sub bulk_action ($c) {
    unless ($c->validate_csrf) {
        $c->render(text => 'Forbidden', status => 403);
        return;
    }

    unless ($c->rate_limit('write')) {
        $c->flash(error => 'Too many requests. Please wait and try again.');
        return $c->redirect_to('/targets');
    }

    my $action = $c->param('bulk_action') // '';
    my @target_ids = $c->param('target_ids') ? @{$c->every_param('target_ids')} : ();

    unless (@target_ids) {
        $c->flash(error => 'No targets selected.');
        $c->redirect_to('/targets');
        return;
    }

    my $dbh = $c->db;
    my $count = 0;

    if ($action eq 'activate') {
        for my $id (@target_ids) {
            $dbh->do(q{UPDATE targets SET active = 1 WHERE id = ?}, undef, $id);
            $count++;
        }
        $c->log_audit('bulk_activate', 'target', undef, { count => $count });
        $c->flash(success => "$count targets activated.");
    }
    elsif ($action eq 'deactivate') {
        for my $id (@target_ids) {
            $dbh->do(q{UPDATE targets SET active = 0 WHERE id = ?}, undef, $id);
            $count++;
        }
        $c->log_audit('bulk_deactivate', 'target', undef, { count => $count });
        $c->flash(success => "$count targets deactivated.");
    }
    elsif ($action eq 'delete') {
        for my $id (@target_ids) {
            $dbh->do(q{DELETE FROM targets WHERE id = ?}, undef, $id);
            $count++;
        }
        $c->log_audit('bulk_delete', 'target', undef, { count => $count });
        $c->flash(success => "$count targets deleted.");
    }
    elsif ($action eq 'generate_dossier') {
        for my $id (@target_ids) {
            my $dossier = $dbh->selectrow_hashref(
                q{SELECT * FROM dossiers WHERE target_id = ?}, undef, $id,
            );
            if ($dossier && $dossier->{status} eq 'generating') {
                next;
            }
            if ($dossier) {
                $dbh->do(
                    q{UPDATE dossiers SET status = 'generating', updated_at = datetime('now') WHERE target_id = ?},
                    undef, $id,
                );
            } else {
                my $dossier_id = $c->new_uuid;
                $dbh->do(
                    q{INSERT INTO dossiers (id, target_id, status, created_at, updated_at)
                      VALUES (?, ?, 'generating', datetime('now'), datetime('now'))},
                    undef, $dossier_id, $id,
                );
            }
            $c->minion->enqueue(synthesise => [{ target_id => $id }]);
            $count++;
        }
        $c->log_audit('bulk_generate_dossier', 'target', undef, { count => $count });
        $c->flash(success => "Dossier generation queued for $count targets.");
    }
    elsif ($action eq 'discover') {
        for my $id (@target_ids) {
            $c->minion->enqueue(discover => [{ target_id => $id }]);
            $count++;
        }
        $c->log_audit('bulk_discover', 'target', undef, { count => $count });
        $c->flash(success => "Discovery queued for $count targets.");
    }
    elsif ($action eq 'forge_sync') {
        for my $id (@target_ids) {
            $c->minion->enqueue(forge_sync => [{ target_id => $id }]);
            $count++;
        }
        $c->log_audit('bulk_forge_sync', 'target', undef, { count => $count });
        $c->flash(success => "Forge sync queued for $count targets.");
    }
    else {
        $c->flash(error => 'Unknown bulk action.');
    }

    $c->redirect_to('/targets');
}

sub monitoring_form ($c) {
    my $id = $c->param('id');
    my $target = $c->db->selectrow_hashref(
        q{SELECT * FROM targets WHERE id = ?}, undef, $id,
    );
    unless ($target) {
        $c->reply->not_found;
        return;
    }
    my $monitoring = $c->db->selectrow_hashref(
        q{SELECT * FROM target_monitoring WHERE target_id = ?}, undef, $id,
    );
    $c->stash(target => $target, monitoring => $monitoring);
    $c->render(template => 'monitoring/edit');
}

sub update_monitoring ($c) {
    unless ($c->validate_csrf) {
        $c->render(text => 'Forbidden', status => 403);
        return;
    }

    unless ($c->rate_limit('write')) {
        $c->flash(error => 'Too many requests. Please wait and try again.');
        return $c->redirect_to('/targets/' . $c->param('id') . '/monitoring');
    }

    my $id = $c->param('id');
    my $target = $c->db->selectrow_hashref(
        q{SELECT * FROM targets WHERE id = ?}, undef, $id,
    );
    unless ($target) {
        $c->reply->not_found;
        return;
    }

    my $forge_cadence   = $c->param('forge_sync_cadence') // 'daily';
    my $crawl_cadence   = $c->param('crawl_cadence')      // 'weekly';
    my $discover_cadence = $c->param('discover_cadence')  // 'weekly';

    my %cadence_offset = (
        hourly   => '+1 hour',
        daily    => '+1 day',
        weekly   => '+7 days',
        monthly  => '+30 days',
        disabled => undef,
    );

    my $next_forge   = $cadence_offset{$forge_cadence};
    my $next_crawl   = $cadence_offset{$crawl_cadence};
    my $next_discover = $cadence_offset{$discover_cadence};

    $c->db->do(
        q{UPDATE target_monitoring SET
            forge_sync_cadence  = ?,
            crawl_cadence       = ?,
            discover_cadence    = ?,
            next_forge_sync_at  = CASE WHEN ? IS NOT NULL THEN datetime('now', ?) ELSE NULL END,
            next_crawl_at       = CASE WHEN ? IS NOT NULL THEN datetime('now', ?) ELSE NULL END,
            next_discover_at    = CASE WHEN ? IS NOT NULL THEN datetime('now', ?) ELSE NULL END
          WHERE target_id = ?},
        undef,
        $forge_cadence, $crawl_cadence, $discover_cadence,
        $next_forge,   $next_forge,
        $next_crawl,   $next_crawl,
        $next_discover, $next_discover,
        $id,
    );

    $c->log_audit('update_monitoring', 'target', $id, {
        forge_sync_cadence => $forge_cadence,
        crawl_cadence      => $crawl_cadence,
        discover_cadence   => $discover_cadence,
    });
    $c->flash(success => 'Monitoring settings updated.');
    $c->redirect_to("/targets/$id");
}

sub enrich_domains ($c) {
    unless ($c->validate_csrf) {
        $c->render(text => 'Forbidden', status => 403);
        return;
    }

    unless ($c->rate_limit('expensive')) {
        $c->flash(error => 'Too many requests. Please wait and try again.');
        return $c->redirect_to('/targets/' . $c->param('id'));
    }

    my $id = $c->param('id');
    my $target = $c->db->selectrow_hashref(
        q{SELECT * FROM targets WHERE id = ?}, undef, $id,
    );
    unless ($target) {
        $c->reply->not_found;
        return;
    }

    $c->minion->enqueue(domain_enrich => [{ target_id => $id }]);
    $c->log_audit('enrich_domains', 'target', $id);
    $c->flash(success => 'Domain enrichment queued.');
    $c->redirect_to("/targets/$id");
}

sub add_org_structure ($c) {
    unless ($c->validate_csrf) {
        $c->render(text => 'Forbidden', status => 403);
        return;
    }

    unless ($c->rate_limit('write')) {
        $c->flash(error => 'Too many requests. Please wait and try again.');
        return $c->redirect_to('/targets/' . $c->param('id'));
    }

    my $id = $c->param('id');
    my $other_id = $c->param('other_target_id') // '';
    my $rel_type = $c->param('relationship_type') // '';
    my $direction = $c->param('direction') // 'child'; # child means other is child of id

    unless (length($other_id) && length($rel_type)) {
        $c->flash(error => 'Target and relationship type are required.');
        return $c->redirect_to("/targets/$id");
    }

    my $parent_id = ($direction eq 'child') ? $id : $other_id;
    my $child_id  = ($direction eq 'child') ? $other_id : $id;

    my $existing = $c->db->selectrow_array(
        q{SELECT 1 FROM org_structure WHERE parent_target_id = ? AND child_target_id = ? AND relationship_type = ?},
        undef, $parent_id, $child_id, $rel_type,
    );
    if ($existing) {
        $c->flash(error => 'That relationship already exists.');
        return $c->redirect_to("/targets/$id");
    }

    my $rel_id = $c->new_uuid;
    my $pct = $c->param('percent_ownership');
    $pct = looks_like_number($pct) ? $pct : undef;
    my $notes = $c->param('notes') || undef;

    eval {
        $c->db->do(
            q{INSERT INTO org_structure (id, parent_target_id, child_target_id, relationship_type, percent_ownership, notes, created_at, updated_at)
              VALUES (?, ?, ?, ?, ?, ?, datetime('now'), datetime('now'))},
            undef, $rel_id, $parent_id, $child_id, $rel_type, $pct, $notes,
        );
    };
    if ($@) {
        $c->flash(error => 'Failed to add organisational relationship.');
        return $c->redirect_to("/targets/$id");
    }

    $c->log_audit('add_org_structure', 'target', $id, { other_target_id => $other_id, relationship_type => $rel_type });
    $c->flash(success => 'Organisational relationship added.');
    $c->redirect_to("/targets/$id");
}

sub delete_org_structure ($c) {
    unless ($c->validate_csrf) {
        $c->render(text => 'Forbidden', status => 403);
        return;
    }

    my $id     = $c->param('id');
    my $rel_id = $c->param('rel_id');
    $c->db->do(
        q{DELETE FROM org_structure WHERE id = ?},
        undef, $rel_id,
    );
    $c->log_audit('delete_org_structure', 'target', $id, { rel_id => $rel_id });
    $c->flash(success => 'Organisational relationship removed.');
    $c->redirect_to("/targets/$id");
}

sub add_peer ($c) {
    unless ($c->validate_csrf) {
        $c->render(text => 'Forbidden', status => 403);
        return;
    }

    unless ($c->rate_limit('write')) {
        $c->flash(error => 'Too many requests. Please wait and try again.');
        return $c->redirect_to('/targets/' . $c->param('id'));
    }

    my $id = $c->param('id');
    my $other_id = $c->param('other_target_id') // '';
    my $rel_type = $c->param('relationship_type') // '';

    unless (length($other_id)) {
        $c->flash(error => 'Please select the other target.');
        return $c->redirect_to("/targets/$id");
    }

    my @valid = qw(competitor partner supplier client peer);
    unless (grep { $_ eq $rel_type } @valid) {
        $c->flash(error => 'Invalid relationship type.');
        return $c->redirect_to("/targets/$id");
    }

    my ($id_a, $id_b) = ($id lt $other_id) ? ($id, $other_id) : ($other_id, $id);

    my $existing = $c->db->selectrow_array(
        q{SELECT 1 FROM peer_relationships WHERE target_id_a = ? AND target_id_b = ? AND relationship_type = ?},
        undef, $id_a, $id_b, $rel_type,
    );
    if ($existing) {
        $c->flash(error => 'That peer relationship already exists.');
        return $c->redirect_to("/targets/$id");
    }

    my $rel_id = $c->new_uuid;
    my $notes = $c->param('notes') || undef;

    eval {
        $c->db->do(
            q{INSERT INTO peer_relationships (id, target_id_a, target_id_b, relationship_type, notes, created_at, updated_at)
              VALUES (?, ?, ?, ?, ?, datetime('now'), datetime('now'))},
            undef, $rel_id, $id_a, $id_b, $rel_type, $notes,
        );
    };
    if ($@) {
        $c->flash(error => 'Failed to add peer relationship.');
        return $c->redirect_to("/targets/$id");
    }

    $c->log_audit('add_peer', 'target', $id, { other_target_id => $other_id, relationship_type => $rel_type });
    $c->flash(success => 'Peer relationship added.');
    $c->redirect_to("/targets/$id");
}

sub delete_peer ($c) {
    unless ($c->validate_csrf) {
        $c->render(text => 'Forbidden', status => 403);
        return;
    }

    my $id     = $c->param('id');
    my $rel_id = $c->param('rel_id');
    $c->db->do(
        q{DELETE FROM peer_relationships WHERE id = ?},
        undef, $rel_id,
    );
    $c->log_audit('delete_peer', 'target', $id, { rel_id => $rel_id });
    $c->flash(success => 'Peer relationship removed.');
    $c->redirect_to("/targets/$id");
}

sub report_txt ($c) {
    my $id = $c->param('id');

    my $target = $c->db->selectrow_hashref(
        q{SELECT t.*, p.name AS project_name
          FROM targets t
          JOIN projects p ON p.id = t.project_id
          WHERE t.id = ? AND t.active = 1},
        undef, $id,
    );
    unless ($target) {
        $c->reply->not_found;
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

    my $people = $c->db->selectall_arrayref(
        q{SELECT pr.title, p.canonical_name AS person_name
          FROM person_roles pr
          JOIN people p ON p.id = pr.person_id
          WHERE pr.target_id = ? AND pr.is_current = 1
          ORDER BY p.canonical_name ASC},
        { Slice => {} }, $id,
    );

    my $events = $c->db->selectall_arrayref(
        q{SELECT event_date, event_type, description
          FROM event_timeline
          WHERE target_id = ?
          ORDER BY event_date DESC
          LIMIT 50},
        { Slice => {} }, $id,
    );

    my $content = $c->db->selectall_arrayref(
        q{SELECT source_type, source_url, source_title, content_text, significance_tier, created_at
          FROM raw_content
          WHERE target_id = ?
          ORDER BY created_at DESC
          LIMIT 20},
        { Slice => {} }, $id,
    );

    my $dossier = $c->db->selectrow_hashref(
        q{SELECT * FROM dossiers WHERE target_id = ? AND status = 'current'},
        undef, $id,
    );

    my $dossier_sections = [];
    if ($dossier) {
        $dossier_sections = $c->db->selectall_arrayref(
            q{SELECT section_name, content
              FROM dossier_sections
              WHERE dossier_id = ?
              ORDER BY section_number ASC},
            { Slice => {} }, $dossier->{id},
    );
    }

    my $report = _build_report($target, $aliases, $domains, $people, $events, $content, $dossier_sections);

    $c->res->headers->content_type('text/plain; charset=utf-8');
    $c->res->headers->content_disposition("attachment; filename=\"$target->{canonical_name}-report.txt\"");
    $c->render(text => $report);
}

sub _build_report ($target, $aliases, $domains, $people, $events, $content, $dossier_sections) {
    my $r = '';
    $r .= "INTELLIGENCE REPORT\n";
    $r .= '=' x 60 . "\n\n";
    $r .= "Target:    $target->{canonical_name}\n";
    $r .= "Type:      $target->{entity_type}\n";
    $r .= "Project:   $target->{project_name}\n";
    $r .= "Country:   " . ($target->{country} // '—') . "\n";
    $r .= "Domain:    " . ($target->{primary_domain} // '—') . "\n";
    $r .= "\n";

    if (@$aliases) {
        $r .= "ALIASES\n";
        $r .= '-' x 40 . "\n";
        $r .= join(', ', map { $_->{alias} } @$aliases) . "\n\n";
    }

    if (@$domains) {
        $r .= "DOMAINS\n";
        $r .= '-' x 40 . "\n";
        for my $d (@$domains) {
            $r .= ($d->{is_primary} ? '* ' : '  ') . $d->{domain} . "\n";
        }
        $r .= "\n";
    }

    if (@$people) {
        $r .= "PEOPLE\n";
        $r .= '-' x 40 . "\n";
        for my $p (@$people) {
            $r .= "  $p->{person_name} — $p->{title}\n";
        }
        $r .= "\n";
    }

    if (@$dossier_sections) {
        $r .= "DOSSIER\n";
        $r .= '=' x 60 . "\n\n";
        for my $s (@$dossier_sections) {
            $r .= uc($s->{section_name}) . "\n";
            $r .= '-' x 40 . "\n";
            $r .= ($s->{content} // '') . "\n\n";
        }
    }

    if (@$events) {
        $r .= "EVENT TIMELINE\n";
        $r .= '=' x 60 . "\n\n";
        for my $e (@$events) {
            $r .= ($e->{event_date} // '—') . " [$e->{event_type}] $e->{description}\n";
        }
        $r .= "\n";
    }

    if (@$content) {
        $r .= "RECENT CONTENT\n";
        $r .= '=' x 60 . "\n\n";
        for my $c (@$content) {
            $r .= ($c->{source_title} // 'Untitled') . "\n";
            $r .= "  Type: $c->{source_type} | Tier: " . ($c->{significance_tier} // '—') . " | $c->{created_at}\n";
            $r .= "  URL: " . ($c->{source_url} // '—') . "\n";
            my $text = $c->{content_text} // '';
            if (length($text) > 500) {
                $text = substr($text, 0, 500) . '...';
            }
            $text =~ s/^/  /gm;
            $r .= $text . "\n\n";
        }
    }

    $r .= "— END OF REPORT —\n";
    return $r;
}

1;
