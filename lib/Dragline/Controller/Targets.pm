package Dragline::Controller::Targets;
use strict;
use warnings;
use utf8;

use Mojo::Base 'Mojolicious::Controller', -signatures;

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

    $c->stash(
        target     => $target,
        aliases    => $aliases,
        domains    => $domains,
        monitoring => $monitoring,
        people     => $people,
        events     => $events,
        raw_count  => $raw_count,
        dossier    => $dossier,
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

1;
