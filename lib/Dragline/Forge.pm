package Dragline::Forge;
use strict;
use warnings;
use utf8;

# This module is a stub. The Forge API integration is pending spec finalisation.
# The storage and deduplication logic below the placeholder is complete and ready
# — only the HTTP call needs to be implemented.

use Digest::SHA  qw(sha256_hex);
use Mojo::JSON   qw(encode_json);
use Data::UUID;
use Dragline::SSRF;

our $VERSION = '0.1.0';

my $_uuid = Data::UUID->new;

sub sync_target {
    my ($dbh, $ua, $settings_getter, $target_id, $target_name, $app_log) = @_;

    if ($ENV{DRAGLINE_AIRGAP}) {
        $app_log->warn("ForgeSync skipped: airgap mode");
        return (0, "airgap mode");
    }

    my $forge_api_url = $settings_getter->('forge_api_url') // '';
    my $forge_api_key = $settings_getter->('forge_api_key') // '';

    unless (length $forge_api_url && length $forge_api_key) {
        $app_log->warn("ForgeSync skipped: forge_api_url or forge_api_key not configured");
        return (0, "forge not configured");
    }

    my ($ssrf_ok, $ssrf_reason) = Dragline::SSRF::validate($forge_api_url);
    unless ($ssrf_ok) {
        $app_log->warn("ForgeSync blocked by SSRF check: $ssrf_reason");
        return (0, "SSRF blocked");
    }

    my $items;

    # TODO: Replace this block with the real Forge API call when the spec is finalised.
    # Expected: POST/GET to $forge_api_url with $forge_api_key auth, querying for $target_name.
    # Expected response: arrayref of items, each with at minimum:
    #   { id, title, url, published_at, sentiment_score, mention_count }
    $app_log->warn("ForgeSync: Forge API not yet implemented. No items fetched for target $target_name.");
    return (0, "forge api not implemented");

    # =========================================================================
    # Storage and deduplication logic — complete and ready.
    # This block executes once the placeholder above is replaced with a real
    # API call that populates $items (arrayref) and does not return early.
    # =========================================================================

    $items //= [];

    my $new_count = 0;

    eval {
        $dbh->begin_work;

        for my $item (@$items) {
            my $forge_item_id = $item->{id} // '';
            next unless length $forge_item_id;

            my $existing = $dbh->selectrow_array(
                q{SELECT id FROM forge_items WHERE target_id = ? AND forge_item_id = ?},
                undef,
                $target_id,
                $forge_item_id,
            );
            next if defined $existing;

            my $fi_id = $_uuid->create_str;
            $dbh->do(
                q{INSERT INTO forge_items
                    (id, target_id, forge_item_id, title, url, published_at,
                     sentiment_score, mention_count, raw_json)
                  VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)},
                undef,
                $fi_id,
                $target_id,
                $forge_item_id,
                $item->{title},
                $item->{url},
                $item->{published_at},
                $item->{sentiment_score},
                $item->{mention_count},
                encode_json($item),
            );

            my $content_text = join("\n\n",
                grep { defined $_ && length $_ }
                    $item->{title},
                    $item->{description},
            );
            my $content_hash = sha256_hex($content_text);
            my $word_count   = scalar split(' ', $content_text);

            my $rc_id = $_uuid->create_str;
            eval {
                $dbh->do(
                    q{INSERT INTO raw_content
                        (id, target_id, source_type, source_url, source_title,
                         content_text, content_hash, word_count)
                      VALUES (?, ?, 'forge', ?, ?, ?, ?, ?)},
                    undef,
                    $rc_id,
                    $target_id,
                    $item->{url},
                    $item->{title},
                    $content_text,
                    $content_hash,
                    $word_count,
                );
            };
            if ($@) {
                # UNIQUE (target_id, content_hash) conflict — duplicate content, skip silently
                die $@ unless $@ =~ /UNIQUE constraint failed/i;
            }

            $new_count++;
        }

        $dbh->commit;
    };
    if ($@) {
        eval { $dbh->rollback };
        $app_log->error("ForgeSync: transaction failed for target $target_name: $@");
        return (0, "database error");
    }

    if ($new_count > 0) {
        my $ce_id = $_uuid->create_str;
        eval {
            $dbh->do(
                q{INSERT INTO change_events
                    (id, target_id, event_type, summary, severity)
                  VALUES (?, ?, 'forge_sync', ?, 'info')},
                undef,
                $ce_id,
                $target_id,
                "$new_count new items from Forge for $target_name",
            );
        };
        $app_log->warn("ForgeSync: failed to insert change_event: $@") if $@;
    }

    return ($new_count, undef);
}

1;
