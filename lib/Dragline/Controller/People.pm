package Dragline::Controller::People;
use strict;
use warnings;
use utf8;

use Mojo::Base 'Mojolicious::Controller', -signatures;

my @RELATIONSHIP_TYPES = qw(
    revolving_door shared_board political_affiliation family_ownership legal_co_appearance
);

sub index ($c) {
    my $search = $c->param('search') // '';
    $search =~ s/^\s+|\s+$//g;

    my @where;
    my @bind;

    if (length($search)) {
        push @where, 'LOWER(p.canonical_name) LIKE ?';
        push @bind, '%' . lc($search) . '%';
    }

    push @where, 'p.merged_into IS NULL';

    my $where_sql = @where ? 'WHERE ' . join(' AND ', @where) : '';

    my $people = $c->db->selectall_arrayref(
        qq{SELECT p.*,
            COUNT(DISTINCT pr.id)        AS role_count,
            COUNT(DISTINCT pr.target_id) AS target_count
          FROM people p
          LEFT JOIN person_roles pr ON pr.person_id = p.id
          $where_sql
          GROUP BY p.id
          ORDER BY p.canonical_name ASC},
        { Slice => {} }, @bind,
    );
    $c->stash(people => $people, search => $search);
    $c->render(template => 'people/list');
}

sub new_form ($c) {
    $c->render(template => 'people/new');
}

sub create ($c) {
    unless ($c->validate_csrf) {
        $c->render(text => 'Forbidden', status => 403);
        return;
    }

    unless ($c->rate_limit('write')) {
        $c->flash(error => 'Too many requests. Please wait and try again.');
        $c->redirect_to('/people/new');
        return;
    }

    my $name = $c->param('canonical_name') // '';
    $name =~ s/^\s+|\s+$//g;

    unless (length($name)) {
        $c->flash(error => 'Name is required.');
        $c->redirect_to('/people/new');
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
            ($c->param('nationality')  // undef),
            ($c->param('bio_summary')  // undef),
        );
    };
    if ($@) {
        $c->flash(error => 'Failed to create person.');
        $c->redirect_to('/people/new');
        return;
    }

    $c->log_audit('create', 'person', $id, { canonical_name => $name });
    $c->redirect_to("/people/$id");
}

sub show ($c) {
    my $id = $c->param('id');

    my $person = $c->db->selectrow_hashref(
        q{SELECT * FROM people WHERE id = ?}, undef, $id,
    );
    unless ($person) {
        $c->reply->not_found;
        return;
    }

    my $roles = $c->db->selectall_arrayref(
        q{SELECT pr.*, t.canonical_name AS target_name
          FROM person_roles pr
          JOIN targets t ON t.id = pr.target_id
          WHERE pr.person_id = ?
          ORDER BY pr.is_current DESC, pr.started_at DESC},
        { Slice => {} }, $id,
    );

    my $connections = $c->db->selectall_arrayref(
        q{SELECT pc.*,
            CASE WHEN pc.person_id_a = ? THEN pb.canonical_name ELSE pa.canonical_name END AS other_name,
            CASE WHEN pc.person_id_a = ? THEN pc.person_id_b ELSE pc.person_id_a END AS other_id
          FROM person_connections pc
          JOIN people pa ON pa.id = pc.person_id_a
          JOIN people pb ON pb.id = pc.person_id_b
          WHERE pc.person_id_a = ? OR pc.person_id_b = ?
          ORDER BY pc.created_at DESC},
        { Slice => {} }, $id, $id, $id, $id,
    );

    my $all_targets = $c->db->selectall_arrayref(
        q{SELECT id, canonical_name FROM targets WHERE active = 1 ORDER BY canonical_name ASC},
        { Slice => {} },
    );

    my $all_people = $c->db->selectall_arrayref(
        q{SELECT id, canonical_name FROM people WHERE id != ? AND merged_into IS NULL ORDER BY canonical_name ASC},
        { Slice => {} }, $id,
    );

    $c->stash(
        person           => $person,
        roles            => $roles,
        connections      => $connections,
        all_targets      => $all_targets,
        all_people       => $all_people,
        relationship_types => \@RELATIONSHIP_TYPES,
    );
    $c->render(template => 'people/show');
}

sub edit_form ($c) {
    my $id     = $c->param('id');
    my $person = $c->db->selectrow_hashref(
        q{SELECT * FROM people WHERE id = ?}, undef, $id,
    );
    unless ($person) {
        $c->reply->not_found;
        return;
    }
    $c->stash(person => $person);
    $c->render(template => 'people/edit');
}

sub update ($c) {
    unless ($c->validate_csrf) {
        $c->render(text => 'Forbidden', status => 403);
        return;
    }

    unless ($c->rate_limit('write')) {
        $c->flash(error => 'Too many requests. Please wait and try again.');
        return $c->redirect_to('/people/' . $c->param('id') . '/edit');
    }

    my $id   = $c->param('id');
    my $name = $c->param('canonical_name') // '';
    $name =~ s/^\s+|\s+$//g;

    unless (length($name)) {
        $c->flash(error => 'Name is required.');
        $c->redirect_to("/people/$id/edit");
        return;
    }

    my $person = $c->db->selectrow_hashref(
        q{SELECT * FROM people WHERE id = ?}, undef, $id,
    );
    unless ($person) {
        $c->reply->not_found;
        return;
    }

    $c->db->do(
        q{UPDATE people SET
            canonical_name = ?, canonical_name_lower = ?,
            nationality = ?, bio_summary = ?
          WHERE id = ?},
        undef,
        $name, lc($name),
        ($c->param('nationality') // undef),
        ($c->param('bio_summary') // undef),
        $id,
    );

    $c->log_audit('update', 'person', $id, { canonical_name => $name });
    $c->flash(success => 'Person updated.');
    $c->redirect_to("/people/$id");
}

sub delete ($c) {
    unless ($c->validate_csrf) {
        $c->render(text => 'Forbidden', status => 403);
        return;
    }

    unless ($c->rate_limit('write')) {
        $c->flash(error => 'Too many requests. Please wait and try again.');
        return $c->redirect_to('/people');
    }

    my $id     = $c->param('id');
    my $person = $c->db->selectrow_hashref(
        q{SELECT * FROM people WHERE id = ?}, undef, $id,
    );
    unless ($person) {
        $c->reply->not_found;
        return;
    }

    my ($merge_target_count) = $c->db->selectrow_array(
        q{SELECT COUNT(*) FROM people WHERE merged_into = ?}, undef, $id,
    );
    if ($merge_target_count) {
        $c->flash(error => 'Cannot delete: other people are merged into this person. Reassign or delete those records first.');
        return $c->redirect_to("/people/$id");
    }

    $c->db->do(q{DELETE FROM people WHERE id = ?}, undef, $id);
    $c->log_audit('delete', 'person', $id, { canonical_name => $person->{canonical_name} });
    $c->flash(success => 'Person deleted.');
    $c->redirect_to('/people');
}

sub add_role ($c) {
    unless ($c->validate_csrf) {
        $c->render(text => 'Forbidden', status => 403);
        return;
    }

    unless ($c->rate_limit('write')) {
        $c->flash(error => 'Too many requests. Please wait and try again.');
        return $c->redirect_to('/people/' . $c->param('id'));
    }

    my $person_id = $c->param('id');
    my $target_id = $c->param('target_id') // '';
    my $title     = $c->param('title')     // '';
    $title =~ s/^\s+|\s+$//g;

    unless (length($person_id) && length($target_id) && length($title)) {
        $c->flash(error => 'Person, target, and title are all required.');
        $c->redirect_to("/people/$person_id");
        return;
    }

    my $role_id    = $c->new_uuid;
    my $is_current = $c->param('is_current') // 1;
    my $started_at = $c->param('started_at') || undef;
    my $ended_at   = $c->param('ended_at')   || undef;
    my $source_url = $c->param('source_url') || undef;

    eval {
        $c->db->do(
            q{INSERT INTO person_roles
                (id, person_id, target_id, title, started_at, ended_at, is_current, source_url,
                 created_at, updated_at)
              VALUES (?, ?, ?, ?, ?, ?, ?, ?, datetime('now'), datetime('now'))},
            undef,
            $role_id, $person_id, $target_id, $title,
            $started_at, $ended_at, $is_current ? 1 : 0, $source_url,
        );
    };
    if ($@) {
        $c->flash(error => 'Failed to add role.');
        $c->redirect_to("/people/$person_id");
        return;
    }

    $c->log_audit('add_role', 'person', $person_id, { title => $title, target_id => $target_id });
    $c->flash(success => 'Role added.');
    $c->redirect_to("/people/$person_id");
}

sub delete_role ($c) {
    unless ($c->validate_csrf) {
        $c->render(text => 'Forbidden', status => 403);
        return;
    }

    my $person_id = $c->param('id');
    my $role_id   = $c->param('role_id');
    $c->db->do(
        q{DELETE FROM person_roles WHERE id = ? AND person_id = ?},
        undef, $role_id, $person_id,
    );
    $c->log_audit('delete_role', 'person', $person_id, { role_id => $role_id });
    $c->flash(success => 'Role removed.');
    $c->redirect_to("/people/$person_id");
}

sub add_connection ($c) {
    unless ($c->validate_csrf) {
        $c->render(text => 'Forbidden', status => 403);
        return;
    }

    unless ($c->rate_limit('write')) {
        $c->flash(error => 'Too many requests. Please wait and try again.');
        return $c->redirect_to('/people/' . $c->param('id'));
    }

    my $person_id        = $c->param('id');
    my $other_person_id  = $c->param('other_person_id') // '';
    my $relationship_type = $c->param('relationship_type') // '';

    unless (length($other_person_id)) {
        $c->flash(error => 'Please select the other person.');
        $c->redirect_to("/people/$person_id");
        return;
    }

    unless (grep { $_ eq $relationship_type } @RELATIONSHIP_TYPES) {
        $c->flash(error => 'Invalid relationship type.');
        $c->redirect_to("/people/$person_id");
        return;
    }

    my $a_exists = $c->db->selectrow_array(
        q{SELECT 1 FROM people WHERE id = ?}, undef, $person_id,
    );
    my $b_exists = $c->db->selectrow_array(
        q{SELECT 1 FROM people WHERE id = ?}, undef, $other_person_id,
    );

    unless ($a_exists && $b_exists) {
        $c->flash(error => 'One or both people not found.');
        $c->redirect_to("/people/$person_id");
        return;
    }

    # Enforce canonical ordering: person_id_a < person_id_b
    my ($id_a, $id_b) = ($person_id lt $other_person_id)
        ? ($person_id, $other_person_id)
        : ($other_person_id, $person_id);

    my $conn_id    = $c->new_uuid;
    my $notes      = $c->param('notes')      || undef;
    my $source_url = $c->param('source_url') || undef;

    eval {
        $c->db->do(
            q{INSERT INTO person_connections
                (id, person_id_a, person_id_b, relationship_type, notes, source_url, created_at)
              VALUES (?, ?, ?, ?, ?, ?, datetime('now'))},
            undef, $conn_id, $id_a, $id_b, $relationship_type, $notes, $source_url,
        );
    };
    if ($@) {
        if ($@ =~ /UNIQUE constraint failed/) {
            $c->flash(error => 'Connection already exists between these two people.');
        } else {
            $c->flash(error => 'Failed to add connection.');
        }
        $c->redirect_to("/people/$person_id");
        return;
    }

    $c->log_audit('add_connection', 'person', $person_id, {
        other_person_id   => $other_person_id,
        relationship_type => $relationship_type,
    });
    $c->flash(success => 'Connection added.');
    $c->redirect_to("/people/$person_id");
}

sub delete_connection ($c) {
    unless ($c->validate_csrf) {
        $c->render(text => 'Forbidden', status => 403);
        return;
    }

    my $person_id = $c->param('id');
    my $conn_id   = $c->param('conn_id');
    $c->db->do(
        q{DELETE FROM person_connections WHERE id = ?},
        undef, $conn_id,
    );
    $c->log_audit('delete_connection', 'person', $person_id, { conn_id => $conn_id });
    $c->flash(success => 'Connection removed.');
    $c->redirect_to("/people/$person_id");
}

sub merge ($c) {
    unless ($c->validate_csrf) {
        $c->render(text => 'Forbidden', status => 403);
        return;
    }

    unless ($c->require_admin) {
        return $c->redirect_to('/people/' . $c->param('id'));
    }

    unless ($c->rate_limit('write')) {
        $c->flash(error => 'Too many requests. Please wait and try again.');
        return $c->redirect_to('/people/' . $c->param('id'));
    }

    my $source_id = $c->param('id');
    my $target_id = $c->param('target_person_id') // '';

    unless (length($target_id)) {
        $c->flash(error => 'Please select the person to merge into.');
        return $c->redirect_to("/people/$source_id");
    }

    if ($source_id eq $target_id) {
        $c->flash(error => 'Cannot merge a person into itself.');
        return $c->redirect_to("/people/$source_id");
    }

    my $source = $c->db->selectrow_hashref(
        q{SELECT * FROM people WHERE id = ?}, undef, $source_id,
    );
    my $target = $c->db->selectrow_hashref(
        q{SELECT * FROM people WHERE id = ?}, undef, $target_id,
    );

    unless ($source && $target) {
        $c->flash(error => 'One or both people not found.');
        return $c->redirect_to("/people/$source_id");
    }

    if ($source->{merged_into}) {
        $c->flash(error => 'Source person has already been merged and cannot be merged again.');
        return $c->redirect_to("/people/$source_id");
    }

    if ($target->{merged_into}) {
        $c->flash(error => 'Target person has already been merged. Merge into the primary record instead.');
        return $c->redirect_to("/people/$source_id");
    }

    my $merge_note = $c->param('merge_note') // '';
    if (length($merge_note) > 2000) {
        $c->flash(error => 'Merge note exceeds maximum length of 2000 characters.');
        return $c->redirect_to("/people/$source_id");
    }

    my $roles_count = 0;
    my $conn_count  = 0;

    eval {
        $c->db->begin_work;

        my $ra = $c->db->do(
            q{UPDATE person_roles SET person_id = ? WHERE person_id = ?},
            undef, $target_id, $source_id,
        );
        $roles_count = ($ra && $ra ne '0E0') ? $ra : 0;

        my $conns = $c->db->selectall_arrayref(
            q{SELECT * FROM person_connections WHERE person_id_a = ? OR person_id_b = ?},
            { Slice => {} }, $source_id, $source_id,
        );

        for my $conn (@$conns) {
            my $a = $conn->{person_id_a};
            my $b = $conn->{person_id_b};
            my $type = $conn->{relationship_type};

            $a = $target_id if $a eq $source_id;
            $b = $target_id if $b eq $source_id;

            if ($a eq $b) {
                $c->db->do(q{DELETE FROM person_connections WHERE id = ?}, undef, $conn->{id});
                next;
            }

            my ($new_a, $new_b) = ($a lt $b) ? ($a, $b) : ($b, $a);

            my $dup = $c->db->selectrow_array(
                q{SELECT 1 FROM person_connections WHERE person_id_a = ? AND person_id_b = ? AND relationship_type = ? AND id != ?},
                undef, $new_a, $new_b, $type, $conn->{id},
            );
            if ($dup) {
                $c->db->do(q{DELETE FROM person_connections WHERE id = ?}, undef, $conn->{id});
                next;
            }

            $c->db->do(
                q{UPDATE person_connections SET person_id_a = ?, person_id_b = ? WHERE id = ?},
                undef, $new_a, $new_b, $conn->{id},
            );
            $conn_count++;
        }

        $c->db->do(
            q{UPDATE people SET merged_into = ? WHERE id = ?},
            undef, $target_id, $source_id,
        );

        my $log_id = $c->new_uuid;
        my $user   = $c->current_user;
        $c->db->do(
            q{INSERT INTO person_merge_log (id, primary_person_id, merged_person_id, merged_person_name, roles_reassigned, connections_reassigned, performed_by, merge_note, created_at)
              VALUES (?, ?, ?, ?, ?, ?, ?, ?, datetime('now'))},
            undef,
            $log_id, $target_id, $source_id, $source->{canonical_name},
            $roles_count, $conn_count,
            ($user ? $user->{id} : undef),
            (length($merge_note) ? $merge_note : undef),
        );

        $c->db->commit;
    };

    if ($@) {
        eval { $c->db->rollback };
        $c->flash(error => 'Merge failed: ' . $@);
        return $c->redirect_to("/people/$source_id");
    }

    $c->log_audit('merge', 'person', $source_id, {
        target_person_id       => $target_id,
        roles_reassigned       => $roles_count,
        connections_reassigned => $conn_count,
    });
    $c->flash(success => 'Person merged successfully.');
    $c->redirect_to("/people/$target_id");
}

1;
