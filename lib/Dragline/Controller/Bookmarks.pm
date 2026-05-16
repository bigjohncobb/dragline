package Dragline::Controller::Bookmarks;
use strict;
use warnings;
use utf8;

use Mojo::Base 'Mojolicious::Controller', -signatures;

sub index ($c) {
    my $user_id = $c->current_user->{id};

    my $bookmarks = $c->db->selectall_arrayref(
        q{SELECT b.*, rc.source_title, rc.source_url, t.canonical_name AS target_name
          FROM bookmarks b
          JOIN raw_content rc ON rc.id = b.raw_content_id
          JOIN targets t ON t.id = rc.target_id
          WHERE b.user_id = ?
          ORDER BY b.created_at DESC},
        { Slice => {} }, $user_id,
    );

    my $collections = $c->db->selectall_arrayref(
        q{SELECT bc.*,
                 (SELECT COUNT(*) FROM bookmark_collection_items WHERE collection_id = bc.id) AS item_count
          FROM bookmark_collections bc
          WHERE bc.user_id = ?
          ORDER BY bc.name ASC},
        { Slice => {} }, $user_id,
    );

    $c->stash(
        bookmarks   => $bookmarks,
        collections => $collections,
    );
    $c->render(template => 'bookmarks/index');
}

sub create ($c) {
    unless ($c->validate_csrf) {
        $c->render(text => 'Forbidden', status => 403);
        return;
    }

    my $user_id       = $c->current_user->{id};
    my $raw_content_id = $c->param('raw_content_id');

    eval {
        $c->db->do(
            q{INSERT INTO bookmarks (id, user_id, raw_content_id, created_at)
              VALUES (?, ?, ?, datetime('now'))
              ON CONFLICT(user_id, raw_content_id) DO NOTHING},
            undef, $c->new_uuid, $user_id, $raw_content_id,
        );
    };
    if ($@) {
        $c->flash(error => 'Failed to create bookmark.');
    } else {
        $c->flash(success => 'Bookmarked.');
    }

    my $back = $c->req->headers->referer // '/bookmarks';
    $c->redirect_to($back);
}

sub delete ($c) {
    unless ($c->validate_csrf) {
        $c->render(text => 'Forbidden', status => 403);
        return;
    }

    my $id      = $c->param('id');
    my $user_id = $c->current_user->{id};

    $c->db->do(
        q{DELETE FROM bookmarks WHERE id = ? AND user_id = ?},
        undef, $id, $user_id,
    );

    $c->flash(success => 'Bookmark removed.');
    my $back = $c->req->headers->referer // '/bookmarks';
    $c->redirect_to($back);
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

    eval {
        $c->db->do(
            q{INSERT INTO bookmark_collections (id, user_id, name, created_at)
              VALUES (?, ?, ?, datetime('now'))},
            undef, $c->new_uuid, $user_id, $name,
        );
    };
    if ($@) {
        if ($@ =~ /UNIQUE constraint failed/) {
            $c->flash(error => 'A collection with that name already exists.');
        } else {
            $c->flash(error => 'Failed to create collection.');
        }
    } else {
        $c->flash(success => 'Collection created.');
    }

    $c->redirect_to('/bookmarks');
}

sub add_to_collection ($c) {
    unless ($c->validate_csrf) {
        $c->render(text => 'Forbidden', status => 403);
        return;
    }

    my $user_id      = $c->current_user->{id};
    my $collection_id = $c->param('coll_id');
    my $bookmark_id   = $c->param('bookmark_id');

    # Verify ownership
    my $ok = $c->db->selectrow_array(
        q{SELECT 1 FROM bookmark_collections WHERE id = ? AND user_id = ?},
        undef, $collection_id, $user_id,
    );
    unless ($ok) {
        $c->render(text => 'Not found', status => 404);
        return;
    }

    $ok = $c->db->selectrow_array(
        q{SELECT 1 FROM bookmarks WHERE id = ? AND user_id = ?},
        undef, $bookmark_id, $user_id,
    );
    unless ($ok) {
        $c->render(text => 'Not found', status => 404);
        return;
    }

    eval {
        $c->db->do(
            q{INSERT INTO bookmark_collection_items (collection_id, bookmark_id, added_at)
              VALUES (?, ?, datetime('now'))
              ON CONFLICT(collection_id, bookmark_id) DO NOTHING},
            undef, $collection_id, $bookmark_id,
        );
    };
    if ($@) {
        $c->flash(error => 'Failed to add to collection.');
    } else {
        $c->flash(success => 'Added to collection.');
    }

    $c->redirect_to('/bookmarks');
}

sub show_collection ($c) {
    my $coll_id  = $c->param('coll_id');
    my $user_id  = $c->current_user->{id};

    my $collection = $c->db->selectrow_hashref(
        q{SELECT * FROM bookmark_collections WHERE id = ? AND user_id = ?},
        undef, $coll_id, $user_id,
    );
    unless ($collection) {
        $c->reply->not_found;
        return;
    }

    my $items = $c->db->selectall_arrayref(
        q{SELECT b.*, rc.source_title, rc.source_url, t.canonical_name AS target_name
          FROM bookmark_collection_items bci
          JOIN bookmarks b ON b.id = bci.bookmark_id
          JOIN raw_content rc ON rc.id = b.raw_content_id
          JOIN targets t ON t.id = rc.target_id
          WHERE bci.collection_id = ?
          ORDER BY bci.added_at DESC},
        { Slice => {} }, $coll_id,
    );

    my $collections = $c->db->selectall_arrayref(
        q{SELECT bc.*,
                 (SELECT COUNT(*) FROM bookmark_collection_items WHERE collection_id = bc.id) AS item_count
          FROM bookmark_collections bc
          WHERE bc.user_id = ?
          ORDER BY bc.name ASC},
        { Slice => {} }, $user_id,
    );

    $c->stash(
        collection  => $collection,
        items       => $items,
        collections => $collections,
    );
    $c->render(template => 'bookmarks/collection');
}

sub remove_from_collection ($c) {
    unless ($c->validate_csrf) {
        $c->render(text => 'Forbidden', status => 403);
        return;
    }

    my $coll_id     = $c->param('coll_id');
    my $bookmark_id = $c->param('bookmark_id');
    my $user_id     = $c->current_user->{id};

    my $ok = $c->db->selectrow_array(
        q{SELECT 1 FROM bookmark_collections WHERE id = ? AND user_id = ?},
        undef, $coll_id, $user_id,
    );
    unless ($ok) {
        $c->render(text => 'Not found', status => 404);
        return;
    }

    $c->db->do(
        q{DELETE FROM bookmark_collection_items WHERE collection_id = ? AND bookmark_id = ?},
        undef, $coll_id, $bookmark_id,
    );

    $c->flash(success => 'Removed from collection.');
    $c->redirect_to("/bookmarks/collections/$coll_id");
}

sub rename_collection ($c) {
    unless ($c->validate_csrf) {
        $c->render(text => 'Forbidden', status => 403);
        return;
    }

    my $coll_id = $c->param('coll_id');
    my $user_id = $c->current_user->{id};
    my $new_name = $c->param('name') // '';
    $new_name =~ s/^\s+|\s+$//g;

    unless (length($new_name)) {
        $c->flash(error => 'Collection name is required.');
        $c->redirect_to("/bookmarks/collections/$coll_id");
        return;
    }

    eval {
        $c->db->do(
            q{UPDATE bookmark_collections SET name = ? WHERE id = ? AND user_id = ?},
            undef, $new_name, $coll_id, $user_id,
        );
    };
    if ($@) {
        if ($@ =~ /UNIQUE constraint failed/) {
            $c->flash(error => 'A collection with that name already exists.');
        } else {
            $c->flash(error => 'Failed to rename collection.');
        }
    } else {
        $c->flash(success => 'Collection renamed.');
    }

    $c->redirect_to("/bookmarks/collections/$coll_id");
}

sub delete_collection ($c) {
    unless ($c->validate_csrf) {
        $c->render(text => 'Forbidden', status => 403);
        return;
    }

    my $coll_id = $c->param('coll_id');
    my $user_id = $c->current_user->{id};

    $c->db->do(
        q{DELETE FROM bookmark_collections WHERE id = ? AND user_id = ?},
        undef, $coll_id, $user_id,
    );

    $c->flash(success => 'Collection deleted.');
    $c->redirect_to('/bookmarks');
}

sub saved_queries ($c) {
    my $user_id = $c->current_user->{id};

    my $queries = $c->db->selectall_arrayref(
        q{SELECT * FROM saved_queries
          WHERE user_id = ?
          ORDER BY created_at DESC},
        { Slice => {} }, $user_id,
    );

    $c->stash(queries => $queries);
    $c->render(template => 'bookmarks/saved_queries');
}

sub save_query ($c) {
    unless ($c->validate_csrf) {
        $c->render(text => 'Forbidden', status => 403);
        return;
    }

    my $user_id    = $c->current_user->{id};
    my $label      = $c->param('label') // '';
    my $query_text = $c->param('query_text') // '';
    my $search_type = $c->param('search_type') // '';

    $label =~ s/^\s+|\s+$//g;
    $query_text =~ s/^\s+|\s+$//g;

    unless (length($label) && length($query_text) && grep { $_ eq $search_type } qw(text semantic)) {
        $c->flash(error => 'Label, query, and valid search type are required.');
        my $back = $c->req->headers->referer // '/saved-queries';
        $c->redirect_to($back);
        return;
    }

    eval {
        $c->db->do(
            q{INSERT INTO saved_queries (id, user_id, label, query_text, search_type, created_at)
              VALUES (?, ?, ?, ?, ?, datetime('now'))},
            undef, $c->new_uuid, $user_id, $label, $query_text, $search_type,
        );
    };
    if ($@) {
        $c->flash(error => 'Failed to save query.');
    } else {
        $c->flash(success => 'Query saved.');
    }

    my $back = $c->req->headers->referer // '/saved-queries';
    $c->redirect_to($back);
}

sub delete_query ($c) {
    unless ($c->validate_csrf) {
        $c->render(text => 'Forbidden', status => 403);
        return;
    }

    my $id      = $c->param('id');
    my $user_id = $c->current_user->{id};

    $c->db->do(
        q{DELETE FROM saved_queries WHERE id = ? AND user_id = ?},
        undef, $id, $user_id,
    );

    $c->flash(success => 'Saved query deleted.');
    my $back = $c->req->headers->referer // '/saved-queries';
    $c->redirect_to($back);
}

1;
