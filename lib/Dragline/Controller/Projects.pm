package Dragline::Controller::Projects;
use strict;
use warnings;
use utf8;

use Mojo::Base 'Mojolicious::Controller', -signatures;

sub index ($c) {
    my $projects = $c->db->selectall_arrayref(
        q{SELECT p.*, COUNT(t.id) AS target_count
          FROM projects p
          LEFT JOIN targets t ON t.project_id = p.id
          GROUP BY p.id
          ORDER BY p.name ASC},
        { Slice => {} },
    );
    $c->stash(projects => $projects);
    $c->render(template => 'projects/index');
}

sub new_form ($c) {
    $c->render(template => 'projects/new');
}

sub create ($c) {
    unless ($c->validate_csrf) {
        $c->render(template => 'projects/new', status => 403);
        return;
    }

    unless ($c->rate_limit('write')) {
        $c->flash(error => 'Too many requests. Please wait and try again.');
        $c->redirect_to('/projects/new');
        return;
    }

    my $name = $c->param('name') // '';
    $name =~ s/^\s+|\s+$//g;

    unless (length($name)) {
        $c->flash(error => 'Project name is required.');
        $c->redirect_to('/projects/new');
        return;
    }

    my $id   = $c->new_uuid;
    my $desc = $c->param('description') // '';

    eval {
        $c->db->do(
            q{INSERT INTO projects (id, name, description, created_at, updated_at)
              VALUES (?, ?, ?, datetime('now'), datetime('now'))},
            undef, $id, $name, $desc,
        );
    };
    if ($@) {
        $c->flash(error => 'Failed to create project.');
        $c->redirect_to('/projects/new');
        return;
    }

    $c->log_audit('create', 'project', $id, { name => $name });
    $c->flash(success => "Project \"$name\" created.");
    $c->redirect_to("/projects/$id");
}

sub show ($c) {
    my $id = $c->param('id');

    my $project = $c->db->selectrow_hashref(
        q{SELECT p.*, COUNT(t.id) AS target_count
          FROM projects p
          LEFT JOIN targets t ON t.project_id = p.id
          WHERE p.id = ?
          GROUP BY p.id},
        undef, $id,
    );

    unless ($project) {
        $c->reply->not_found;
        return;
    }

    my $targets = $c->db->selectall_arrayref(
        q{SELECT * FROM targets WHERE project_id = ? ORDER BY canonical_name ASC},
        { Slice => {} }, $id,
    );

    $c->stash(project => $project, targets => $targets);
    $c->render(template => 'projects/show');
}

sub edit_form ($c) {
    my $id      = $c->param('id');
    my $project = $c->db->selectrow_hashref(
        q{SELECT * FROM projects WHERE id = ?}, undef, $id,
    );
    unless ($project) {
        $c->reply->not_found;
        return;
    }
    $c->stash(project => $project);
    $c->render(template => 'projects/edit');
}

sub update ($c) {
    unless ($c->validate_csrf) {
        $c->render(text => 'Forbidden', status => 403);
        return;
    }

    unless ($c->rate_limit('write')) {
        $c->flash(error => 'Too many requests. Please wait and try again.');
        return $c->redirect_to('/projects/' . $c->param('id') . '/edit');
    }

    my $id   = $c->param('id');
    my $name = $c->param('name') // '';
    $name =~ s/^\s+|\s+$//g;

    unless (length($name)) {
        $c->flash(error => 'Project name is required.');
        $c->redirect_to("/projects/$id/edit");
        return;
    }

    my $project = $c->db->selectrow_hashref(
        q{SELECT * FROM projects WHERE id = ?}, undef, $id,
    );
    unless ($project) {
        $c->reply->not_found;
        return;
    }

    $c->db->do(
        q{UPDATE projects SET name = ?, description = ? WHERE id = ?},
        undef, $name, ($c->param('description') // ''), $id,
    );

    $c->log_audit('update', 'project', $id, { name => $name });
    $c->flash(success => 'Project updated.');
    $c->redirect_to("/projects/$id");
}

sub delete ($c) {
    unless ($c->validate_csrf) {
        $c->render(text => 'Forbidden', status => 403);
        return;
    }

    unless ($c->rate_limit('write')) {
        $c->flash(error => 'Too many requests. Please wait and try again.');
        return $c->redirect_to('/projects');
    }

    my $id = $c->param('id');

    my $target_count = $c->db->selectrow_array(
        q{SELECT COUNT(*) FROM targets WHERE project_id = ?}, undef, $id,
    );

    if ($target_count > 0) {
        $c->flash(error => 'Remove all targets before deleting this project.');
        $c->redirect_to("/projects/$id");
        return;
    }

    $c->db->do(q{DELETE FROM projects WHERE id = ?}, undef, $id);
    $c->log_audit('delete', 'project', $id);
    $c->flash(success => 'Project deleted.');
    $c->redirect_to('/projects');
}

1;
