package Dragline::Controller::Search;
use strict;
use warnings;
use utf8;

use Mojo::Base 'Mojolicious::Controller', -signatures;

sub semantic ($c) {
    my $query = $c->param('q') // '';
    $query =~ s/^\s+|\s+$//g;

    my $target_id = $c->param('target_id') // '';

    unless (length($query)) {
        $c->stash(results => [], query => '', target_id => $target_id);
        $c->render(template => 'search/semantic');
        return;
    }

    my $dbh = $c->db;
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

    # Get embedding for the query
    my $embedding = eval {
        require Dragline::Embed;
        Dragline::Embed::embed($dbh, $settings_getter, $query);
    };

    unless ($embedding && ref($embedding) eq 'ARRAY' && @$embedding) {
        $c->stash(results => [], query => $query, target_id => $target_id, error => 'Failed to generate embedding for query.');
        $c->render(template => 'search/semantic');
        return;
    }

    my $blob = pack('f*', @$embedding);

    my @where;
    my @bind = ($blob);

    if ($target_id) {
        push @where, 'rc.target_id = ?';
        push @bind, $target_id;
    }

    my $where_sql = @where ? 'WHERE ' . join(' AND ', @where) : '';

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
          LIMIT 20},
        { Slice => {} }, @bind,
    );

    # Truncate content for display
    for my $r (@$results) {
        my $text = $r->{content_text} // '';
        if (length($text) > 300) {
            $text = substr($text, 0, 300) . '…';
        }
        $r->{snippet} = $text;
    }

    $c->stash(results => $results, query => $query, target_id => $target_id);
    $c->render(template => 'search/semantic');
}

1;