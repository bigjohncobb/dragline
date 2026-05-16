package Dragline::Controller::Search;
use strict;
use warnings;
use utf8;

use Mojo::Base 'Mojolicious::Controller', -signatures;

sub semantic ($c) {
    my $query = $c->param('q') // '';
    $query =~ s/^\s+|\s+$//g;

    my $target_id = $c->param('target_id') // '';
    my $page  = $c->param('page') // 1;
    $page     = 1 unless $page =~ /^\d+$/ && $page > 0;
    my $per_page = 20;
    my $offset   = ($page - 1) * $per_page;

    my $dbh = $c->db;
    my $saved_queries = $dbh->selectall_arrayref(
        q{SELECT * FROM saved_queries
          WHERE user_id = ?
          ORDER BY created_at DESC},
        { Slice => {} }, $c->current_user->{id},
    );

    unless (length($query)) {
        $c->stash(results => [], query => '', target_id => $target_id, saved_queries => $saved_queries, page => 1, total => 0, per_page => $per_page);
        $c->render(template => 'search/semantic');
        return;
    }
    my $settings_getter = sub {
        my ($key) = @_;
        my $row = $dbh->selectrow_hashref(
            q{SELECT value, is_encrypted FROM settings WHERE key=?},
            undef, $key,
        );
        return undef unless $row;
        return undef unless defined($row->{value}) && $row->{value} ne '';
        return $row->{is_encrypted}
            ? $c->decrypt_value($row->{value})
            : $row->{value};
    };

    my $embedding = eval {
        require Dragline::Embed;
        Dragline::Embed::embed($dbh, $settings_getter, $query);
    };

    unless ($embedding && ref($embedding) eq 'ARRAY' && @$embedding) {
        $c->stash(results => [], query => $query, target_id => $target_id, error => 'Failed to generate embedding for query.', saved_queries => $saved_queries, page => 1, total => 0, per_page => $per_page);
        $c->render(template => 'search/semantic');
        return;
    }

    my $blob = pack('f*', @$embedding);
    my $dims = scalar @$embedding;

    my @where;
    my @bind = ($blob, $dims);

    push @where, 'rce.dimensions = ?';

    if ($target_id) {
        push @where, 'rc.target_id = ?';
        push @bind, $target_id;
    }

    my $where_sql = @where ? 'WHERE ' . join(' AND ', @where) : '';

    my ($total) = $dbh->selectrow_array(
        qq{SELECT COUNT(*) FROM raw_content_embeddings rce
           JOIN raw_content rc ON rc.id = rce.raw_content_id
           $where_sql},
        undef, @bind,
    );

    my $results = $dbh->selectall_arrayref(
        qq{SELECT
            rc.id, rc.target_id, rc.source_type, rc.source_url, rc.source_title,
            rc.content_text, rc.significance_tier, rc.word_count, rc.created_at,
            t.canonical_name AS target_name,
            vec_distance_cosine(rce.embedding, ?) AS distance
          FROM raw_content_embeddings rce
          JOIN raw_content rc ON rc.id = rce.raw_content_id
          JOIN targets t ON t.id = rc.target_id
          $where_sql
          ORDER BY distance ASC
          LIMIT ? OFFSET ?},
        { Slice => {} }, @bind, $per_page, $offset,
    );

    for my $r (@$results) {
        my $text = $r->{content_text} // '';
        if (length($text) > 300) {
            $text = substr($text, 0, 300) . "\x{2026}";
        }
        $r->{snippet} = $text;
    }

    $c->stash(
        results       => $results,
        query         => $query,
        target_id     => $target_id,
        saved_queries => $saved_queries,
        page          => $page,
        total         => $total,
        per_page      => $per_page,
    );
    $c->render(template => 'search/semantic');
}

sub text ($c) {
    my $query = $c->param('q') // '';
    $query =~ s/^\s+|\s+$//g;

    my $page  = $c->param('page') // 1;
    $page     = 1 unless $page =~ /^\d+$/ && $page > 0;
    my $per_page = 20;
    my $offset   = ($page - 1) * $per_page;

    my $dbh = $c->db;
    my $saved_queries = $dbh->selectall_arrayref(
        q{SELECT * FROM saved_queries
          WHERE user_id = ?
          ORDER BY created_at DESC},
        { Slice => {} }, $c->current_user->{id},
    );

    unless (length($query)) {
        $c->stash(results => [], query => '', saved_queries => $saved_queries, page => 1, total => 0, per_page => $per_page);
        $c->render(template => 'search/text');
        return;
    }

    my $like = '%' . $query . '%';
    my @results;

    my $targets = $dbh->selectall_arrayref(
        q{SELECT id, canonical_name, entity_type, country, notes
          FROM targets
          WHERE canonical_name LIKE ? OR notes LIKE ?
          ORDER BY canonical_name ASC
          LIMIT 50},
        { Slice => {} }, $like, $like,
    );
    my $target_count = scalar(@$targets);
    for my $t (@$targets) {
        push @results, {
            type    => 'target',
            id      => $t->{id},
            title   => $t->{canonical_name},
            subtype => $t->{entity_type},
            snippet => ($t->{notes} // ''),
        };
    }

    my $people = $dbh->selectall_arrayref(
        q{SELECT id, canonical_name, nationality, bio_summary
          FROM people
          WHERE merged_into IS NULL
            AND (canonical_name LIKE ? OR bio_summary LIKE ?)
          ORDER BY canonical_name ASC
          LIMIT 50},
        { Slice => {} }, $like, $like,
    );
    my $people_count = scalar(@$people);
    for my $p (@$people) {
        push @results, {
            type    => 'person',
            id      => $p->{id},
            title   => $p->{canonical_name},
            subtype => $p->{nationality} // '',
            snippet => ($p->{bio_summary} // ''),
        };
    }

    my $events = $dbh->selectall_arrayref(
        q{SELECT et.id, et.target_id, et.event_date, et.event_type, et.description,
                 t.canonical_name AS target_name
          FROM event_timeline et
          JOIN targets t ON t.id = et.target_id
          WHERE et.description LIKE ?
          ORDER BY et.event_date DESC
          LIMIT 50},
        { Slice => {} }, $like,
    );
    my $events_count = scalar(@$events);
    for my $e (@$events) {
        push @results, {
            type    => 'event',
            id      => $e->{id},
            title   => ($e->{target_name} // '') . " \x{2014} " . ($e->{event_date} // ''),
            subtype => $e->{event_type},
            snippet => $e->{description},
        };
    }

    my $content_total = 0;
    my $content;
    eval {
        ($content_total) = $dbh->selectrow_array(
            q{SELECT COUNT(*) FROM raw_content_fts
              WHERE raw_content_fts MATCH ?},
            undef, $query,
        );
        $content = $dbh->selectall_arrayref(
            q{SELECT rc.id, rc.target_id, rc.source_type, rc.source_title, rc.source_url,
                     rc.content_text, t.canonical_name AS target_name
              FROM raw_content_fts fts
              JOIN raw_content rc ON rc.id = fts.raw_content_id
              JOIN targets t ON t.id = rc.target_id
              WHERE raw_content_fts MATCH ?
              ORDER BY rank
              LIMIT ? OFFSET ?},
            { Slice => {} }, $query, $per_page, $offset,
        );
    };
    if ($@) {
        $content = $dbh->selectall_arrayref(
            q{SELECT rc.id, rc.target_id, rc.source_type, rc.source_title, rc.source_url,
                     rc.content_text, t.canonical_name AS target_name
              FROM raw_content rc
              JOIN targets t ON t.id = rc.target_id
              WHERE rc.content_text LIKE ? OR rc.source_title LIKE ?
              ORDER BY rc.created_at DESC
              LIMIT ? OFFSET ?},
            { Slice => {} }, $like, $like, $per_page, $offset,
        );
        ($content_total) = $dbh->selectrow_array(
            q{SELECT COUNT(*) FROM raw_content
              WHERE content_text LIKE ? OR source_title LIKE ?},
            undef, $like, $like,
        );
    }
    for my $r (@$content) {
        my $snippet = $r->{content_text} // '';
        if (length($snippet) > 200) {
            $snippet = substr($snippet, 0, 200) . "\x{2026}";
        }
        push @results, {
            type    => 'content',
            id      => $r->{id},
            title   => ($r->{source_title} // 'Untitled') . ' (' . ($r->{target_name} // '') . ')',
            subtype => $r->{source_type},
            snippet => $snippet,
        };
    }

    my $total = $target_count + $people_count + $events_count + $content_total;

    $c->stash(
        results       => \@results,
        query         => $query,
        saved_queries => $saved_queries,
        page          => $page,
        total         => $total,
        per_page      => $per_page,
        target_count  => $target_count,
        people_count  => $people_count,
        events_count  => $events_count,
        content_total => $content_total,
    );
    $c->render(template => 'search/text');
}

1;
