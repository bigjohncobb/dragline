package Dragline::Cost;
use strict;
use warnings;
use utf8;

use Data::UUID;

our $VERSION = '0.1.0';

my $_uuid = Data::UUID->new;

sub record {
    my ($dbh, %args) = @_;

    my $id = $_uuid->create_str;

    $dbh->do(
        q{INSERT INTO cost_records
            (id, provider, operation, model, input_tokens, output_tokens,
             estimated_cost_usd, target_id, job_id, status, created_at)
          VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, datetime('now'))},
        undef,
        $id,
        $args{provider},
        $args{operation},
        $args{model},
        $args{input_tokens},
        $args{output_tokens},
        $args{cost_usd},
        $args{target_id},
        $args{job_id},
        $args{status} // 'success',
    );

    return $id;
}

sub summary {
    my ($dbh, $days) = @_;

    return $dbh->selectall_arrayref(
        q{SELECT provider,
                 SUM(estimated_cost_usd) AS total_cost_usd,
                 COUNT(*)                AS total_calls
          FROM   cost_records
          WHERE  created_at >= datetime('now', ? || ' days')
          GROUP  BY provider
          ORDER  BY total_cost_usd DESC},
        { Slice => {} },
        "-$days",
    );
}

sub daily_breakdown {
    my ($dbh, $days) = @_;

    return $dbh->selectall_arrayref(
        q{SELECT DATE(created_at)          AS date,
                 provider,
                 SUM(estimated_cost_usd)   AS total_cost_usd
          FROM   cost_records
          WHERE  created_at >= datetime('now', ? || ' days')
          GROUP  BY DATE(created_at), provider
          ORDER  BY date DESC, provider ASC},
        { Slice => {} },
        "-$days",
    );
}

sub model_breakdown {
    my ($dbh, $days) = @_;

    return $dbh->selectall_arrayref(
        q{SELECT provider,
                 COALESCE(model, '—')      AS model,
                 operation,
                 SUM(estimated_cost_usd)   AS total_cost_usd,
                 SUM(input_tokens)         AS total_input_tokens,
                 SUM(output_tokens)        AS total_output_tokens,
                 COUNT(*)                  AS total_calls
          FROM   cost_records
          WHERE  created_at >= datetime('now', ? || ' days')
          GROUP  BY provider, model, operation
          ORDER  BY total_cost_usd DESC},
        { Slice => {} },
        "-$days",
    );
}

sub by_target {
    my ($dbh, $target_id) = @_;

    return $dbh->selectall_arrayref(
        q{SELECT provider,
                 operation,
                 model,
                 SUM(estimated_cost_usd) AS total_cost_usd,
                 COUNT(*)                AS total_calls
          FROM   cost_records
          WHERE  target_id = ?
          GROUP  BY provider, operation, model},
        { Slice => {} },
        $target_id,
    );
}

1;
