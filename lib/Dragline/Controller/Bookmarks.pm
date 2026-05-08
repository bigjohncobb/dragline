package Dragline::Controller::Bookmarks;
use strict;
use warnings;
use utf8;

use Mojo::Base 'Mojolicious::Controller', -signatures;

sub index ($c) {
    my $user_id = $c->current_user->{id};

    my $collections = $c->db->selectall_arrayref(
        q{SELECT bc.*,
                 (SELECT COUNT(*) FROM bookmarks WHERE collection_id = bc.id) AS bookmark_count
          FROM bookmark_collections bc
          WHERE bc.user_id = ?
          ORDER BY bc.name ASC},
        { Slice => {} }, $user_id,
    );

    my $saved_queries = $c->db->selectall_arrayref(
        q{SELECT sq.*, t.canonical_name AS target_name
          FROM saved_queries sq
          LEFT JOIN targets t ON t.id = sq.target_id
          WHERE sq.user_id = ?
          ORDER BY sq.created_at DESC},
        { Slice => {} }, $user_id,
    );

    $c->stash(
        collections   => $collections,
        saved_queries => $saved_queries,
    );
    $c->render(template => 'bookmarks/index');
}

sub create_collection ($c) {
    unless ($c->validate_csrf) {
        $c->render(text => 'Forbidden', status => 403);
        return;
    }

    my $user_id = $c->current_user->{id};
    my $name    = $c->param('name') // '';
    $name =~ s/^\s+|\s+$//g;

    unless (length($name)) {
        $c->flash(error => 'Collection name is required.');
        $c->redirect_to('/bookmarks');
        return;
    }

    my $id = $c->new_uuid;
    eval {
        $c->db->do(
            q{INSERT INTO bookmark_collections (id, user_id, name, created_at, updated_at)
              VALUES (?, ?, ?, datetime('now'), datetime('now'))},
            undef, $id, $user_id, $name,
        );
    };
    if ($@) {
        $c->flash(error => 'Failed to create collection.');
        $c->redirect_to('/bookmarks');
        return;
    }

    $c->flash(success => 'Collection created.');
    $c->redirect_to('/bookmarks');
}

sub delete_collection ($c) {
    unless ($c->validate_csrf) {
        $c->render(text => 'Forbidden', status => 403);
        return;
    }

    my $id = $c->param('id');
    $c->db->do(
        q{DELETE FROM bookmark_collections WHERE id = ? AND user_id = ?},
        undef, $id, $c->current_user->{id},
    );

    $c->flash(success => 'Collection deleted.');
    $c->redirect_to('/bookmarks');
}

sub show_collection ($c) {
    my $id = $c->param('id');
    my $user_id = $c->current_user->{id};

    my $collection = $c->db->selectrow_hashref(
        q{SELECT * FROM bookmark_collections WHERE id = ? AND user_id = ?},
        undef, $id, $user_id,
    );
    unless ($collection) {
        $c->reply->not_found;
        return;
    }

    my $bookmarks = $c->db->selectall_arrayref(
        q{SELECT b.*, t.canonical_name AS target_name, t.entity_type
          FROM bookmarks b
          JOIN targets t ON t.id = b.target_id
          WHERE b.collection_id = ?
          ORDER BY t.canonical_name ASC},
        { Slice => {} }, $id,
    );

    $c->stash(
        collection => $collection,
        bookmarks  => $bookmarks,
    );
    $c->render(template => 'bookmarks/collection');
}

sub add_bookmark ($c) {
    unless ($c->validate_csrf) {
        $c->render(text => 'Forbidden', status => 403);
        return;
    }

    my $collection_id = $c->param('collection_id');
    my $target_id     = $c->param('target_id');
    my $user_id       = $c->current_user->{id};

    my $collection = $c->db->selectrow_hashref(
        q{SELECT 1 FROM bookmark_collections WHERE id = ? AND user_id = ?},
        undef, $collection_id, $user_id,
    );
    unless ($collection) {
        $c->render(text => 'Not found', status => 404);
        return;
    }

    my $id = $c->new_uuid;
    eval {
        $c->db->do(
            q{INSERT INTO bookmarks (id, collection_id, target_id, created_at)
              VALUES (?, ?, ?, datetime('now'))},
            undef, $id, $collection_id, $target_id,
        );
    };
    if ($@) {
        $c->flash(error => 'Already bookmarked in this collection.');
        $c->redirect_to("/bookmarks/$collection_id");
        return;
    }

    $c->flash(success => 'Bookmark added.');
    $c->redirect_to("/bookmarks/$collection_id");
}

sub delete_bookmark ($c) {
    unless ($c->validate_csrf) {
        $c->render(text => 'Forbidden', status => 403);
        return;
    }

    my $id = $c->param('bookmark_id');
    my $collection_id = $c->param('collection_id');

    $c->db->do(
        q{DELETE FROM bookmarks WHERE id = ? AND collection_id = ?},
        undef, $id, $collection_id,
    );

    $c->flash(success => 'Bookmark removed.');
    $c->redirect_to("/bookmarks/$collection_id");
}

sub create_saved_query ($c) {
    unless ($c->validate_csrf) {
        $c->render(text => 'Forbidden', status => 403);
        return;
    }

    my $user_id   = $c->current_user->{id};
    my $name      = $c->param('name') // '';
    my $query_type = $c->param('query_type') // 'text';
    my $query_text = $c->param('query_text') // '';
    my $target_id  = $c->param('target_id') // undef;

    $name =~ s/^\s+|\s+$//g;
    $query_text =~ s/^\s+|\s+$//g;

    unless (length($name) && length($query_text)) {
        $c->flash(error => 'Name and query are required.');
        $c->redirect_to('/bookmarks');
        return;
    }

    my $id = $c->new_uuid;
    eval {
        $c->db->do(
            q{INSERT INTO saved_queries (id, user_id, name, query_type, query_text, target_id, created_at)
              VALUES (?, ?, ?, ?, ?, ?, datetime('now'))},
            undef, $id, $user_id, $name, $query_type, $query_text, $target_id,
        );
    };
    if ($@) {
        $c->flash(error => 'Failed to save query.');
        $c->redirect_to('/bookmarks');
        return;
    }

    $c->flash(success => 'Query saved.');
    $c->redirect_to('/bookmarks');
}

sub delete_saved_query ($c) {
    unless ($c->validate_csrf) {
        $c->render(text => 'Forbidden', status => 403);
        return;
    }

    my $id = $c->param('id');
    $c->db->do(
        q{DELETE FROM saved_queries WHERE id = ? AND user_id = ?},
        undef, $id, $c->current_user->{id},
    );

    $c->flash(success => 'Saved query deleted.');
    $c->redirect_to('/bookmarks');
}

1;
